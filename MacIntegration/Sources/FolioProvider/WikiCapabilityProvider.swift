import Foundation
import SEMIAppIntegration
import SEMIControl
import SEMICore
import FolioKnowledgeApple
import FolioKnowledge

public actor WikiCapabilityProvider: AppCapabilityProvider {
  public typealias Connection = SEMIAppIntegration.Connection
  public let service: WikiSearchService
  private struct Prepared: Sendable { let capability: String; let edit: WikiPreparedEdit; let publicPlan: AppCapabilityPlan; let proposalID: String? }
  private var prepared: [String: Prepared] = [:]
  private var calls: [UUID: Task<AutomationResult, any Error>] = [:]
  private var preparations: [UUID: Task<AppCapabilityPlan, any Error>] = [:]

  public init(service: WikiSearchService) { self.service = service }

  public nonisolated static let capabilities: [AppCapabilityDescriptor] = WikiCapabilityContract.all.map(\.descriptor)

  public nonisolated func registration(bundleIdentifier: String) -> AppRegistration {
    AppRegistration(identity: AppIdentity(bundleIdentifier: bundleIdentifier, displayName: "Folio"), capabilities: Self.capabilities)
  }

  public nonisolated func connect(bundleIdentifier: String, endpointURL: URL? = nil) async throws -> Connection {
    if let endpointURL {
      return try await SEMIAppIntegration.connect(registration: registration(bundleIdentifier: bundleIdentifier), provider: self, endpointURL: endpointURL)
    }
    return try await SEMIAppIntegration.connect(registration: registration(bundleIdentifier: bundleIdentifier), provider: self)
  }

  public func read(capabilityID: String, inputJSON: String, operationID: UUID) async throws -> AutomationResult {
    guard calls[operationID] == nil, preparations[operationID] == nil, calls.count + preparations.count < 64 else {
      throw WikiError.conflict("Operation is already active or admission is full.")
    }
    let task = Task { try await self.performRead(capabilityID, input: inputJSON) }
    calls[operationID] = task; defer { calls.removeValue(forKey: operationID) }
    return try await task.value
  }

  private func performRead(_ capability: String, input: String) async throws -> AutomationResult {
    try Task.checkCancellation()
    guard let contract = WikiCapabilityContract.find(capability), contract.descriptor.kind == .read else {
      throw WikiError.invalidSource("Unknown wiki read capability.")
    }
    switch capability {
    case "wiki.search":
      struct Input: Decodable { let query: String; let limit: Int? }
      let request: Input = try contract.decode(input)
      guard (1...10).contains(request.limit ?? 3) else { throw WikiError.invalidSource("Search limit must be 1...10.") }
      let result = try await service.search(request.query, limit: request.limit ?? 3)
      let snapshot = try await service.workspace.projection.snapshot()
      return try encode(EvidenceEnvelope(root: await service.workspace.root.path, query: request.query, result: result, snapshot: snapshot))
    case "wiki.semantic_search":
      struct Input: Decodable { let query: String; let limit: Int? }
      let request: Input = try contract.decode(input)
      return try encode(try await service.semanticSearch(request.query, limit: request.limit ?? 10))
    case "wiki.suggest_relations":
      struct Input: Decodable { let document_id: String; let predicate: String; let limit: Int? }
      let request: Input = try contract.decode(input)
      return try encode(try await service.suggestRelations(documentID: request.document_id, predicate: request.predicate, limit: request.limit ?? 5))
    case "wiki.relation_proposal":
      struct Input: Decodable { let proposal_id: String }
      let request: Input = try contract.decode(input)
      return try encode(try await service.workspace.relationProposalStatus(id: request.proposal_id))
    case "wiki.read":
      struct Input: Decodable { let reference: WikiEvidenceReference }
      let request: Input = try contract.decode(input)
      let text = try await service.workspace.read(request.reference)
      let snapshot = try await service.workspace.refresh()
      guard let document = snapshot.documents.first(where: { $0.id == request.reference.documentID }),
        document.revision == request.reference.sourceRevision else { throw WikiError.changedSource }
      return try encode(EvidenceEnvelope(root: await service.workspace.root.path,
        source: EvidenceSource(reference: request.reference, title: document.title,
          heading: document.sections.first(where: { $0.id == request.reference.sectionID })?.headingPath ?? [],
          excerpt: text, snapshot: snapshot)))
    case "wiki.verify_evidence":
      struct Input: Decodable { let references: [WikiEvidenceReference] }
      let request: Input = try contract.decode(input)
      return try encode(try await service.workspace.verifyEvidence(request.references))
    case "wiki.source":
      struct Input: Decodable { let path: String; let revision: String; let start_line: Int?; let maximum_lines: Int? }
      let request: Input = try contract.decode(input)
      let bytes = try await service.workspace.source(relativePath: request.path)
      guard SourceDigest.sha256(bytes) == request.revision else { throw WikiError.changedSource }
      let excerpt = try WikiMarkdownParser.excerpt(bytes: bytes, startLine: request.start_line ?? 1, maximumLines: request.maximum_lines ?? 40)
      return try encode(excerpt)
    case "wiki.relations":
      struct Input: Decodable { let document_id: String }
      let request: Input = try contract.decode(input)
      let snapshot = try await service.workspace.refresh()
      struct Result: Encodable { let relations: [WikiRelation]; let truncated: Bool; let revision: String; let coverageComplete: Bool }
      let edges = snapshot.relations(for: request.document_id)
      return try encode(Result(relations: Array(edges.prefix(100)), truncated: edges.count > 100,
        revision: snapshot.revision, coverageComplete: snapshot.coverageComplete))
    case "wiki.status":
      struct Input: Decodable {}
      let _: Input = try contract.decode(input)
      let snapshot = try await service.workspace.refresh()
      struct Status: Encodable {
        let workspace: WikiWorkspaceIdentity; let revision: String; let documents: Int
        let diagnostics: [WikiDiagnostic]; let diagnosticsTruncated: Bool; let coverageComplete: Bool; let semanticState: String
        let ontologyRevision: String?; let ontologyUnavailable: Bool
      }
      return try encode(Status(workspace: snapshot.workspace, revision: snapshot.revision, documents: snapshot.documents.count,
        diagnostics: Array(snapshot.diagnostics.prefix(20)), diagnosticsTruncated: snapshot.diagnostics.count > 20,
        coverageComplete: snapshot.coverageComplete, semanticState: await service.semanticState(),
        ontologyRevision: snapshot.ontology?.revision, ontologyUnavailable: snapshot.ontologyUnavailable))
    case "wiki.operation":
      struct Input: Decodable { let operation_id: UUID }
      let request: Input = try contract.decode(input)
      return try encode(try await service.workspace.operationStatus(request.operation_id))
    default: throw WikiError.invalidSource("Unknown wiki read capability.")
    }
  }

  public func prepare(capabilityID: String, inputJSON: String, operationID: UUID) async throws -> AppCapabilityPlan {
    guard let contract = WikiCapabilityContract.find(capabilityID), contract.descriptor.kind == .mutation,
      calls[operationID] == nil, preparations[operationID] == nil,
      prepared.count + preparations.count < 32, !prepared.values.contains(where: { $0.edit.operationID == operationID }) else {
      throw WikiError.conflict("Unknown mutation or operation already prepared/active.")
    }
    let task = Task { try await self.prepareEdit(contract, input: inputJSON, operationID: operationID) }
    preparations[operationID] = task; defer { preparations.removeValue(forKey: operationID) }
    return try await task.value
  }

  private func prepareEdit(_ contract: WikiCapabilityContract, input: String, operationID: UUID) async throws -> AppCapabilityPlan {
    let capability = contract.descriptor.id
    struct Input: Decodable { let path: String; let expected_revision: String?; let range: WikiSourceRange?; let replacement: String }
    let request: Input
    var proposalID: String?
    var proposalEdit: WikiPreparedEdit?
    if capability == "wiki.accept_relation_proposal" {
      struct ProposalInput: Decodable { let proposal_id: String }
      let input: ProposalInput = try contract.decode(input)
      let edit = try await service.workspace.prepareRelationProposal(id: input.proposal_id, operationID: operationID)
      proposalID = input.proposal_id; proposalEdit = edit
      request = Input(path: edit.relativePath, expected_revision: edit.expectedRevision, range: nil, replacement: edit.after)
    }
    else if capability == "wiki.edit" { request = try contract.decode(input) }
    else {
      struct RelationInput: Decodable { let path: String; let expected_revision: String; let predicate: String; let target_id: String }
      let relation: RelationInput = try contract.decode(input)
      let bytes = try await service.workspace.source(relativePath: relation.path)
      guard SourceDigest.sha256(bytes) == relation.expected_revision else { throw WikiError.changedSource }
      let patch = try WikiMarkdownEditor.addRelation(bytes: bytes, predicate: relation.predicate, targetID: relation.target_id)
      request = Input(path: relation.path, expected_revision: relation.expected_revision,
        range: patch?.range ?? WikiSourceRange(lowerBound: 0, upperBound: 0, startLine: 1, endLine: 1), replacement: patch?.replacement ?? "")
    }
    let edit: WikiPreparedEdit
    if let proposalEdit { edit = proposalEdit }
    else {
      edit = try await service.workspace.prepareEdit(relativePath: request.path,
        expectedRevision: request.expected_revision, range: request.range, replacement: request.replacement, operationID: operationID)
    }
    try Task.checkCancellation()
    struct Preview: Encodable {
      let operationID: UUID
      let path: String; let previousRevision: String?; let resultingRevision: String
      let range: WikiSourceRange?; let before: String; let after: String
    }
    let before: String
    if let range = request.range { before = String(decoding: try range.extract(from: Data(edit.before.utf8)), as: UTF8.self) }
    else { before = edit.before }
    let preview = Preview(operationID: operationID, path: edit.relativePath, previousRevision: edit.expectedRevision,
      resultingRevision: edit.resultRevision, range: request.range, before: before, after: request.replacement)
    let previewJSON = try json(preview)
    guard previewJSON.utf8.count <= 200000 else { throw WikiError.invalidSource("Use a narrow source patch for a large note.") }
    let plan = AppCapabilityPlan(token: UUID().uuidString,
      target: AppEffectTarget(id: "\(edit.workspaceID.uuidString)/\(SourceDigest.sha256(edit.relativePath))", revision: edit.expectedRevision), previewJSON: previewJSON)
    prepared[plan.token] = Prepared(capability: capability, edit: edit, publicPlan: plan, proposalID: proposalID)
    return plan
  }

  public func execute(capabilityID: String, plan: AppCapabilityPlan, idempotencyKey: String, operationID: UUID) async throws -> AutomationResult {
    guard let stored = prepared[plan.token], stored.capability == capabilityID, stored.publicPlan == plan,
      stored.edit.operationID == operationID, !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 256,
      calls[operationID] == nil else { throw WikiError.changedSource }
    let task = Task {
      // The domain keeps its operation intent/receipt separately from the disposable projection.
      let receipt: WikiWriteReceipt
      if let id = stored.proposalID {
        receipt = try await self.service.workspace.executeRelationProposal(id: id, plan: stored.edit, idempotencyKey: idempotencyKey)
      } else { receipt = try await self.service.workspace.execute(stored.edit, idempotencyKey: idempotencyKey) }
      return try self.encode(receipt, committed: true)
    }
    calls[operationID] = task
    defer { calls.removeValue(forKey: operationID); prepared.removeValue(forKey: plan.token) }
    return try await task.value
  }

  public func cancel(operationID: UUID) async {
    let call = calls[operationID]; let preparation = preparations[operationID]
    call?.cancel(); preparation?.cancel()
    if let call { _ = try? await call.value }
    if let preparation { _ = try? await preparation.value }
    prepared = prepared.filter { $0.value.edit.operationID != operationID }
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  private func encode<T: Encodable>(_ value: T, committed: Bool = false) throws -> AutomationResult {
    if !committed { try Task.checkCancellation() }
    let json = try json(value)
    guard json.utf8.count <= 128 * 1024 else { throw WikiError.invalidSource("Wiki result exceeds its bounded receipt budget.") }
    return AutomationResult(outcome: .succeeded, json: json)
  }
}
