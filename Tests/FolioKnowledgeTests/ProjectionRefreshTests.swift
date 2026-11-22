import Foundation
import Testing
@testable import FolioKnowledge
import FolioKnowledgeApple

@Suite struct ProjectionRefreshTests {
  @Test func unchangedRefreshPreservesJobsButNewAdapterStillReceivesCurrentSource() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    try f.write("---\nid: note\n---\n# 제목\n원문입니다.\n", path: "notes/a.md")
    let first = try await f.workspace.refresh()
    let job = try #require(try await f.workspace.projection.pendingJobs(adapter: "spotlight").first)
    try await f.workspace.projection.acknowledge(job)
    for _ in 0..<3 { #expect(try await f.workspace.refresh().revision == first.revision) }
    #expect(try await f.workspace.projection.pendingJobs(adapter: "spotlight").isEmpty)
    let scan = makeScan(first)
    _ = try await f.workspace.projection.apply(scan, adapters: ["spotlight", "new-adapter"])
    #expect(try await f.workspace.projection.pendingJobs(adapter: "new-adapter").count == first.indexedItems().count)
    #expect(try await f.workspace.projection.pendingJobs(adapter: "spotlight").isEmpty)
    // Reindex requests remain pending even when the next scan has no changes.
    try await f.workspace.projection.requestReindex(adapter: "spotlight")
    _ = try await f.workspace.refresh()
    #expect(try await f.workspace.projection.pendingJobs(adapter: "spotlight").count == first.indexedItems().count)
    await f.workspace.close()
  }

  @Test func identicalRevisionStillPublishesCoverageDiagnosticsAndAdvancesScanSequence() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    try f.write("---\nid: note\n---\n# 제목\n원문입니다.\n", path: "notes/a.md")
    let first = try await f.workspace.refresh()
    let owner = UUID()
    _ = try await f.workspace.projection.apply(makeScan(first), sequence: .init(ownerID: owner, generation: 1))
    _ = try await f.workspace.projection.apply(makeScan(first), sequence: .init(ownerID: owner, generation: 3))
    let problem = WikiDiagnostic(path: "notes/b.md", reason: "read_failed")
    // A late scan cannot publish even a diagnostic after an unchanged newer scan.
    let late = try await f.workspace.projection.apply(makeScan(first, diagnostics: [problem], complete: false), sequence: .init(ownerID: owner, generation: 2))
    #expect(late.diagnostics.isEmpty && late.coverageComplete)
    let changed = try await f.workspace.projection.apply(makeScan(first, diagnostics: [problem], complete: false), sequence: .init(ownerID: owner, generation: 4))
    #expect(changed.revision == first.revision)
    #expect(changed.diagnostics == [problem] && !changed.coverageComplete)
    let restored = try await f.workspace.refresh()
    #expect(restored.diagnostics.isEmpty && restored.coverageComplete)
    // A separate owner of the database must invalidate this owner's cache.
    let other = try WikiProjection(databaseURL: f.base.appendingPathComponent("State/knowledge.sqlite"))
    _ = try await other.apply(makeScan(first, diagnostics: [problem], complete: false))
    #expect(try await f.workspace.projection.snapshot()?.diagnostics == [problem])
    try f.write("---\nid: note\n---\n# 제목\n바뀐 원문입니다.\n", path: "notes/a.md")
    #expect(try await f.workspace.refresh().revision != first.revision)
    await f.workspace.close()
  }

  private func makeScan(_ snapshot: WikiSnapshot, diagnostics: [WikiDiagnostic] = [], complete: Bool = true) -> WikiScan {
    .init(workspace: snapshot.workspace, documents: snapshot.documents,
      observedPaths: Set(snapshot.documents.map(\.relativePath)), ontology: snapshot.ontology,
      ontologyUnavailable: snapshot.ontologyUnavailable, diagnostics: diagnostics, enumerationComplete: complete)
  }
}
