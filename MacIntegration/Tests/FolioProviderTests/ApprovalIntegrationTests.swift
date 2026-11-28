import Foundation
import SEMIControl
import SEMICore
import FolioKnowledgeApple
import FolioSemanticModels
import FolioKnowledge
import FolioProvider
import Testing

@Test @MainActor func realProviderUsesSEMIAuthorityAndDurableReceipt() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WikiApproval-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let root = directory.appendingPathComponent("source")
  try WikiWorkspace.create(at: root, name: "Approval fixture")
  let path = "notes/a.md"; let file = root.appendingPathComponent(path)
  let old = Data("---\nid: a\n---\n# Original\n".utf8); try old.write(to: file)
  let workspace = try WikiWorkspace(root: root, localStateDirectory: directory.appendingPathComponent("state"))
  let snapshot = try await workspace.refresh()
  let provider = WikiCapabilityProvider(service: WikiSearchService(workspace: workspace, workspaceID: snapshot.workspace.id))
  let registry = ControlPlaneRegistry()
  _ = try await registry.register(provider.registration(bundleIdentifier: "com.axient.Folio"), provider: provider)
  let automation = ControlPlaneAutomation(registry: registry)
  let authority = ControlAuthority(automation: automation)
  let run = UUID(); try authority.beginIntent(run)
  let command = try #require(try await automation.commands().first { $0.id.hasSuffix("/wiki.edit") })
  let replacement = "---\nid: a\n---\n# Approved source\n"
  let input = String(decoding: try JSONSerialization.data(withJSONObject: ["path": path,
    "expected_revision": SourceDigest.sha256(old), "replacement": replacement], options: [.sortedKeys]), as: UTF8.self)
  let access = try authority.accessRequest(command: command, inputJSON: input, intentRevision: run, destination: nil)
  var request = access.presentation()
  try authority.presentConsent(request, access: access)
  #expect(try authority.resolveConsent(id: request.id, approved: false) == nil)
  #expect(try Data(contentsOf: file) == old)
  request = access.presentation()
  try authority.presentConsent(request, access: access)
  let consent = try #require(try authority.resolveConsent(id: request.id, approved: true))
  try authority.authorizeAccess(access, consent: consent)
  let candidate = try await authority.prepare(command: command, inputJSON: access.inputJSON, intentRevision: run)
  #expect(try Data(contentsOf: file) == old)
  #expect(candidate.plan.previewJSON.contains("Approved source"))
  let approval = ApprovalRequest(runID: run, purpose: .mutation(command: command.id),
    title: "Apply fixture", details: candidate.plan.previewJSON)
  try authority.presentConsent(approval)
  let decision = try #require(try authority.resolveConsent(id: approval.id, approved: true))
  let approved = try authority.approve(candidate, consent: decision)
  let result = try await authority.execute(approved)
  #expect(result.succeeded)
  #expect(try String(contentsOf: file, encoding: .utf8) == replacement)
  let receipt = try JSONDecoder().decode(WikiWriteReceipt.self, from: Data(result.json.utf8))
  #expect(receipt.idempotencyKeySHA256 == SourceDigest.sha256(approved.approval.approvalID.uuidString))
  #expect(try await workspace.operationStatus(receipt.operationID).state == .committed)
  await #expect(throws: (any Error).self) { try await authority.execute(approved) }
}

@Test func providerVerifiesEvidenceAndReportsChangesWithoutMutatingSource() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WikiEvidence-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let root = directory.appendingPathComponent("source")
  try WikiWorkspace.create(at: root, name: "Evidence fixture")
  let file = root.appendingPathComponent("notes/a.md")
  let source = Data("---\nid: a\n---\n# Source\nActual evidence\n".utf8)
  try source.write(to: file)
  let workspace = try WikiWorkspace(root: root, localStateDirectory: directory.appendingPathComponent("state"))
  let snapshot = try await workspace.refresh()
  let document = try #require(snapshot.documents.first)
  let reference = WikiEvidenceReference(workspaceID: snapshot.workspace.id, document: document,
    section: try #require(document.sections.first))
  let provider = WikiCapabilityProvider(service: WikiSearchService(workspace: workspace, workspaceID: snapshot.workspace.id))
  struct Input: Encodable { let references: [WikiEvidenceReference] }
  func input(_ references: [WikiEvidenceReference]) throws -> String {
    String(decoding: try JSONEncoder().encode(Input(references: references)), as: UTF8.self)
  }
  let result = try await provider.read(capabilityID: "wiki.verify_evidence", inputJSON: input([reference]), operationID: UUID())
  #expect(result.succeeded)
  let report = try JSONDecoder().decode(WikiEvidenceVerification.self, from: Data(result.json.utf8))
  #expect(report.allCurrent)
  #expect(try Data(contentsOf: file) == source)
  let changed = Data("---\nid: a\n---\n# Changed externally\n".utf8)
  try changed.write(to: file)
  let stale = try await provider.read(capabilityID: "wiki.verify_evidence", inputJSON: input([reference]), operationID: UUID())
  let staleReport = try JSONDecoder().decode(WikiEvidenceVerification.self, from: Data(stale.json.utf8))
  #expect(staleReport.items[0].state == .changed)
  #expect(!staleReport.allCurrent)
  #expect(try Data(contentsOf: file) == changed)
  await #expect(throws: (any Error).self) {
    try await provider.read(capabilityID: "wiki.verify_evidence", inputJSON: input(Array(repeating: reference, count: 101)), operationID: UUID())
  }
  await #expect(throws: (any Error).self) {
    try await provider.read(capabilityID: "wiki.verify_evidence", inputJSON: #"{"references":[],"unexpected":true}"#, operationID: UUID())
  }
  await workspace.close()
}

