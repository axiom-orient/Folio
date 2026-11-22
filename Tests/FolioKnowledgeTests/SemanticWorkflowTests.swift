import Foundation
import FolioSemanticModels
import Testing
import FolioKnowledge
@testable import FolioKnowledgeApple

@Suite(.serialized)
struct SemanticWorkflowTests {
  @Test func nativeSearchFindsAParaphraseAndCachesOnlyRevisionBoundVectors() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let old = "---\nid: concurrent\n---\n# Work\nConcurrent operations respond to cancellation.\n"
    try f.write(old, path: "notes/a.md")
    try f.write("---\nid: river\n---\n# Outdoors\nThe water flows past trees along a river.\n", path: "notes/b.md")
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    let query = "Parallel tasks stop when cancelled."
    let lexical = try await service.search(query, includeSystemSearch: false)
    #expect(!lexical.hits.contains { $0.reference.documentID == "concurrent" })
    let first = try await service.semanticSearch(query)
    #expect(first.matches.first?.reference.documentID == "concurrent")
    #expect(first.matches.allSatisfy { $0.similarity >= WikiLocalSemanticSearch.minimumCandidateSimilarity && ($0.relevanceScore ?? -.infinity) >= WikiLocalSemanticSearch.minimumRelevanceScore })
    #expect(first.cachedSections == 0)
    #expect(first.vectorBytes <= WikiLocalSemanticSearch.maximumSections * 384 * 8)
    let warm = try await service.semanticSearch(query)
    #expect(warm.cachedSections == warm.indexedSections)
    let ref = try #require(warm.matches.first?.reference)
    let producer = WikiLocalSemanticSearch.cacheProducer(modelID: warm.modelID)
    let entry = try #require(try await f.workspace.projection.derivedValues(producer: producer).first)
    #expect(try await f.workspace.projection.storeDerivedValue(.init(subjectID: entry.subjectID,
      sourceRevision: entry.sourceRevision, inputHash: entry.inputHash, valueJSON: "{invalid vector}"), producer: producer))
    _ = try await f.workspace.projection.storeDerivedValue(entry, producer: "folio.semantic/old-model")
    _ = try await f.workspace.projection.storeDerivedValue(entry, producer: "unrelated.user-cache")
    let repaired = try await service.semanticSearch(query)
    #expect(repaired.cachedSections < repaired.indexedSections)
    #expect(try await f.workspace.projection.derivedValues(producer: "folio.semantic/old-model").isEmpty)
    #expect(try await f.workspace.projection.derivedValues(producer: "unrelated.user-cache").count == 1)
    #expect(try await f.workspace.read(ref).contains("cancellation"))
    try f.write(old.replacingOccurrences(of: "cancellation", with: "interruption"), path: "notes/a.md")
    let changed = try await service.semanticSearch(query)
    #expect(changed.sourceRevision != warm.sourceRevision)
    #expect(changed.cachedSections < changed.indexedSections)
    await #expect(throws: WikiError.changedSource) { try await f.workspace.read(ref) }
    try FileManager.default.removeItem(at: f.root.appendingPathComponent("notes/b.md"))
    let deleted = try await service.semanticSearch(query)
    #expect(deleted.indexedSections == 1)
    let reopened = try WikiWorkspace(root: f.root, localStateDirectory: f.base.appendingPathComponent("State"))
    let cacheAfterRestart = try await WikiLocalSemanticSearch(embedding: MultilingualE5Embedding(), relevance: MultilingualMiniLMRelevance()).search(workspace: reopened, query: query)
    #expect(cacheAfterRestart.cachedSections == 1)
    try await reopened.projection.reset()
    let rebuilt = try await WikiLocalSemanticSearch(embedding: MultilingualE5Embedding(), relevance: MultilingualMiniLMRelevance()).search(workspace: reopened, query: query)
    #expect(rebuilt.cachedSections == 0)
    #expect(try String(contentsOf: f.root.appendingPathComponent("notes/a.md"), encoding: .utf8).contains("interruption"))
    await reopened.close(); await f.workspace.close()
  }

  @Test func invalidLanguageCancellationAndClosedSourcesAreExplicit() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let engine = WikiLocalSemanticSearch(embedding: MultilingualE5Embedding(), relevance: MultilingualMiniLMRelevance())
    await #expect(throws: (any Error).self) { try await engine.search(workspace: f.workspace, query: "query", language: "unsupported") }
    await #expect(throws: (any Error).self) { try await engine.search(workspace: f.workspace, query: "English text", language: "fr") }
    await #expect(throws: (any Error).self) { try await engine.search(workspace: f.workspace, query: "", limit: 0) }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await engine.search(workspace: f.workspace, query: "Task cancellation")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    await f.workspace.close()
    await #expect(throws: (any Error).self) { try await engine.search(workspace: f.workspace, query: "Task cancellation") }
  }

  @Test func filtersAndOversizedUnsupportedSectionsNeverLeakIntoSemanticCandidates() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    try f.write("---\nid: a\ntags: [included]\n---\n# Work\nConcurrent operations respond to cancellation.\n", path: "notes/a.md")
    try f.write("---\nid: b\n---\n# Work\nConcurrent operations respond to cancellation.\n", path: "notes/b.md")
    try f.write("---\nid: huge\ntags: [included]\n---\n# Large\n" + String(repeating: "word ", count: 1800), path: "notes/c.md")
    try f.write("---\nid: korean\ntags: [included]\n---\n# 한국어\n작업 취소 동시성\n", path: "notes/d.md")
    let value = try await WikiLocalSemanticSearch(embedding: MultilingualE5Embedding(), relevance: MultilingualMiniLMRelevance()).search(workspace: f.workspace,
      query: "Concurrent operations respond to cancellation.", filter: .init(tag: "included"))
    #expect(value.matches.contains { $0.reference.documentID == "a" })
    #expect(!value.matches.contains { ["b", "huge"].contains($0.reference.documentID) })
    #expect(!value.indexComplete)
    #expect(value.indexedSections == 2)
    await f.workspace.close()
  }

  @Test func indexBudgetAndCancellationAreBoundedAndSourcePreserving() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let source = "---\nid: budget\n---\n" + (0..<513).map {
      "# Work \($0)\nConcurrent operations respond to cancellation and preserve progress.\n"
    }.joined()
    try f.write(source, path: "notes/a.md")
    let engine = WikiLocalSemanticSearch(embedding: MultilingualE5Embedding(), relevance: MultilingualMiniLMRelevance())
    let pending = Task { try await engine.search(workspace: f.workspace, query: "Concurrent work") }
    try await Task.sleep(for: .milliseconds(10))
    pending.cancel()
    await #expect(throws: CancellationError.self) { try await pending.value }
    let bounded = try await engine.search(workspace: f.workspace, query: "Concurrent work")
    #expect(!bounded.indexComplete)
    #expect(bounded.indexedSections <= 512)
    #expect(bounded.vectorBytes <= 512 * 384 * 8)
    #expect(try String(contentsOf: f.root.appendingPathComponent("notes/a.md"), encoding: .utf8) == source)
    await f.workspace.close()
  }

  @Test func proposalsAreDurableRejectedAndStaleWithoutWritingMarkdown() async throws {
    let f = try await proposalFixture(); defer { f.remove() }
    let before = try Data(contentsOf: f.root.appendingPathComponent("notes/a.md"))
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    let proposals = try await service.suggestRelations(documentID: "a", predicate: "related")
    let proposal = try #require(proposals.first)
    #expect(proposal.target.documentID == "b")
    #expect(try Data(contentsOf: f.root.appendingPathComponent("notes/a.md")) == before)
    let again = try await service.suggestRelations(documentID: "a", predicate: "related")
    #expect(again.first?.id == proposal.id)
    try await f.workspace.rejectRelationProposal(id: proposal.id)
    #expect(try await f.workspace.relationProposalStatus(id: proposal.id).state == .rejected)
    #expect(try await service.suggestRelations(documentID: "a", predicate: "related").isEmpty)
    await #expect(throws: (any Error).self) { try await f.workspace.prepareRelationProposal(id: proposal.id, operationID: UUID()) }
    let reopened = try WikiWorkspace(root: f.root, localStateDirectory: f.base.appendingPathComponent("State"))
    #expect(try await reopened.relationProposalStatus(id: proposal.id).state == .rejected)
    #expect(try await reopened.relationProposalHistory(documentID: "a").count == 1)
    await reopened.close(); await f.workspace.close()
  }

  @Test(arguments: ["target", "ontology", "source"])
  func proposalApprovalRejectsChangesToEitherSourceOrRules(kind: String) async throws {
    let f = try await proposalFixture(); defer { f.remove() }
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    let proposal = try #require(try await service.suggestRelations(documentID: "a", predicate: "related").first)
    let before = try Data(contentsOf: f.root.appendingPathComponent("notes/a.md"))
    let plan = try await f.workspace.prepareRelationProposal(id: proposal.id, operationID: UUID())
    let path = kind == "ontology" ? "_ontology.md" : kind == "target" ? "notes/b.md" : "notes/a.md"
    let url = f.root.appendingPathComponent(path)
    var changed = try Data(contentsOf: url); changed.append(Data("External change\n".utf8)); try changed.write(to: url)
    #expect(try await f.workspace.relationProposalStatus(id: proposal.id).state == .stale)
    await #expect(throws: WikiError.changedSource) { try await f.workspace.executeRelationProposal(id: proposal.id, plan: plan) }
    if kind != "source" { #expect(try Data(contentsOf: f.root.appendingPathComponent("notes/a.md")) == before) }
    else { #expect(try Data(contentsOf: url) == changed) }
    await f.workspace.close()
  }

  @Test func receiptRecoversAcceptedAndUncertainProposalsWithoutReplay() async throws {
    let f = try await proposalFixture(); defer { f.remove() }
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    let proposal = try #require(try await service.suggestRelations(documentID: "a", predicate: "related").first)
    let op = UUID()
    let plan = try await f.workspace.prepareRelationProposal(id: proposal.id, operationID: op)
    #expect(try await f.workspace.relationProposalStatus(id: proposal.id).state == .prepared)
    let receipt = try await f.workspace.executeRelationProposal(id: proposal.id, plan: plan, idempotencyKey: "approved")
    let saved = try Data(contentsOf: f.root.appendingPathComponent("notes/a.md"))
    // A model/policy migration must never hide a committed or uncertain write.
    try removeProposalPolicy(proposal.id, fixture: f)
    let reopened = try WikiWorkspace(root: f.root, localStateDirectory: f.base.appendingPathComponent("State"))
    let status = try await reopened.relationProposalStatus(id: proposal.id)
    #expect(status.state == .accepted)
    #expect(status.receipt?.sourceRevision == receipt.sourceRevision)
    await #expect(throws: (any Error).self) { try await reopened.prepareRelationProposal(id: proposal.id, operationID: UUID()) }
    // Simulate a durable intent with no receipt: inspection must block any replay.
    let receiptURL = f.base.appendingPathComponent("State/OperationReceipts/\(op.uuidString).json")
    try FileManager.default.removeItem(at: receiptURL)
    #expect(try await reopened.relationProposalStatus(id: proposal.id).state == .uncertain)
    await #expect(throws: (any Error).self) { try await reopened.prepareRelationProposal(id: proposal.id, operationID: UUID()) }
    #expect(try Data(contentsOf: f.root.appendingPathComponent("notes/a.md")) == saved)
    await reopened.close(); await f.workspace.close()
  }

  @Test func obsoletePreparedProposalCannotApplyAfterPolicyMigration() async throws {
    let f = try await proposalFixture(); defer { f.remove() }
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    let proposal = try #require(try await service.suggestRelations(documentID: "a", predicate: "related").first)
    let before = try Data(contentsOf: f.root.appendingPathComponent("notes/a.md"))
    let plan = try await f.workspace.prepareRelationProposal(id: proposal.id, operationID: UUID())
    try removeProposalPolicy(proposal.id, fixture: f)
    #expect(try await f.workspace.relationProposalStatus(id: proposal.id).state == .stale)
    await #expect(throws: WikiError.changedSource) { try await f.workspace.prepareRelationProposal(id: proposal.id, operationID: UUID()) }
    await #expect(throws: WikiError.changedSource) { try await f.workspace.executeRelationProposal(id: proposal.id, plan: plan) }
    #expect(try Data(contentsOf: f.root.appendingPathComponent("notes/a.md")) == before)
    await f.workspace.close()
  }

  @Test func proposalsCannotBeAdoptedByAnotherSourceLocationWithTheSameWorkspaceID() async throws {
    let f = try await proposalFixture(); defer { f.remove() }
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    let proposal = try #require(try await service.suggestRelations(documentID: "a", predicate: "related").first)
    let otherRoot = f.base.appendingPathComponent("OtherSource")
    try FileManager.default.copyItem(at: f.root, to: otherRoot)
    let other = try WikiWorkspace(root: otherRoot, localStateDirectory: f.base.appendingPathComponent("State"))
    await #expect(throws: (any Error).self) { try await other.relationProposalStatus(id: proposal.id) }
    await #expect(throws: (any Error).self) { try await other.prepareRelationProposal(id: proposal.id, operationID: UUID()) }
    await other.close(); await f.workspace.close()
  }

  @Test func proposalStorageCannotFollowASymlinkIntoOriginalSources() async throws {
    let f = try await proposalFixture(); defer { f.remove() }
    let state = f.base.appendingPathComponent("State")
    try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("RelationProposals"), withDestinationURL: f.root)
    let before = try Data(contentsOf: f.root.appendingPathComponent("notes/a.md"))
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    await #expect(throws: (any Error).self) { try await service.suggestRelations(documentID: "a", predicate: "related") }
    #expect(try Data(contentsOf: f.root.appendingPathComponent("notes/a.md")) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).allSatisfy { !$0.hasSuffix(".json") })
    await f.workspace.close()
  }

  @Test func generationRequiresDeclaredRulesAndExcludesUntypedTargets() async throws {
    let f = try await proposalFixture(); defer { f.remove() }
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    await #expect(throws: (any Error).self) { try await service.suggestRelations(documentID: "a", predicate: "part_of") }
    try f.write("---\ntype: note\n---\n# Unidentified\nConcurrent operations respond to cancellation and preserve their current progress.\n", path: "notes/b.md")
    #expect(try await service.suggestRelations(documentID: "a", predicate: "related").isEmpty)
    try FileManager.default.removeItem(at: f.root.appendingPathComponent("_ontology.md"))
    await #expect(throws: (any Error).self) { try await service.suggestRelations(documentID: "a", predicate: "related") }
    await #expect(throws: (any Error).self) { try await f.workspace.relationProposalStatus(id: "../source") }
    await f.workspace.close()
  }

  @Test func rejectedOrSubstitutedPreparedPlansCannotApply() async throws {
    let f = try await proposalFixture(); defer { f.remove() }
    let service = WikiSearchService(workspace: f.workspace, workspaceID: f.workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
    let proposal = try #require(try await service.suggestRelations(documentID: "a", predicate: "related").first)
    let before = try Data(contentsOf: f.root.appendingPathComponent("notes/a.md"))
    let operation = UUID()
    let plan = try await f.workspace.prepareRelationProposal(id: proposal.id, operationID: operation)
    let substitute = try await f.workspace.prepareEdit(relativePath: "notes/a.md", expectedRevision: proposal.source.sourceRevision,
      range: nil, replacement: String(decoding: before, as: UTF8.self) + "Unapproved body\n", operationID: operation)
    await #expect(throws: (any Error).self) { try await f.workspace.executeRelationProposal(id: proposal.id, plan: substitute) }
    try await f.workspace.rejectRelationProposal(id: proposal.id)
    await #expect(throws: (any Error).self) { try await f.workspace.executeRelationProposal(id: proposal.id, plan: plan) }
    #expect(try Data(contentsOf: f.root.appendingPathComponent("notes/a.md")) == before)
    await f.workspace.close()
  }
}

private func removeProposalPolicy(_ id: String, fixture f: KnowledgeFixture) throws {
  let url = f.base.appendingPathComponent("State/RelationProposals/\(id).json")
  var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  record.removeValue(forKey: "policyVersion")
  try JSONSerialization.data(withJSONObject: record).write(to: url)
}

func proposalFixture() async throws -> KnowledgeFixture {
  let f = try KnowledgeFixture()
  try f.write("---\nkind: ontology\ntypes:\n  note: {}\nrelations:\n  related:\n    from: [note]\n    to: [note]\n---\n", path: "_ontology.md")
  for (id,title) in [("a","Cancelling concurrent tasks"),("b","Stopping parallel work")] {
    try f.write("---\nid: \(id)\ntype: note\n---\n# \(title)\nConcurrent operations respond to cancellation and preserve their current progress.\n", path: "notes/\(id).md")
  }
  return f
}
