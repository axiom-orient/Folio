import Foundation
import Testing
import FolioSemanticModels
import FolioKnowledge
import FolioKnowledgeApple

@Suite(.serialized)
struct BilingualSemanticTests {
  @Test func bundledAssetsMatchPinnedManifest() async throws {
    struct Manifest: Decodable { let files: [String: String] }
    let roots = [try await MultilingualE5Embedding().resources(), try await MultilingualMiniLMRelevance().resources()]
    for root in roots {
      let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("MODEL_SOURCE.json")))
      for (path, digest) in manifest.files {
        #expect(SourceDigest.sha256(try Data(contentsOf: root.appendingPathComponent(path))) == digest)
      }
      #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("tokenizer.json").path))
      #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("tokenizer_config.json").path))
    }
    let root = roots[0]
    let tokenizer = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("TOKENIZER_SOURCE.json")))
    for (path, digest) in tokenizer.files {
      #expect(SourceDigest.sha256(try Data(contentsOf: root.appendingPathComponent(path))) == digest)
    }
  }

  @Test func compactTokenizerMatchesIndependentUnicodeConformance() async throws {
    struct Reference: Decodable {
      struct Single: Decodable { let text: String; let ids: [Int] }
      struct Pair: Decodable { let query: String; let passage: String; let ids: [Int] }
      let embedding: [Single]; let relevance: [Pair]
    }
    let url = try #require(Bundle.module.url(forResource: "CompactTokenizerConformance", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    let e = MultilingualE5Embedding(); let r = MultilingualMiniLMRelevance()
    for item in reference.embedding { #expect(try await e.tokenIDs(item.text) == item.ids, "Compact E5 mismatch: \(item.text.debugDescription)") }
    for item in reference.relevance { let actual = try await r.tokenIDs(query: item.query, passage: item.passage); #expect(actual == item.ids, "Compact pair mismatch: \(item.query.debugDescription) / \(item.passage.debugDescription)") }
  }

  @Test func bilingualCorpusRejectsUnrelatedQueriesWithoutChangingSources() async throws {
    struct Corpus: Decodable {
      struct Note: Decodable { let id: String; let title: String; let text: String }
      struct Question: Decodable { let split: String; let query: String; let relevant: [String] }
      let notes: [Note]; let questions: [Question]
    }
    let url = try #require(Bundle.module.url(forResource: "SemanticCorpus", withExtension: "json", subdirectory: "Fixtures"))
    let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    let f = try KnowledgeFixture(); defer { f.remove() }
    var originals: [String: Data] = [:]
    for note in corpus.notes {
      let path = "notes/\(note.id).md"
      let text = "---\nid: \(note.id)\ntype: note\n---\n# \(note.title)\n\(note.text)\n"
      try f.write(text, path: path); originals[path] = Data(text.utf8)
    }
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    var positives: [String: Int] = [:]; var hits: [String: Int] = [:]
    for question in corpus.questions {
      let report = try await service.semanticSearch(question.query, limit: 3)
      let ids = Set(report.matches.map(\.reference.documentID))
      #expect(report.indexComplete && report.coverageComplete && report.relevanceComplete == true, "\(question.split): \(question.query)")
      if question.relevant.isEmpty { #expect(ids.isEmpty, "Unrelated: \(question.query)") }
      else {
        positives[question.split, default: 0] += 1
        if !ids.intersection(question.relevant).isEmpty { hits[question.split, default: 0] += 1 }
        #expect(ids.isSubset(of: Set(question.relevant)), "False candidate: \(question.query)")
      }
      if question.query == "세면대에서 물이 한 방울씩 떨어질 때 부를 전문가" { #expect(ids.contains("repair-ko")) }
      for match in report.matches { _ = try await f.workspace.read(match.reference) }
    }
    for (split, count) in positives { #expect(Double(hits[split, default: 0]) / Double(count) >= 0.8, "Hit@3 gate: \(split)") }
    for (path, original) in originals { #expect(try Data(contentsOf: f.root.appendingPathComponent(path)) == original) }
    await f.workspace.close()
  }

  @Test func koreanRelationSimilarityIsConservative() async throws {
    let model = MultilingualE5Embedding()
    let texts = [
      "# 예금과 이자\n은행은 고객이 맡긴 돈을 예금 계좌에 보관하고 약정한 조건에 따라 이자를 지급한다.\n",
      "# 은행 계좌와 이자\n은행은 고객이 맡긴 돈을 예금 계좌에 보관하며 약정한 조건에 따라 이자를 지급한다.\n",
      "# Deposits and interest\nA bank keeps customers' money in deposit accounts and pays interest according to the account terms.\n",
      "# 물길 옆 산책\n강둑은 강물이 흐르는 가장자리의 땅이다. 사람들은 물가를 따라 걸으며 나무와 새를 관찰한다.\n"
    ]
    var vectors: [[Double]] = []
    for text in texts { vectors.append(try await model.vector(for: text, role: .query)) }
    let scores = vectors.dropFirst().map { zip(vectors[0], $0).reduce(0.0) { $0 + $1.0 * $1.1 } }
    print("KOREAN_RELATION_SCORES \(scores)")
    #expect(scores[0] >= 0.88)
    #expect(scores[2] < 0.88)
    let f = try KnowledgeFixture(); defer { f.remove() }
    try f.write("---\nkind: ontology\ntypes:\n  note: {}\nrelations:\n  related:\n    from: [note]\n    to: [note]\n---\n", path: "_ontology.md")
    for (index, text) in texts.enumerated() {
      try f.write("---\nid: note-\(index)\ntype: note\n---\n" + text, path: "notes/\(index).md")
    }
    let before = try Data(contentsOf: f.root.appendingPathComponent("notes/0.md"))
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: model)
    let proposals = try await service.suggestRelations(documentID: "note-0", predicate: "related")
    #expect(proposals.map(\.target.documentID) == ["note-1"])
    #expect(try Data(contentsOf: f.root.appendingPathComponent("notes/0.md")) == before)
    await f.workspace.close()
  }
  @Test func tokenizerMatchesReference() async throws {
    let model = MultilingualE5Embedding()
    struct Reference: Decodable {
      struct Case: Decodable { let text: String; let ids: [Int] }
      let cases: [Case]
    }
    let url = try #require(Bundle.module.url(forResource: "TokenizerReference", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    for item in reference.cases { #expect(try await model.tokenIDs(item.text) == item.ids, "Tokenizer mismatch: \(item.text)") }
  }

  @Test func relevancePairTokenizerMatchesReference() async throws {
    struct Reference: Decodable {
      struct Case: Decodable { let query: String; let passage: String; let ids: [Int] }
      let cases: [Case]
    }
    let url = try #require(Bundle.module.url(forResource: "RelevanceTokenizerReference", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    let model = MultilingualMiniLMRelevance()
    for item in reference.cases { #expect(try await model.tokenIDs(query: item.query, passage: item.passage) == item.ids, "Pair mismatch: \(item.query)") }
  }
}