@Test @MainActor func semanticProposalRequiresRealSEMIAccessAndExactMutationApproval() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WikiSemanticApproval-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let root = directory.appendingPathComponent("source")
  try WikiWorkspace.create(at: root, name: "Local semantic approval")
  try Data("---\nkind: ontology\ntypes:\n  note: {}\nrelations:\n  related:\n    from: [note]\n    to: [note]\n---\n".utf8).write(to: root.appendingPathComponent("_ontology.md"))
  for id in ["a", "b"] {
    try Data("---\nid: \(id)\ntype: note\n---\n# Concurrent work \(id)\nConcurrent operations respond to cancellation and preserve progress.\n".utf8)
      .write(to: root.appendingPathComponent("notes/\(id).md"))
  }
  let file = root.appendingPathComponent("notes/a.md")
  let before = try Data(contentsOf: file)
  let state = directory.appendingPathComponent("state")
  let workspace = try WikiWorkspace(root: root, localStateDirectory: state)
  let service = WikiSearchService(workspace: workspace, workspaceID: workspace.workspaceID, localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
  let provider = WikiCapabilityProvider(service: service)
  let search = try await provider.read(capabilityID: "wiki.semantic_search",
    inputJSON: #"{"query":"Parallel tasks stop when cancelled."}"#, operationID: UUID())
  let report = try JSONDecoder().decode(WikiSemanticSearchReport.self, from: Data(search.json.utf8))
  #expect(!report.matches.isEmpty)
  #expect(report.relevanceComplete == true)
  #expect(report.matches.allSatisfy { ($0.relevanceScore ?? -.infinity) >= WikiLocalSemanticSearch.minimumRelevanceScore })
  let suggested = try await provider.read(capabilityID: "wiki.suggest_relations",
    inputJSON: #"{"document_id":"a","predicate":"related"}"#, operationID: UUID())
  let proposal = try #require(try JSONDecoder().decode([WikiRelationProposal].self, from: Data(suggested.json.utf8)).first)
  #expect(try Data(contentsOf: file) == before)
  let registry = ControlPlaneRegistry()
  _ = try await registry.register(provider.registration(bundleIdentifier: "com.axient.Folio"), provider: provider)
  let automation = ControlPlaneAutomation(registry: registry)
  let authority = ControlAuthority(automation: automation)
  let run = UUID(); try authority.beginIntent(run)
  let command = try #require(try await automation.commands().first { $0.id.hasSuffix("/wiki.accept_relation_proposal") })
  let input = "{\"proposal_id\":\"\(proposal.id)\"}"
  let access = try authority.accessRequest(command: command, inputJSON: input, intentRevision: run, destination: nil)
  let accessRequest = access.presentation()
  try authority.presentConsent(accessRequest, access: access)
  let consent = try #require(try authority.resolveConsent(id: accessRequest.id, approved: true))
  try authority.authorizeAccess(access, consent: consent)
  let candidate = try await authority.prepare(command: command, inputJSON: access.inputJSON, intentRevision: run)
  #expect(try Data(contentsOf: file) == before)
  #expect(candidate.plan.previewJSON.contains("related"))
  let denied = ApprovalRequest(runID: run, purpose: .mutation(command: command.id), title: "Cancel", details: candidate.plan.previewJSON)
  try authority.presentConsent(denied)
  #expect(try authority.resolveConsent(id: denied.id, approved: false) == nil)
  #expect(try Data(contentsOf: file) == before)
  let request = ApprovalRequest(runID: run, purpose: .mutation(command: command.id), title: "Apply reviewed relation", details: candidate.plan.previewJSON)
  try authority.presentConsent(request)
  let decision = try #require(try authority.resolveConsent(id: request.id, approved: true))
  let approved = try authority.approve(candidate, consent: decision)
  let result = try await authority.execute(approved)
  #expect(result.succeeded)
  #expect(try await workspace.refresh().relations.count == 1)
  let receipt = try JSONDecoder().decode(WikiWriteReceipt.self, from: Data(result.json.utf8))
  #expect(receipt.idempotencyKeySHA256 == SourceDigest.sha256(approved.approval.approvalID.uuidString))
  let reopened = try WikiWorkspace(root: root, localStateDirectory: state)
  #expect(try await reopened.relationProposalStatus(id: proposal.id).state == .accepted)
  await #expect(throws: (any Error).self) { try await authority.execute(approved) }
  let history = try await provider.read(capabilityID: "wiki.relation_proposal", inputJSON: input, operationID: UUID())
  #expect(try JSONDecoder().decode(WikiRelationProposalStatus.self, from: Data(history.json.utf8)).state == .accepted)
  await reopened.close(); await workspace.close()
}

@Test func providerKnowledgeLookupReturnsOriginalQuotesAndRejectsUnknownFields() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioKnowledgeCapability-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let root = directory.appendingPathComponent("source")
  try WikiWorkspace.create(at: root, name: "Knowledge capability")
  let file = root.appendingPathComponent("notes/source.md")
  let original = Data("---\nid: source\n---\n# Source\nFictional material factor equals seven under condition Z.\n".utf8)
  try original.write(to: file)
  let workspace = try WikiWorkspace(root: root, localStateDirectory: directory.appendingPathComponent("state"))
  let provider = WikiCapabilityProvider(service: WikiSearchService(workspace: workspace, workspaceID: workspace.workspaceID))
  let result = try await provider.read(capabilityID: "wiki.knowledge_search",
    inputJSON: #"{"question":"Fictional","document_id":"source"}"#, operationID: UUID())
  let answer = try JSONDecoder().decode(WikiKnowledgeAnswer.self, from: Data(result.json.utf8))
  let evidence = try #require(answer.evidence.first)
  #expect(!answer.semanticUsed && answer.evidence.count == 1)
  #expect(evidence.source.documentID == "source" && evidence.text.contains("condition Z"))
  struct EvidenceInput: Encodable { let evidence: WikiKnowledgeEvidence }
  let evidenceInput = String(decoding: try JSONEncoder().encode(EvidenceInput(evidence: evidence)), as: UTF8.self)
  let read = try await provider.read(capabilityID: "wiki.read_knowledge_evidence", inputJSON: evidenceInput, operationID: UUID())
  #expect(try JSONDecoder().decode(WikiKnowledgeEvidence.self, from: Data(read.json.utf8)) == evidence)
  for (capability, input) in [
    ("wiki.knowledge_search", #"{"question":"Fictional","unexpected":true}"#),
    ("wiki.concept", #"{"concept_id":"factor","unexpected":true}"#),
    ("wiki.concept_operation", "{\"operation_id\":\"\(UUID())\",\"unexpected\":true}"),
    ("wiki.read_knowledge_evidence", String(evidenceInput.dropLast()) + ",\"unexpected\":true}")
  ] {
    await #expect(throws: (any Error).self) {
      try await provider.read(capabilityID: capability, inputJSON: input, operationID: UUID())
    }
  }
  await #expect(throws: (any Error).self) {
    try await provider.prepare(capabilityID: "wiki.save_concept",
      inputJSON: #"{"concept":{},"unexpected":true}"#, operationID: UUID())
  }
  #expect(try Data(contentsOf: file) == original)
  try Data("---\nid: source\n---\n# Changed\nDifferent original.\n".utf8).write(to: file)
  await #expect(throws: WikiError.changedSource) {
    try await provider.read(capabilityID: "wiki.read_knowledge_evidence", inputJSON: evidenceInput, operationID: UUID())
  }
  await workspace.close()
}

@Test @MainActor func conceptSaveUsesSEMIAuthorityAndSeparatesCommitFromCurrentEvidence() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioConceptCapability-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let root = directory.appendingPathComponent("source")
  try WikiWorkspace.create(at: root, name: "Concept capability")
  let sourceFile = root.appendingPathComponent("notes/source.md")
  let original = Data("---\nid: source\n---\n# Source\nFictional material factor equals seven under condition Z.\n".utf8)
  try original.write(to: sourceFile)
  let workspace = try WikiWorkspace(root: root, localStateDirectory: directory.appendingPathComponent("state"))
  let service = WikiSearchService(workspace: workspace, workspaceID: workspace.workspaceID)
  let evidence = try #require(try await service.knowledgeAnswer("Fictional").evidence.first)
  let concept = WikiKnowledgeConcept(id: "factor", domain: "fictional fixture",
    labels: [WikiConceptLabel(language: "ko", preferred: "가상 물성 계수"),
      WikiConceptLabel(language: "en", preferred: "fictional material factor")],
    mentions: [WikiKnowledgeConceptMention(evidence: evidence, isDefinition: true)])
  let provider = WikiCapabilityProvider(service: service)
  let registry = ControlPlaneRegistry()
  _ = try await registry.register(provider.registration(bundleIdentifier: "com.axient.Folio"), provider: provider)
  let automation = ControlPlaneAutomation(registry: registry)
  let authority = ControlAuthority(automation: automation)
  let run = UUID(); try authority.beginIntent(run)
  let command = try #require(try await automation.commands().first { $0.id.hasSuffix("/wiki.save_concept") })
  struct Input: Encodable { let concept: WikiKnowledgeConcept }
  let input = String(decoding: try JSONEncoder().encode(Input(concept: concept)), as: UTF8.self)
  let access = try authority.accessRequest(command: command, inputJSON: input, intentRevision: run, destination: nil)
  let accessRequest = access.presentation()
  try authority.presentConsent(accessRequest, access: access)
  let consent = try #require(try authority.resolveConsent(id: accessRequest.id, approved: true))
  try authority.authorizeAccess(access, consent: consent)
  let candidate = try await authority.prepare(command: command, inputJSON: access.inputJSON, intentRevision: run)
  let conceptFile = root.appendingPathComponent("notes/factor.md")
  #expect(!FileManager.default.fileExists(atPath: conceptFile.path))
  #expect(try Data(contentsOf: sourceFile) == original)
  let denied = ApprovalRequest(runID: run, purpose: .mutation(command: command.id), title: "Cancel", details: candidate.plan.previewJSON)
  try authority.presentConsent(denied)
  #expect(try authority.resolveConsent(id: denied.id, approved: false) == nil)
  #expect(!FileManager.default.fileExists(atPath: conceptFile.path))
  let request = ApprovalRequest(runID: run, purpose: .mutation(command: command.id), title: "Save reviewed concept", details: candidate.plan.previewJSON)
  try authority.presentConsent(request)
  let decision = try #require(try authority.resolveConsent(id: request.id, approved: true))
  let approved = try authority.approve(candidate, consent: decision)
  let result = try await authority.execute(approved)
  let receipt = try JSONDecoder().decode(WikiWriteReceipt.self, from: Data(result.json.utf8))
  #expect(result.succeeded && FileManager.default.fileExists(atPath: conceptFile.path))
  #expect(receipt.idempotencyKeySHA256 == SourceDigest.sha256(approved.approval.approvalID.uuidString))
  #expect(try Data(contentsOf: sourceFile) == original)

  struct ConceptResult: Decodable { let concept: WikiKnowledgeConcept; let currentness: String; let atomicSnapshot: Bool }
  let direct = try await provider.read(capabilityID: "wiki.concept", inputJSON: #"{"concept_id":"factor"}"#, operationID: UUID())
  let stored = try JSONDecoder().decode(ConceptResult.self, from: Data(direct.json.utf8))
  #expect(stored.concept == concept && stored.currentness == "current" && !stored.atomicSnapshot)
  let lookup = try await provider.read(capabilityID: "wiki.knowledge_search",
    inputJSON: #"{"question":"가상 물성 계수"}"#, operationID: UUID())
  let answer = try JSONDecoder().decode(WikiKnowledgeAnswer.self, from: Data(lookup.json.utf8))
  #expect(answer.evidence.contains(evidence) && !answer.semanticUsed)
  let operationInput = "{\"operation_id\":\"\(receipt.operationID)\"}"
  struct OperationResult: Decodable { let operation: WikiOperationStatus; let sourceObserved: Bool; let currentness: String }
  let observed = try await provider.read(capabilityID: "wiki.concept_operation", inputJSON: operationInput, operationID: UUID())
  let committed = try JSONDecoder().decode(OperationResult.self, from: Data(observed.json.utf8))
  #expect(committed.operation.state == .committed && committed.sourceObserved && committed.currentness == "current")
  try Data("---\nid: source\n---\n# Changed\nDifferent original.\n".utf8).write(to: sourceFile)
  let afterChange = try await provider.read(capabilityID: "wiki.concept_operation", inputJSON: operationInput, operationID: UUID())
  let historical = try JSONDecoder().decode(OperationResult.self, from: Data(afterChange.json.utf8))
  #expect(historical.operation.state == .committed && historical.sourceObserved && historical.currentness == "changed")
  await #expect(throws: WikiError.changedSource) {
    try await provider.read(capabilityID: "wiki.concept", inputJSON: #"{"concept_id":"factor"}"#, operationID: UUID())
  }
  await #expect(throws: (any Error).self) { try await authority.execute(approved) }
  await workspace.close()
}
