import Foundation
import SEMIControl
import SEMICore
import FolioKnowledge
import FolioKnowledgeApple
import FolioProvider
import Testing

@Test func assertionReadsKeepFacetsAndRejectOutOfScopeOrChangedOriginals() async throws {
  let fixture = try await AssertionCapabilityFixture()
  defer { fixture.remove() }
  let assertion = fixture.assertion(id: "factor")
  let plan = try await fixture.workspace.prepareKnowledgeAssertion(assertion, operationID: UUID())
  _ = try await fixture.workspace.executeKnowledgeAssertion(plan)
  let outside = WikiKnowledgeAssertion(id: "factor-with-context", statement: assertion.statement,
    polarity: assertion.polarity, conceptIDs: assertion.conceptIDs, conditions: assertion.conditions,
    value: assertion.value, unit: assertion.unit, edition: assertion.edition,
    evidence: assertion.evidence + [.init(evidence: fixture.outside, role: .context)])
  let outsidePlan = try await fixture.workspace.prepareKnowledgeAssertion(outside, operationID: UUID())
  _ = try await fixture.workspace.executeKnowledgeAssertion(outsidePlan)

  let direct = try await fixture.provider.read(capabilityID: "wiki.assertion",
    inputJSON: #"{"assertion_id":"factor"}"#, operationID: UUID())
  let read = try JSONDecoder().decode(AssertionCapabilityResult.self, from: Data(direct.json.utf8))
  #expect(read.assertion == assertion && read.currentness == "current" && !read.atomicSnapshot)
  #expect(read.assertion.conditions[0].text == "condition Z")
  #expect(read.assertion.value?.text == "42" && read.assertion.unit?.text == "W/(m K)")
  #expect(read.assertion.edition?.text == "Edition 2")

  let scoped = try await fixture.provider.read(capabilityID: "wiki.assertions",
    inputJSON: #"{"concept_id":"flux","document_id":"source"}"#, operationID: UUID())
  let list = try JSONDecoder().decode(AssertionCapabilityList.self, from: Data(scoped.json.utf8))
  #expect(list.assertions.map(\.assertion.id) == ["factor"])
  #expect(list.assertions.allSatisfy { $0.assertion.evidence.allSatisfy { $0.evidence.source.documentID == "source" } })
  #expect(!scoped.json.contains("Unrelated archival context"))
  #expect(list.complete && !list.atomicSnapshot)
  let all = try await fixture.provider.read(capabilityID: "wiki.assertions", inputJSON: "{}", operationID: UUID())
  #expect(try JSONDecoder().decode(AssertionCapabilityList.self, from: Data(all.json.utf8)).assertions.count == 2)
  let facets = try await fixture.provider.read(capabilityID: "wiki.assertions",
    inputJSON: #"{"document_id":"source","unit":"W/(m K)","edition":"Edition 2","query":"coefficient"}"#, operationID: UUID())
  #expect(try JSONDecoder().decode(AssertionCapabilityList.self, from: Data(facets.json.utf8)).assertions.map(\.assertion.id) == ["factor"])
  let wrongUnit = try await fixture.provider.read(capabilityID: "wiki.assertions",
    inputJSON: #"{"unit":"MW/(m K)","edition":"Edition 2"}"#, operationID: UUID())
  #expect(try JSONDecoder().decode(AssertionCapabilityList.self, from: Data(wrongUnit.json.utf8)).assertions.isEmpty)
  let wrongCase = try await fixture.provider.read(capabilityID: "wiki.assertions",
    inputJSON: #"{"unit":"w/(m K)"}"#, operationID: UUID())
  #expect(try JSONDecoder().decode(AssertionCapabilityList.self, from: Data(wrongCase.json.utf8)).assertions.isEmpty)
  for (capability, input) in [
    ("wiki.assertion", #"{"assertion_id":"factor","unexpected":true}"#),
    ("wiki.assertions", #"{"document_id":"source","unexpected":true}"#),
    ("wiki.assertions", #"{"document_id":"missing"}"#),
    ("wiki.assertions", #"{"limit":0}"#),
    ("wiki.assertions", #"{"limit":101}"#),
    ("wiki.assertion_operation", "{\"operation_id\":\"\(UUID())\",\"unexpected\":true}")
  ] {
    await #expect(throws: (any Error).self) {
      try await fixture.provider.read(capabilityID: capability, inputJSON: input, operationID: UUID())
    }
  }
  // A valid collection can exceed the wire budget even though each assertion
  // fits its storage contract. Return complete records, never a clipped quote.
  for index in 0..<18 {
    let item = fixture.assertion(id: "bulk-\(index)")
    let next = try await fixture.workspace.prepareKnowledgeAssertion(item, operationID: UUID())
    _ = try await fixture.workspace.executeKnowledgeAssertion(next)
  }
  let bounded = try await fixture.provider.read(capabilityID: "wiki.assertions", inputJSON: "{}", operationID: UUID())
  let partial = try JSONDecoder().decode(AssertionCapabilityList.self, from: Data(bounded.json.utf8))
  #expect(bounded.json.utf8.count <= 128 * 1024)
  #expect(!partial.complete && !partial.diagnostics.isEmpty)
  #expect(!partial.assertions.isEmpty && partial.assertions.count < 20)
  #expect(partial.assertions.allSatisfy { $0.assertion.evidence.first?.evidence == fixture.quote })
  #expect(try Data(contentsOf: fixture.sourceFile) == fixture.original)
  try Data("---\nid: source\n---\n# Changed\nA different source replaces the recorded original.\n".utf8)
    .write(to: fixture.sourceFile)
  await #expect(throws: WikiError.changedSource) {
    try await fixture.provider.read(capabilityID: "wiki.assertion",
      inputJSON: #"{"assertion_id":"factor"}"#, operationID: UUID())
  }
  let after = try await fixture.provider.read(capabilityID: "wiki.assertions", inputJSON: "{}", operationID: UUID())
  let stale = try JSONDecoder().decode(AssertionCapabilityList.self, from: Data(after.json.utf8))
  #expect(stale.assertions.isEmpty && !stale.complete && !stale.diagnostics.isEmpty)
  await fixture.workspace.close()
}

@Test @MainActor func assertionSaveUsesExactSEMIAuthorityAndSeparatesReceiptFromCurrentEvidence() async throws {
  let fixture = try await AssertionCapabilityFixture()
  defer { fixture.remove() }
  let assertion = fixture.assertion(id: "reviewed-factor")
  let input = try fixture.input(assertion)
  let descriptor = try #require(WikiCapabilityProvider.capabilities.first { $0.id == "wiki.save_assertion" })
  let schema = try #require(try JSONSerialization.jsonObject(with: Data(descriptor.schemaJSON.utf8)) as? [String: Any])
  let envelope = try #require(schema["properties"] as? [String: Any])
  let declaration = try #require(envelope["assertion"] as? [String: Any])
  let fields = try #require(declaration["properties"] as? [String: Any])
  let native = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(assertion)) as? [String: Any])
  #expect(Set(fields.keys) == Set(native.keys) && fields["recordID"] != nil && fields["id"] == nil)
  let definitions = try #require(schema["$defs"] as? [String: Any])
  #expect(definitions["AssertionText"] != nil && definitions["AssertionCitation"] != nil)
  var unknown = try #require(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
  var payload = try #require(unknown["assertion"] as? [String: Any])
  payload["uncitedClaim"] = "This is silently ignored only by a non-strict decoder."
  unknown["assertion"] = payload
  let unknownInput = String(decoding: try JSONSerialization.data(withJSONObject: unknown), as: UTF8.self)
  await #expect(throws: (any Error).self) {
    try await fixture.provider.prepare(capabilityID: "wiki.save_assertion", inputJSON: unknownInput, operationID: UUID())
  }
  let registry = ControlPlaneRegistry()
  _ = try await registry.register(fixture.provider.registration(bundleIdentifier: "com.axient.Folio"), provider: fixture.provider)
  let automation = ControlPlaneAutomation(registry: registry)
  let authority = ControlAuthority(automation: automation)
  let run = UUID(); try authority.beginIntent(run)
  let command = try #require(try await automation.commands().first { $0.id.hasSuffix("/wiki.save_assertion") })
  let access = try authority.accessRequest(command: command, inputJSON: input, intentRevision: run, destination: nil)
  let accessRequest = access.presentation()
  try authority.presentConsent(accessRequest, access: access)
  let consent = try #require(try authority.resolveConsent(id: accessRequest.id, approved: true))
  try authority.authorizeAccess(access, consent: consent)
  let candidate = try await authority.prepare(command: command, inputJSON: access.inputJSON, intentRevision: run)
  let file = fixture.root.appendingPathComponent("notes/reviewed-factor.md")
  #expect(!FileManager.default.fileExists(atPath: file.path))
  #expect(candidate.plan.previewJSON.contains("condition Z") && candidate.plan.previewJSON.contains("Edition 2"))
  let denied = ApprovalRequest(runID: run, purpose: .mutation(command: command.id), title: "Cancel", details: candidate.plan.previewJSON)
  try authority.presentConsent(denied)
  #expect(try authority.resolveConsent(id: denied.id, approved: false) == nil)
  #expect(!FileManager.default.fileExists(atPath: file.path))
  let request = ApprovalRequest(runID: run, purpose: .mutation(command: command.id), title: "Save reviewed assertion", details: candidate.plan.previewJSON)
  try authority.presentConsent(request)
  let decision = try #require(try authority.resolveConsent(id: request.id, approved: true))
  let approved = try authority.approve(candidate, consent: decision)
  let result = try await authority.execute(approved)
  let receipt = try JSONDecoder().decode(WikiWriteReceipt.self, from: Data(result.json.utf8))
  #expect(result.succeeded && FileManager.default.fileExists(atPath: file.path))
  #expect(receipt.idempotencyKeySHA256 == SourceDigest.sha256(approved.approval.approvalID.uuidString))
  #expect(try Data(contentsOf: fixture.sourceFile) == fixture.original)
  let operationInput = "{\"operation_id\":\"\(receipt.operationID)\"}"
  let status = try await fixture.provider.read(capabilityID: "wiki.assertion_operation", inputJSON: operationInput, operationID: UUID())
  let committed = try JSONDecoder().decode(AssertionCapabilityOperation.self, from: Data(status.json.utf8))
  #expect(committed.assertionID == assertion.id && committed.operation.state == .committed)
  #expect(committed.sourceObserved && committed.currentness == "current")
  try Data("---\nid: source\n---\n# Changed\nThe original changed after the approved save.\n".utf8).write(to: fixture.sourceFile)
  let history = try await fixture.provider.read(capabilityID: "wiki.assertion_operation", inputJSON: operationInput, operationID: UUID())
  let historical = try JSONDecoder().decode(AssertionCapabilityOperation.self, from: Data(history.json.utf8))
  #expect(historical.operation.state == .committed && historical.sourceObserved && historical.currentness == "changed")
  await #expect(throws: (any Error).self) { try await authority.execute(approved) }
  await fixture.workspace.close()
}

@Test func assertionReviewExposesChangedConceptsWithoutAdmittingStaleKnowledgeOrChangedOriginals() async throws {
  let fixture = try await AssertionCapabilityFixture()
  defer { fixture.remove() }
  let assertion = fixture.assertion(id: "review-factor")
  let plan = try await fixture.workspace.prepareKnowledgeAssertion(assertion, operationID: UUID())
  _ = try await fixture.workspace.executeKnowledgeAssertion(plan)
  let file = fixture.root.appendingPathComponent(plan.relativePath)
  let savedBytes = try Data(contentsOf: file)
  let input = #"{"assertion_id":"review-factor"}"#
  let descriptor = try #require(WikiCapabilityProvider.capabilities.first { $0.id == "wiki.assertion_review" })
  #expect(descriptor.kind == .read)
  let initial = try await fixture.provider.read(capabilityID: descriptor.id, inputJSON: input, operationID: UUID())
  let initialReview = try JSONDecoder().decode(AssertionCapabilityReview.self, from: Data(initial.json.utf8))
  #expect(initialReview.purpose == "review" && !initialReview.requiresConceptReview)
  #expect(initialReview.originalEvidenceCurrent && initialReview.conceptChanges.isEmpty && !initialReview.atomicSnapshot)
  #expect(Set(initialReview.currentConceptRevisions.keys) == ["flux"])
  await #expect(throws: (any Error).self) {
    try await fixture.provider.read(capabilityID: descriptor.id,
      inputJSON: #"{"assertion_id":"review-factor","unexpected":true}"#, operationID: UUID())
  }

  let concept = try await fixture.workspace.readKnowledgeConcept(id: "flux")
  let conceptFile = fixture.root.appendingPathComponent(concept.relativePath)
  try (Data(contentsOf: conceptFile) + Data("\n<!-- reviewed concept metadata changed -->\n".utf8)).write(to: conceptFile)
  await #expect(throws: WikiError.changedSource) {
    try await fixture.provider.read(capabilityID: "wiki.assertion", inputJSON: input, operationID: UUID())
  }
  let result = try await fixture.provider.read(capabilityID: descriptor.id, inputJSON: input, operationID: UUID())
  let review = try JSONDecoder().decode(AssertionCapabilityReview.self, from: Data(result.json.utf8))
  #expect(review.purpose == "review" && review.requiresConceptReview && review.originalEvidenceCurrent)
  #expect(review.assertion == assertion && review.relativePath == plan.relativePath && review.revision == plan.resultRevision)
  #expect(review.conceptChanges.map(\.conceptID) == ["flux"] && review.conceptChanges.map(\.state) == ["changed"])
  let currentConcept = try #require(review.conceptChanges.first?.currentConcept)
  #expect(currentConcept.id == "flux" && currentConcept.labels.first?.preferred == "flux coefficient")
  #expect(currentConcept.mentions.first?.evidence == fixture.quote)
  #expect(review.currentConceptRevisions["flux"] != initialReview.currentConceptRevisions["flux"])
  let raw = try #require(try JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
  #expect(raw["currentness"] == nil)
  let current = try await fixture.provider.read(capabilityID: "wiki.assertions", inputJSON: "{}", operationID: UUID())
  let list = try JSONDecoder().decode(AssertionCapabilityList.self, from: Data(current.json.utf8))
  #expect(list.assertions.isEmpty && !list.complete)
  #expect(try Data(contentsOf: file) == savedBytes)
  #expect(try Data(contentsOf: fixture.sourceFile) == fixture.original)

  func saveInput(_ revisions: [String: String]) throws -> String {
    var fields = try #require(try JSONSerialization.jsonObject(with: Data(fixture.input(assertion).utf8)) as? [String: Any])
    fields["path"] = plan.relativePath
    fields["expected_revision"] = plan.resultRevision
    fields["expected_concept_revisions"] = revisions
    return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
  }
  try (Data(contentsOf: conceptFile) + Data("\n<!-- concept changed again after review -->\n".utf8)).write(to: conceptFile)
  await #expect(throws: WikiError.changedSource) {
    try await fixture.provider.prepare(capabilityID: "wiki.save_assertion",
      inputJSON: saveInput(review.currentConceptRevisions), operationID: UUID())
  }
  #expect(try Data(contentsOf: file) == savedBytes)
  let refreshed = try await fixture.provider.read(capabilityID: descriptor.id, inputJSON: input, operationID: UUID())
  let refreshedReview = try JSONDecoder().decode(AssertionCapabilityReview.self, from: Data(refreshed.json.utf8))
  #expect(refreshedReview.currentConceptRevisions["flux"] != review.currentConceptRevisions["flux"])
  let reviewedPlan = try await fixture.provider.prepare(capabilityID: "wiki.save_assertion",
    inputJSON: saveInput(refreshedReview.currentConceptRevisions), operationID: UUID())
  let preview = try #require(try JSONSerialization.jsonObject(with: Data(reviewedPlan.previewJSON.utf8)) as? [String: Any])
  #expect(preview["path"] as? String == plan.relativePath)
  #expect(try Data(contentsOf: file) == savedBytes) // A new plan still needs separate approval.

  try (fixture.original + Data("\nChanged original after concept review.\n".utf8)).write(to: fixture.sourceFile)
  await #expect(throws: WikiError.changedSource) {
    try await fixture.provider.read(capabilityID: descriptor.id, inputJSON: input, operationID: UUID())
  }
  #expect(try Data(contentsOf: file) == savedBytes)
  await fixture.workspace.close()
}

private struct AssertionCapabilityReview: Decodable {
  struct ConceptChange: Decodable {
    let conceptID: String
    let name: String
    let state: String
    let currentConcept: WikiKnowledgeConcept?
  }
  let purpose: String
  let assertion: WikiKnowledgeAssertion
  let relativePath: String
  let revision: String
  let originalEvidenceCurrent: Bool
  let requiresConceptReview: Bool
  let conceptChanges: [ConceptChange]
  let currentConceptRevisions: [String: String]
  let atomicSnapshot: Bool
}

private struct AssertionCapabilityResult: Decodable {
  let assertion: WikiKnowledgeAssertion
  let relativePath: String
  let revision: String
  let currentness: String
  let atomicSnapshot: Bool
}
private struct AssertionCapabilityList: Decodable {
  let assertions: [AssertionCapabilityResult]
  let complete: Bool
  let diagnostics: [String]
  let atomicSnapshot: Bool
}
private struct AssertionCapabilityOperation: Decodable {
  let assertionID: String
  let operation: WikiOperationStatus
  let sourceObserved: Bool
  let currentness: String
}

private struct AssertionCapabilityFixture {
  let directory: URL
  let root: URL
  let sourceFile: URL
  let original: Data
  let workspace: WikiWorkspace
  let provider: WikiCapabilityProvider
  let quote: WikiKnowledgeEvidence
  let outside: WikiKnowledgeEvidence

  init() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioAssertionCapability-\(UUID())")
    root = directory.appendingPathComponent("source")
    try WikiWorkspace.create(at: root, name: "Assertion capability")
    sourceFile = root.appendingPathComponent("notes/source.md")
    let context = String(repeating: "The fictional record keeps its literal conditions and does not infer omitted information. ", count: 10)
    original = Data(("---\nid: source\n---\n# Source\nThe fictional flux coefficient equals 42 W/(m K) only under condition Z. Edition 2.\n\n" + context + "\n").utf8)
    try original.write(to: sourceFile)
    try Data("---\nid: outside\n---\n# Outside\nUnrelated archival context belongs to a different document.\n".utf8)
      .write(to: root.appendingPathComponent("notes/outside.md"))
    workspace = try WikiWorkspace(root: root, localStateDirectory: directory.appendingPathComponent("state"))
    let service = WikiSearchService(workspace: workspace, workspaceID: workspace.workspaceID)
    quote = try #require(try await service.knowledgeAnswer("fictional", documentID: "source").evidence.first)
    outside = try #require(try await service.knowledgeAnswer("archival", documentID: "outside").evidence.first)
    let concept = WikiKnowledgeConcept(id: "flux", labels: [.init(language: "en", preferred: "flux coefficient")],
      mentions: [.init(evidence: quote)])
    let plan = try await workspace.prepareKnowledgeConcept(concept, operationID: UUID())
    _ = try await workspace.executeKnowledgeConcept(plan)
    provider = WikiCapabilityProvider(service: service)
  }

  func assertion(id: String) -> WikiKnowledgeAssertion {
    func text(_ value: String) -> WikiKnowledgeAssertionText {
      .init(text: value, citations: [.init(evidenceID: quote.id, quote: quote.text)])
    }
    return .init(id: id, statement: text("The fictional flux coefficient equals 42 W/(m K) only under condition Z."),
      polarity: .affirmed, conceptIDs: ["flux"], conditions: [text("condition Z")], value: text("42"),
      unit: text("W/(m K)"), edition: text("Edition 2"), evidence: [.init(evidence: quote)])
  }

  func input(_ assertion: WikiKnowledgeAssertion) throws -> String {
    struct Input: Encodable { let assertion: WikiKnowledgeAssertion }
    return String(decoding: try JSONEncoder().encode(Input(assertion: assertion)), as: UTF8.self)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
