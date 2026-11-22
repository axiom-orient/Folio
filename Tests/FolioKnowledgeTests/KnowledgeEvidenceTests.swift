import Foundation
import Testing
import FolioKnowledge
@testable import FolioKnowledgeApple

struct KnowledgeEvidenceTests {
  @Test func timeoutReturnsWithoutWaitingForAnUncooperativeProviderAndBoundsItsLifetime() async throws {
    let runner = WikiCandidateSearch()
    let gate = ProviderGate()
    let clock = ContinuousClock()
    let start = clock.now
    let first = await runner.search(source: .semantic, timeout: .milliseconds(30)) {
      await gate.wait()
      return .init(ids: ["late"], state: "ready", source: .semantic)
    }
    #expect(first.state == "systemSearchTimedOut")
    #expect(start.duration(to: clock.now) < .seconds(1))
    for _ in 0..<20 {
      let busy = await runner.search(source: .semantic) {
        Issue.record("A timed-out provider must retain its slot until it exits")
        return .init(ids: [], state: "unexpected", source: .semantic)
      }
      #expect(busy.state == "systemSearchBusy")
      #expect(busy.ids.isEmpty)
    }
    await gate.release()
    // Wait on the provider's actual completion, rather than an arbitrary sleep.
    var recovered = false
    for _ in 0..<1000 {
      let result = await runner.search(source: .semantic) { .init(ids: ["new"], state: "ready", source: .semantic) }
      if result.state == "ready" { recovered = true; #expect(result.ids == ["new"]); break }
      await Task.yield()
    }
    #expect(recovered)
  }

  @Test func callerCancellationReturnsAndDoesNotPublishLateCandidates() async throws {
    let runner = WikiCandidateSearch()
    let gate = ProviderGate()
    let task = Task {
      await runner.search(source: .semantic, timeout: .seconds(30)) {
        await gate.wait()
        return .init(ids: ["late"], state: "ready", source: .semantic)
      }
    }
    await gate.waitUntilStarted()
    task.cancel()
    let value = await task.value
    #expect(value.ids.isEmpty)
    let busy = await runner.search(source: .semantic) { .init(ids: [], state: "unexpected", source: .semantic) }
    #expect(busy.state == "systemSearchBusy")
    await gate.release()
  }

  @Test func closingWorkspaceDuringProviderSearchCannotPublishAnEmptySuccess() async throws {
    let fixture = try KnowledgeFixture()
    defer { fixture.remove() }
    let gate = ProviderGate()
    let service = WikiSearchService(workspace: fixture.workspace, workspaceID: fixture.workspace.workspaceID,
      semanticSearch: { _, _ in await gate.wait(); return [] })
    let search = Task { try await service.search("NoMatchingDocument") }
    await gate.waitUntilStarted()
    await fixture.workspace.close()
    await gate.release()
    await #expect(throws: (any Error).self) { try await search.value }
  }

  @Test func providerErrorsPreserveTheSelectedCandidateSource() async {
    let runner = WikiCandidateSearch()
    let result = await runner.search(source: .semantic) { throw WikiError.unavailable("offline") }
    #expect(result.source == .semantic)
    #expect(result.state.hasPrefix("degraded:"))
  }

  @Test func verificationDistinguishesCurrentChangedInvalidMissingAndEmptyEvidence() async throws {
    let fixture = try KnowledgeFixture()
    defer { fixture.remove() }
    try fixture.write("---\nid: first\n---\n# Original\nEvidence one\n", path: "notes/a.md")
    try fixture.write("---\nid: second\n---\n# Other\nEvidence two\n", path: "notes/b.md")
    let snapshot = try await fixture.workspace.refresh()
    let refs = snapshot.documents.map { WikiEvidenceReference(workspaceID: snapshot.workspace.id, document: $0, section: $0.sections[0]) }
    #expect(try await fixture.workspace.verifyEvidence(refs).allCurrent)
    let empty = try await fixture.workspace.verifyEvidence([])
    #expect(!empty.allCurrent)
    try fixture.write("---\nid: first\n---\n# Changed\nExternal edit\n", path: "notes/a.md")
    let mixed = try await fixture.workspace.verifyEvidence([refs[1], refs[0], refs[1]])
    #expect(mixed.items.map(\.state) == [.current, .changed, .current])
    #expect(!mixed.allCurrent)
    #expect(!mixed.atomicSnapshot)
    var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(refs[1])) as? [String: Any])
    fields["excerptSHA256"] = String(repeating: "0", count: 64)
    let invalid = try JSONDecoder().decode(WikiEvidenceReference.self, from: JSONSerialization.data(withJSONObject: fields))
    #expect(try await fixture.workspace.verifyEvidence([invalid]).items[0].state == .invalid)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("notes/b.md"))
    #expect(try await fixture.workspace.verifyEvidence([refs[1]]).items[0].state == .unavailable)
    await #expect(throws: (any Error).self) { try await fixture.workspace.verifyEvidence(Array(repeating: refs[0], count: 101)) }
    await fixture.workspace.close()
    await #expect(throws: (any Error).self) { try await fixture.workspace.verifyEvidence([]) }
  }

  @Test func localPagesKeepTermsBeyondTheBoundedSearchCompatibilityLimit() async throws {
    let fixture = try KnowledgeFixture()
    defer { fixture.remove() }
    try fixture.write("---\nid: boundary\n---\n# Boundary\nt32\n", path: "notes/a.md")
    let service = WikiSearchService(workspace: fixture.workspace, workspaceID: fixture.workspace.workspaceID)
    let query = (0..<33).map { String(format: "t%02d", $0) }.joined(separator: " ")
    let bounded = try await service.search(query, includeSystemSearch: false)
    let page = try await service.searchPage(query)
    #expect(bounded.hits.isEmpty)
    #expect(page.hits.first?.reference.documentID == "boundary")
    #expect(page.totalCount == 1)
  }

  @Test func relationStatesDistinguishAbsentUnavailableInvalidAndDuplicateTargets() throws {
    let identity = try WikiMarkdownParser.workspace(bytes: Data("---\nkind: workspace\nschema: 1\nid: \(UUID())\nname: Fixture\n---\n".utf8))
    let source = try WikiMarkdownParser.document(relativePath: "notes/a.md", bytes: Data(
      "---\nid: a\ntype: note\nrelations:\n  related: [b]\n---\n# Source\n".utf8))
    let target = try WikiMarkdownParser.document(relativePath: "notes/b.md", bytes: Data(
      "---\nid: b\ntype: note\n---\n# Target\n".utf8))
    let absent = WikiSnapshot(workspace: identity, documents: [source, target])
    #expect(absent.relations.first?.status == .valid)
    #expect(absent.relations.first?.ontologyRevision == nil)
    let unavailable = WikiSnapshot(workspace: identity, documents: [source, target], ontologyUnavailable: true)
    #expect(unavailable.relations.first?.status == .unresolved)
    #expect(unavailable.relations.first?.diagnostic == "ontology_unavailable")
    #expect(!unavailable.coverageComplete)
    let noRelation = try WikiOntology(bytes: Data("---\nkind: ontology\ntypes:\n  note: {}\n---\n".utf8))
    #expect(WikiSnapshot(workspace: identity, documents: [source, target], ontology: noRelation).relations.first?.status == .invalid)
    let duplicate = try WikiMarkdownParser.document(relativePath: "notes/c.md", bytes: Data("---\nid: b\n---\n# Duplicate\n".utf8))
    let ambiguous = WikiSnapshot(workspace: identity, documents: [source, target, duplicate])
    #expect(ambiguous.relations.first?.status == .unresolved)
    #expect(ambiguous.diagnostics.filter { $0.reason == "duplicate_document_id" }.count == 2)
  }

  @Test func approvedRelationRejectsChangedTargetOrOntologyWithoutChangingSource() async throws {
    let fixture = try KnowledgeFixture()
    defer { fixture.remove() }
    let ontology = "---\nkind: ontology\ntypes:\n  note: {}\nrelations:\n  related:\n    from: [note]\n    to: [note]\n---\n"
    try fixture.write(ontology, path: "_ontology.md")
    let source = "---\nid: source\ntype: note\n---\n# Source\n"
    try fixture.write(source, path: "notes/a.md")
    try fixture.write("---\nid: target\ntype: note\n---\n# Target\n", path: "notes/b.md")
    let snapshot = try await fixture.workspace.refresh()
    let original = try #require(snapshot.documents.first { $0.id == "source" })
    let replacement = "---\nid: source\ntype: note\nrelations:\n  related: [target]\n---\n# Source\n"
    let plan = try await fixture.workspace.prepareEdit(relativePath: original.relativePath,
      expectedRevision: original.revision, range: nil, replacement: replacement, operationID: UUID())
    try fixture.write("---\nid: target\ntype: note\n---\n# Target changed\n", path: "notes/b.md")
    await #expect(throws: WikiError.changedSource) { try await fixture.workspace.execute(plan) }
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("notes/a.md"), encoding: .utf8) == source)
    let next = try await fixture.workspace.prepareEdit(relativePath: original.relativePath,
      expectedRevision: original.revision, range: nil, replacement: replacement, operationID: UUID())
    try fixture.write(ontology + "Rule annotation changed\n", path: "_ontology.md")
    await #expect(throws: WikiError.changedSource) { try await fixture.workspace.execute(next) }
    let fresh = try await fixture.workspace.prepareEdit(relativePath: original.relativePath,
      expectedRevision: original.revision, range: nil, replacement: replacement, operationID: UUID())
    let receipt = try await fixture.workspace.execute(fresh)
    #expect(try await fixture.workspace.operationStatus(receipt.operationID).state == .committed)
    #expect(try await fixture.workspace.refresh().relations.first?.status == .valid)
    let replay = try await fixture.workspace.execute(fresh)
    #expect(replay.sourceRevision == receipt.sourceRevision)
    #expect(try await fixture.workspace.refresh().relations.count == 1)
  }
}

private actor ProviderGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var started = false
  private var released = false
  func wait() async {
    started = true
    guard !released else { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func waitUntilStarted() async {
    while !started { await Task.yield() }
  }
  func release() { released = true; continuation?.resume(); continuation = nil }
}
