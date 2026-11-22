import Foundation
import Testing
import FolioKnowledge
@testable import FolioKnowledgeApple
import FolioSemanticModels

@Suite(.serialized)
struct SemanticRelevanceTests {
  @Test func releasingModelsKeepsRevisionBoundCacheAndEvidenceUsable() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    try f.write("---\nid: a\n---\n# Work\nConcurrent operations respond to cancellation and preserve saved progress.\n", path: "notes/a.md")
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID,
      localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    let first = try await service.semanticSearch("Parallel tasks stop when cancelled.")
    let ref = try #require(first.matches.first?.reference)
    await service.releaseSemanticResources()
    let resumed = try await service.semanticSearch("Parallel tasks stop when cancelled.")
    #expect(resumed.matches.map(\.reference.documentID) == first.matches.map(\.reference.documentID))
    #expect(resumed.sourceRevision == first.sourceRevision)
    #expect(resumed.cachedSections == resumed.indexedSections)
    #expect(try await f.workspace.read(ref).contains("saved progress"))
    await service.releaseSemanticResources(); await f.workspace.close()
  }

  @Test func releaseRequestedDuringRelevanceIsDeferredUntilTheSearchEnds() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    try f.write("---\nid: a\n---\n# Work\nConcurrent operations respond to cancellation.\n", path: "notes/a.md")
    let relevance = HeldRelevance()
    let engine = WikiLocalSemanticSearch(embedding: MultilingualE5Embedding(), relevance: relevance)
    let pending = Task { try await engine.search(workspace: f.workspace, query: "Concurrent operations respond to cancellation.") }
    await relevance.waitForEntry()
    await engine.releaseResources()
    #expect(await relevance.releases == 0)
    await relevance.release()
    _ = try await pending.value
    await relevance.waitForResourceRelease()
    #expect(await relevance.releases == 1)
    await f.workspace.close()
  }

  @Test func retrievalCannotFallBackToUncheckedDenseCandidates() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    try f.write("---\nid: a\n---\n# Coffee\nHot water extracts a drink from ground coffee beans.\n", path: "notes/a.md")
    let engine = WikiLocalSemanticSearch(embedding: MultilingualE5Embedding())
    await #expect(throws: (any Error).self) { try await engine.search(workspace: f.workspace, query: "Coffee") }
    await f.workspace.close()
  }

  @Test func oversizedPairsAreExplicitAndNeverSilentlyTruncated() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let body = "# Word\n" + String(repeating: "word ", count: 503) + "\n"
    let original = "---\nid: a\n---\n" + body
    try f.write(original, path: "notes/a.md")
    let query = String(repeating: "word ", count: 10)
    let embedding = MultilingualE5Embedding(); let relevance = MultilingualMiniLMRelevance()
    #expect(try await embedding.tokenIDs("passage: " + body).count <= 512)
    #expect(try await relevance.tokenIDs(query: query, passage: body).count > 512)
    let report = try await WikiLocalSemanticSearch(embedding: embedding, relevance: relevance).search(workspace: f.workspace, query: query)
    #expect(report.indexComplete)
    #expect(report.relevanceComplete == false)
    #expect(report.relevanceCheckedCandidates == 0)
    #expect(report.matches.isEmpty)
    #expect(try String(contentsOf: f.root.appendingPathComponent("notes/a.md"), encoding: .utf8) == original)
    await f.workspace.close()
  }

  @Test(arguments: ["change", "close", "cancel"])
  func sourceIsRevalidatedAfterTheRelevanceWait(action: String) async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    try f.write("---\nid: a\n---\n# Work\nConcurrent operations respond to cancellation.\n", path: "notes/a.md")
    let relevance = HeldRelevance()
    let engine = WikiLocalSemanticSearch(embedding: MultilingualE5Embedding(), relevance: relevance)
    let search = Task { try await engine.search(workspace: f.workspace, query: "Concurrent operations respond to cancellation.") }
    await relevance.waitForEntry()
    if action == "close" { await f.workspace.close() }
    else if action == "cancel" { search.cancel() }
    else {
      // Change a different file: rereading only the returned reference would
      // miss the fact that the workspace revision changed during stage two.
      try f.write("---\nid: other\n---\n# External\nAnother document.\n", path: "notes/other.md")
    }
    await relevance.release()
    if action == "change" { await #expect(throws: WikiError.changedSource) { try await search.value } }
    else if action == "cancel" { await #expect(throws: CancellationError.self) { try await search.value } }
    else { await #expect(throws: (any Error).self) { try await search.value } }
    await f.workspace.close()
  }

  @Test(arguments: [false, true])
  func malformedRelevanceResultsFailClosed(wrongCount: Bool) async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    try f.write("---\nid: a\n---\n# Work\nConcurrent operations respond to cancellation.\n", path: "notes/a.md")
    let engine = WikiLocalSemanticSearch(embedding: MultilingualE5Embedding(), relevance: InvalidRelevance(wrongCount: wrongCount))
    await #expect(throws: WikiError.invalidSource("Invalid relevance scores.")) {
      try await engine.search(workspace: f.workspace, query: "Concurrent operations respond to cancellation.")
    }
    await f.workspace.close()
  }
}

private struct InvalidRelevance: WikiSemanticRelevance {
  let identifier = "invalid-relevance-test"
  let wrongCount: Bool
  func scores(query: String, passages: [String]) async throws -> [Double?] { wrongCount ? [] : passages.map { _ in .nan } }
}

private actor HeldRelevance: WikiSemanticRelevance {
  nonisolated let identifier = "held-relevance-lifecycle-test"
  private var entered = false
  private var entry: CheckedContinuation<Void, Never>?
  private var pending: CheckedContinuation<Void, Never>?
  private var resourceRelease: CheckedContinuation<Void, Never>?
  private(set) var releases = 0
  func releaseResources() { releases += 1; resourceRelease?.resume(); resourceRelease = nil }
  func waitForResourceRelease() async {
    if releases > 0 { return }
    await withCheckedContinuation { resourceRelease = $0 }
  }
  func waitForEntry() async {
    if entered { return }
    await withCheckedContinuation { entry = $0 }
  }
  func scores(query: String, passages: [String]) async throws -> [Double?] {
    entered = true; entry?.resume(); entry = nil
    await withCheckedContinuation { pending = $0 }
    return passages.map { _ in 10 }
  }
  func release() { pending?.resume(); pending = nil }
}
