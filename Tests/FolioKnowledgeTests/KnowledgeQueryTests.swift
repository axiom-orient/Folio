import Foundation
import Testing
import FolioKnowledge
import FolioKnowledgeApple

@Suite struct KnowledgeQueryTests {
  @Test func lexicalNeedsNoModelsAndOptionalSemanticVisitsAndCachesMoreThan512Blocks() async throws {
    let fixture = try QueryFixture(); defer { fixture.remove() }
    let source = "---\nid: large\n---\n" + (0..<600).map { index in
      "# Record \(index)\n" + (index == 599
        ? "target-evidence 동시 실행을 취소하면 진행 중인 작업을 중단합니다.\n"
        : "Catalog entry number \(index) preserves its original quotation.\n")
    }.joined()
    try fixture.write(source)
    let embedding = QueryEmbedding()
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace, embedding: embedding, relevance: QueryRelevance())
    let coverage = try await engine.prepare()
    #expect(coverage.complete && coverage.blockCount >= 600)
    #expect(await embedding.passageCount() == 0)
    let lexical = try await engine.answer("target-evidence")
    #expect(!lexical.semanticUsed && lexical.evidence.contains { $0.text.contains("target-evidence") })
    #expect(await embedding.queryCount() == 0)
    await #expect(throws: WikiError.self) { try await engine.answer("target-evidence", documentID: "missing") }
    let first = try await engine.answer("parallel tasks stop", useSemantic: true)
    #expect(first.semanticUsed && first.coverage.semanticComplete)
    #expect(first.evidence.count == 1 && first.evidence[0].text.contains("동시 실행"))
    #expect(await embedding.passageCount() == coverage.blockCount)
    let warm = try await engine.answer("parallel tasks stop", documentID: "large", useSemantic: true)
    #expect(warm.evidence.map(\.id) == first.evidence.map(\.id))
    #expect(await embedding.passageCount() == coverage.blockCount)
    #expect(try String(contentsOf: fixture.note, encoding: .utf8) == source)
    await fixture.workspace.close()
  }

  @Test func hybridCandidatesRespectTheRerankerBudgetWithoutLosingTheDenseMatch() async throws {
    let fixture = try QueryFixture(); defer { fixture.remove() }
    let distractors = (0..<25).map { "# Report \($0)\nA report tracks unrelated weather data.\n" }.joined()
    let source = "---\nid: selected\n---\n" + distractors + "# Work\ntarget-evidence 동시 실행을 취소할 수 있습니다.\n"
    try fixture.write(source)
    let other = fixture.root.appendingPathComponent("notes/other.md")
    try Data("---\nid: other\n---\n# Other\ntarget-evidence 다른 자료의 동시 작업.\n".utf8).write(to: other)
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace, embedding: QueryEmbedding(), relevance: QueryRelevance())
    let index = try await engine.prepare()
    let answer = try await engine.answer("report parallel tasks stop", documentID: "selected", useSemantic: true)

    #expect(answer.evidence.count == 1)
    #expect(answer.evidence.first?.text.contains("동시 실행") == true)
    #expect(answer.evidence.first?.source.documentID == "selected")
    #expect(answer.coverage.sourceCount == 1)
    #expect(answer.coverage.blockCount == index.blockCount - 1)
    await fixture.workspace.close()
  }

  @Test func skippedAndUnscoredPassagesNeverBecomeFallbacksAndForgedQuotesAreRejected() async throws {
    let fixture = try QueryFixture(); defer { fixture.remove() }
    try fixture.write("---\nid: small\n---\n# One\ntarget-evidence eligible quotation.\n# Two\nunscored quotation.\n# Three\nover-budget quotation.\n")
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace,
      embedding: QueryEmbedding(allCandidates: true), relevance: QueryRelevance())
    let answer = try await engine.answer("eligible unscored", useSemantic: true)
    #expect(!answer.coverage.semanticComplete)
    #expect(answer.evidence.count == 1 && answer.evidence[0].text.contains("eligible"))
    #expect(!answer.evidence.contains { $0.text.contains("unscored") || $0.text.contains("over-budget") })
    let quote = try #require(answer.evidence.first)
    let document = try #require(try await fixture.workspace.projection.knowledgeDocuments().first)
    let rows = try await fixture.workspace.projection.knowledgeBlockPage(sourceIDs: [document.id])
    let forged = WikiKnowledgeEvidence(id: quote.id, text: "target-evidence fabricated eligible quotation.",
      source: quote.source, location: quote.location)
    let payload = String(decoding: try JSONEncoder().encode(forged), as: UTF8.self)
    let blocks = rows.map { row in
      row.block.id == quote.id ? WikiKnowledgeBlockRecord(id: quote.id, sourceID: document.id,
        ordinal: row.block.ordinal, text: forged.text, payload: payload) : row.block
    }
    // Even self-consistent forged JSON, block text and a copied source identity
    // cannot replace the current original quotation.
    try await fixture.workspace.projection.replaceKnowledgeDocument(document, blocks: blocks)
    await #expect(throws: WikiError.changedSource) { try await engine.answer("fabricated") }
    await fixture.workspace.close()
  }

  @Test func sourceChangesDuringModelAwaitRejectPublicationAndDeferResourceRelease() async throws {
    let fixture = try QueryFixture(); defer { fixture.remove() }
    try fixture.write("---\nid: changing\n---\n# Work\ntarget-evidence original quotation.\n")
    let embedding = GatedQueryEmbedding()
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace, embedding: embedding, relevance: QueryRelevance())
    let pending = Task { try await engine.answer("parallel tasks stop", useSemantic: true) }
    await embedding.waitUntilEntered()
    await #expect(throws: WikiError.self) { try await engine.prepare() }
    await engine.releaseResources()
    #expect(await embedding.releaseCount() == 0)
    try fixture.write("---\nid: changing\n---\n# Work\ntarget-evidence changed quotation.\n")
    await embedding.resumeQuery()
    await #expect(throws: WikiError.changedSource) { try await pending.value }
    await embedding.waitUntilReleased()
    #expect(await embedding.releaseCount() >= 1)
    #expect(try String(contentsOf: fixture.note, encoding: .utf8).contains("changed quotation"))
    await fixture.workspace.close()
  }

  @Test func selectedPreparationKeepsOtherValidVectorsAndLeavesUnpreparedSourcesAlone() async throws {
    let fixture = try QueryFixture(); defer { fixture.remove() }
    try fixture.write("---\nid: selected\n---\n# Selected\nselected-only original quotation.\n")
    let other = fixture.root.appendingPathComponent("notes/other.md")
    try Data("---\nid: other\n---\n# Other\ntarget-evidence original quotation.\n".utf8).write(to: other)
    let embedding = QueryEmbedding()
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace, embedding: embedding, relevance: QueryRelevance())
    let otherAnswer = try await engine.answer("parallel tasks stop", documentID: "other", useSemantic: true)
    let otherSource = try #require(otherAnswer.evidence.first?.source.id)
    let otherRecord = try #require(try await fixture.workspace.projection.knowledgeDocuments().first { $0.id == otherSource })
    let otherRows = try await fixture.workspace.projection.knowledgeBlockPage(sourceIDs: [otherSource])
    #expect(!otherRows.isEmpty && otherRows.allSatisfy { $0.block.vectorJSON != nil })
    let generatedPassages = await embedding.passageCount()

    // These bytes enter the inventory, but preparing a different document must
    // not parse them or index the unselected owner note as a side effect.
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("attachments"), withIntermediateDirectories: true)
    try Data("not a PDF".utf8).write(to: fixture.root.appendingPathComponent("attachments/unprepared.pdf"))
    try Data("---\nid: unprepared\n---\n# Unprepared\n[PDF](../attachments/unprepared.pdf)\n".utf8)
      .write(to: fixture.root.appendingPathComponent("notes/unprepared.md"))

    let selected = try await engine.answer("selected-only", documentID: "selected")
    let selectedSource = try #require(selected.evidence.first?.source.id)
    #expect(selected.evidence.allSatisfy { $0.source.documentID == "selected" })
    #expect(selected.coverage.complete && selected.coverage.sourceCount == 1 && selected.coverage.blockCount == 1)
    let records = try await fixture.workspace.projection.knowledgeDocuments()
    #expect(Set(records.map(\.id)) == [selectedSource, otherSource])
    #expect(records.first { $0.id == otherSource } == otherRecord)
    #expect(try await fixture.workspace.projection.knowledgeBlockPage(sourceIDs: [otherSource]) == otherRows)
    #expect(await embedding.passageCount() == generatedPassages)
    await fixture.workspace.close()
  }

  @Test func missingDocumentIsRejectedBeforeAnyKnowledgeSourceIsPrepared() async throws {
    let fixture = try QueryFixture(); defer { fixture.remove() }
    try fixture.write("---\nid: existing\n---\n# Existing\nOriginal quotation.\n")
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace)
    await #expect(throws: WikiError.self) { try await engine.answer("Original", documentID: "missing") }
    #expect(try await fixture.workspace.projection.knowledgeDocuments().isEmpty)
    #expect(try await fixture.workspace.projection.knowledgeBlockCount() == 0)
    await fixture.workspace.close()
  }

  @Test func failedSelectedSourceDoesNotAuthorizeItsOldCacheOrCoverage() async throws {
    let fixture = try QueryFixture(); defer { fixture.remove() }
    try fixture.write("---\nid: owner\n---\n# Owner\n[PDF](../attachments/source.pdf)\n")
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("attachments"), withIntermediateDirectories: true)
    try Data("not a PDF".utf8).write(to: fixture.root.appendingPathComponent("attachments/source.pdf"))
    let inventory = try await fixture.workspace.knowledgeInventory()
    let pdf = try #require(inventory.sources.first { $0.kind == .pdf })
    // A stale extraction may remain on disk after a source replacement. Failure
    // to prepare the current source must not fall back to those previous rows.
    let old = WikiKnowledgeDocumentRecord(id: pdf.id, revision: "previous-source-revision", producer: "previous-producer", payload: "{}")
    let oldBlock = WikiKnowledgeBlockRecord(id: "old-pdf-block", sourceID: pdf.id, ordinal: 0,
      text: "stale-only-evidence", payload: "{}")
    try await fixture.workspace.projection.replaceKnowledgeDocument(old, blocks: [oldBlock])
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace)
    let answer = try await engine.answer("stale-only-evidence", documentID: "owner")
    #expect(answer.evidence.isEmpty)
    #expect(!answer.coverage.complete && !answer.coverage.diagnostics.isEmpty)
    #expect(answer.coverage.sourceCount == 1 && answer.coverage.blockCount == 1)
    #expect(try await fixture.workspace.projection.knowledgeBlockCount(sourceIDs: [pdf.id]) == 0)
    #expect(try await fixture.workspace.projection.knowledgeDocuments().allSatisfy { $0.id != pdf.id })
    await fixture.workspace.close()
  }
}

