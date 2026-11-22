import Foundation
import Darwin
import FolioKnowledge
import FolioKnowledgeApple
import FolioSemanticModels

/// Same corpus is used by model-backed regression tests. Development and
/// validation judgments remain separate in both raw results and gate metrics.
enum SemanticEvaluation {
  struct Corpus: Decodable {
    struct Note: Decodable { let id: String; let title: String; let text: String }
    struct Question: Decodable { let split: String; let query: String; let relevant: [String] }
    let version: Int; let notes: [Note]; let questions: [Question]
  }
  struct Sample: Encodable {
    let split: String; let query: String; let relevant: [String]
    let lexical: [String]; let semantic: [String]; let scores: [Double]
    let relevanceScores: [Double?]
    let milliseconds: Double; let complete: Bool
  }
  struct Metrics: Encodable {
    let positiveQuestions: Int; let negativeQuestions: Int
    let hitAt3: Double; let recallAt3: Double; let candidatePrecision: Double; let negativeCandidateRate: Double
    let qualified: Bool
  }
  struct VectorTrace: Encodable {
    struct Score: Encodable { let documentID: String; let retrieval: Double; let symmetric: Double; let relevance: Double? }
    let query: String; let scores: [Score]
  }
  static func run() async throws {
    let args = CommandLine.arguments
    let path = args.firstIndex(of: "--corpus").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
      ?? "Tests/FolioKnowledgeTests/Fixtures/SemanticCorpus.json"
    let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioBilingualEvaluation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Source")
    try WikiWorkspace.create(at: root, name: "한영 검색 검증")
    for doc in corpus.notes {
      try Data("---\nid: \(doc.id)\ntype: note\n---\n# \(doc.title)\n\(doc.text)\n".utf8).write(to: root.appendingPathComponent("notes/\(doc.id).md"))
    }
    try Data("---\nkind: ontology\ntypes:\n  note: {}\nrelations:\n  related:\n    from: [note]\n    to: [note]\n---\n".utf8).write(to: root.appendingPathComponent("_ontology.md"))
    let workspace = try WikiWorkspace(root: root, localStateDirectory: base.appendingPathComponent("State"))
    let embedding = MultilingualE5Embedding()
    let relevance = MultilingualMiniLMRelevance()
    let service = WikiSearchService(workspace: workspace, workspaceID: workspace.workspaceID,
      localSemanticEmbedding: embedding, localSemanticRelevance: relevance)
    var samples: [Sample] = []; var modelID = ""
    var relationCandidates: [WikiRelationProposal] = []
    var residentBeforeRelease: UInt64?; var residentAfterRelease: UInt64?
    var trace: [VectorTrace]? = args.contains("--trace-vectors") ? [] : nil
    do {
      var traceVectors: [(String, String, [Double], [Double])] = []
      if trace != nil {
        let snapshot = try await workspace.refresh()
        for doc in snapshot.documents {
          for section in doc.sections {
            traceVectors.append((doc.id, section.sourceText, try await embedding.vector(for: section.sourceText, role: .passage),
              try await embedding.vector(for: section.sourceText, role: .query)))
          }
        }
      }
      for q in corpus.questions {
        let lexical = try await service.search(q.query, limit: 3, includeSystemSearch: false)
        let start = ContinuousClock.now
        let result = try await service.semanticSearch(q.query, limit: 3)
        let duration = start.duration(to: .now).components; modelID = result.modelID
        samples.append(.init(split: q.split, query: q.query, relevant: q.relevant,
          lexical: lexical.hits.map(\.reference.documentID), semantic: result.matches.map(\.reference.documentID),
          scores: result.matches.map(\.similarity), relevanceScores: result.matches.map(\.relevanceScore),
          milliseconds: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
          complete: result.indexComplete && result.coverageComplete && result.relevanceComplete != false))
        if trace != nil {
          let query = try await embedding.vector(for: q.query, role: .query)
          var logits: [Double?] = []
          for offset in stride(from: 0, to: traceVectors.count, by: 20) {
            logits += try await relevance.scores(query: q.query, passages: traceVectors.dropFirst(offset).prefix(20).map { $0.1 })
          }
          trace?.append(.init(query: q.query, scores: zip(traceVectors, logits).map { item, logit in
            let (id, _, passage, symmetric) = item
            return .init(documentID: id, retrieval: zip(query, passage).reduce(0) { $0 + $1.0 * $1.1 },
              symmetric: zip(query, symmetric).reduce(0) { $0 + $1.0 * $1.1 },
              relevance: logit)
          }))
        }
      }
      relationCandidates = try await service.suggestRelations(documentID: "bank-ko", predicate: "related")
      residentBeforeRelease = memoryUsage()?.resident
      await service.releaseSemanticResources()
      residentAfterRelease = memoryUsage()?.resident
      await workspace.close()
    } catch { await workspace.close(); throw error }
    func metrics(_ split: String) -> Metrics {
      let selected = samples.filter { $0.split == split }; let positive = selected.filter { !$0.relevant.isEmpty }
      let negative = selected.filter { $0.relevant.isEmpty }
      let hits = positive.filter { !Set($0.semantic).intersection($0.relevant).isEmpty }.count
      let recall = positive.reduce(0.0) { $0 + Double(Set($1.semantic).intersection($1.relevant).count) / Double($1.relevant.count) } / Double(max(1, positive.count))
      let returned = selected.reduce(0) { $0 + $1.semantic.count }
      let correct = selected.reduce(0) { $0 + Set($1.semantic).intersection($1.relevant).count }
      let precision = Double(correct) / Double(max(1, returned)); let rate = Double(negative.filter { !$0.semantic.isEmpty }.count) / Double(max(1, negative.count))
      let hit = Double(hits) / Double(max(1, positive.count))
      return .init(positiveQuestions: positive.count, negativeQuestions: negative.count, hitAt3: hit, recallAt3: recall,
        candidatePrecision: precision, negativeCandidateRate: rate, qualified: hit >= 0.8 && precision >= 0.8 && rate <= 0.1)
    }
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    struct Report: Encodable {
      let schema: String; let modelID: String; let corpusVersion: Int
      let minimumCandidateCosine: Double; let minimumRelevanceScore: Double; let maximumRelevanceScoreGap: Double
      let peakResidentBytes: Int; let development: Metrics; let validation: Metrics; let holdout: Metrics; let additionalAudit: Metrics
      let samples: [Sample]; let relationCandidates: [WikiRelationProposal]
      let vectorTrace: [VectorTrace]?
      let residentBytesBeforeRelease: UInt64?; let residentBytesAfterRelease: UInt64?
      let peakPhysicalFootprintBytes: UInt64?
    }
    let report = Report(schema: "folio.bilingual-retrieval/2", modelID: modelID, corpusVersion: corpus.version,
      minimumCandidateCosine: WikiLocalSemanticSearch.minimumCandidateSimilarity,
      minimumRelevanceScore: WikiLocalSemanticSearch.minimumRelevanceScore, maximumRelevanceScoreGap: WikiLocalSemanticSearch.maximumRelevanceGap,
      peakResidentBytes: Int(usage.ru_maxrss), development: metrics("development"), validation: metrics("validation"), holdout: metrics("holdout"),
      additionalAudit: metrics("audit"), samples: samples, relationCandidates: relationCandidates, vectorTrace: trace,
      residentBytesBeforeRelease: residentBeforeRelease, residentBytesAfterRelease: residentAfterRelease,
      peakPhysicalFootprintBytes: memoryUsage()?.peakPhysical)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    FileHandle.standardOutput.write(try encoder.encode(report)); FileHandle.standardOutput.write(Data("\n".utf8))
  }

  private static func memoryUsage() -> (resident: UInt64, peakPhysical: UInt64)? {
    var info = task_vm_info_data_t()
    let words = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(words)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: words) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard status == KERN_SUCCESS, let peak = UInt64(exactly: info.ledger_phys_footprint_peak) else { return nil }
    return (info.resident_size, peak)
  }
}