private actor QueryEmbedding: WikiSemanticEmbedding {
  nonisolated let identifier = "test-knowledge-embedding.v1"
  nonisolated let dimensions = 2
  private let allCandidates: Bool
  private var passages = 0
  private var queries = 0
  init(allCandidates: Bool = false) { self.allCandidates = allCandidates }
  func vector(for text: String, role: WikiSemanticRole) async throws -> [Double] {
    switch role {
    case .query: queries += 1; return [1, 0]
    case .passage:
      passages += 1
      if text.contains("over-budget") { throw WikiSemanticEmbeddingError.tokenBudget }
      return allCandidates || text.contains("target-evidence") ? [1, 0] : [0, 1]
    }
  }
  func passageCount() -> Int { passages }
  func queryCount() -> Int { queries }
}

private struct QueryRelevance: WikiSemanticRelevance {
  let identifier = "test-knowledge-relevance.v1"
  func scores(query: String, passages: [String]) async throws -> [Double?] {
    guard passages.count <= WikiLocalSemanticSearch.maximumRelevanceCandidates else {
      throw WikiError.invalidSource("The relevance provider accepts at most 20 candidates.")
    }
    return passages.map { text in
      if text.contains("unscored") { return nil }
      return text.contains("target-evidence") ? 2 : -10
    }
  }
}

private actor GatedQueryEmbedding: WikiSemanticEmbedding {
  nonisolated let identifier = "test-gated-knowledge-embedding.v1"
  nonisolated let dimensions = 2
  private var entered = false
  private var released = 0
  private var queryContinuation: CheckedContinuation<Void, Never>?
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var releasedContinuation: CheckedContinuation<Void, Never>?
  func vector(for text: String, role: WikiSemanticRole) async throws -> [Double] {
    if case .query = role, !entered {
      entered = true; enteredContinuation?.resume(); enteredContinuation = nil
      await withCheckedContinuation { queryContinuation = $0 }
    }
    return [1, 0]
  }
  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { enteredContinuation = $0 } }
  }
  func resumeQuery() { queryContinuation?.resume(); queryContinuation = nil }
  func releaseResources() async {
    released += 1; releasedContinuation?.resume(); releasedContinuation = nil
  }
  func waitUntilReleased() async {
    if released == 0 { await withCheckedContinuation { releasedContinuation = $0 } }
  }
  func releaseCount() -> Int { released }
}

private struct QueryFixture {
  let directory: URL
  let root: URL
  let note: URL
  let workspace: WikiWorkspace
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioKnowledgeQuery-" + UUID().uuidString)
    root = directory.appendingPathComponent("source")
    note = root.appendingPathComponent("notes/material.md")
    try WikiWorkspace.create(at: root, name: "Knowledge query test")
    workspace = try WikiWorkspace(root: root, localStateDirectory: directory.appendingPathComponent("state"))
  }
  func write(_ text: String) throws { try Data(text.utf8).write(to: note, options: .atomic) }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
