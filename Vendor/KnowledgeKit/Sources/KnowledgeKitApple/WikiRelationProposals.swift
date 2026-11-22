import Foundation
import FolioKnowledge

public struct WikiRelationProposal: Codable, Sendable, Identifiable {
  public let id: String
  public let workspaceRevision: String
  public let predicate: String
  public let source: WikiEvidenceReference
  public let target: WikiEvidenceReference
  public let targetTitle: String
  public let modelID: String
  public let similarity: Double
}

public struct WikiRelationProposalStatus: Codable, Sendable {
  public enum State: String, Codable, Sendable { case proposed, prepared, rejected, stale, uncertain, accepted }
  public let proposal: WikiRelationProposal
  public let state: State
  public let operationID: UUID?
  public let receipt: WikiWriteReceipt?
}

private struct ProposalRecord: Codable {
  let version: Int
  let sourceScope: String
  let policyVersion: Int?
  let proposal: WikiRelationProposal
  var rejected: Bool
  var operationID: UUID?
  var resultRevision: String?
}

extension WikiSearchService {
  /// Similarity supplies candidates only. The caller selects a meaning-preserving
  /// association predicate; type constraints and exact evidence are mandatory.
  public func suggestRelations(documentID: String, predicate: String, limit: Int = 5) async throws -> [WikiRelationProposal] {
    guard (1...10).contains(limit) else { throw WikiError.invalidSource("Proposal limit must be 1...10.") }
    let snapshot = try await workspace.refresh()
    guard snapshot.coverageComplete, let ontology = snapshot.ontology,
      let constraint = ontology.relations[predicate],
      let doc = snapshot.documents.first(where: { $0.id == documentID }), doc.stableID != nil,
      let type = doc.type, constraint.from.contains(type), let section = doc.sections.first else {
      throw WikiError.unavailable("현재 원문과 유형 규칙을 확인한 뒤, 이 문서에 허용된 관계를 선택해 주세요.")
    }
    let evidence = WikiEvidenceReference(workspaceID: snapshot.workspace.id, document: doc, section: section)
    let query = String(String.UnicodeScalarView(section.sourceText.unicodeScalars.prefix(120)))
    let eligible = Set(snapshot.documents.filter { target in
      guard target.id != documentID, target.stableID != nil, let type = target.type, constraint.to.contains(type) else { return false }
      return !snapshot.relations.contains { $0.sourceID == documentID && $0.targetID == target.id && $0.predicate == predicate }
    }.map(\.id))
    guard !eligible.isEmpty else { return [] }
    let report = try await semanticSearch(query, limit: 20, documentIDs: eligible, purpose: .similarity)
    guard report.sourceRevision == snapshot.revision else { throw WikiError.changedSource }
    var proposals: [WikiRelationProposal] = []
    for match in report.matches where match.reference.documentID != documentID && match.similarity >= 0.88 {
      try Task.checkCancellation()
      guard let target = snapshot.documents.first(where: { $0.id == match.reference.documentID }), target.stableID != nil,
        let targetType = target.type, constraint.to.contains(targetType),
        !snapshot.relations.contains(where: { $0.sourceID == documentID && $0.targetID == target.id && $0.predicate == predicate }),
        !proposals.contains(where: { $0.target.documentID == target.id }) else { continue }
      let proposal = try await workspace.recordRelationProposal(workspaceRevision: snapshot.revision,
        predicate: predicate, source: evidence, target: match.reference, targetTitle: target.title,
        modelID: report.modelID, similarity: match.similarity)
      let status = try await workspace.relationProposalStatus(id: proposal.id)
      if status.state == .proposed { proposals.append(proposal) }
      if proposals.count == limit { break }
    }
    return proposals
  }
}

extension WikiWorkspace {
  private static let proposalPolicyVersion = 3
  private var proposalsDirectory: URL { receiptDirectory.deletingLastPathComponent().appendingPathComponent("RelationProposals", isDirectory: true) }

  func recordRelationProposal(workspaceRevision: String, predicate: String, source: WikiEvidenceReference,
    target: WikiEvidenceReference, targetTitle: String, modelID: String, similarity: Double
  ) async throws -> WikiRelationProposal {
    let snapshot = try await refresh()
    guard snapshot.revision == workspaceRevision, snapshot.coverageComplete else { throw WikiError.changedSource }
    _ = try read([source, target])
    let scope = SourceDigest.sha256(root.standardizedFileURL.resolvingSymlinksInPath().path)
    let binding = [String(Self.proposalPolicyVersion), scope, workspaceID.uuidString, workspaceRevision, predicate, source.sectionID, source.sourceRevision,
      target.sectionID, target.sourceRevision, modelID]
    let id = SourceDigest.sha256(try JSONEncoder().encode(binding))
    let proposal = WikiRelationProposal(id: id, workspaceRevision: workspaceRevision, predicate: predicate,
      source: source, target: target, targetTitle: targetTitle, modelID: modelID, similarity: similarity)
    if FileManager.default.fileExists(atPath: proposalsDirectory.appendingPathComponent(id + ".json").path) {
      return try proposalRecord(id).proposal
    }
    if FileManager.default.fileExists(atPath: proposalsDirectory.path) {
      guard try FileManager.default.contentsOfDirectory(atPath: proposalsDirectory.path).filter({ $0.hasSuffix(".json") }).count < 1000 else {
        throw WikiError.unavailable("Proposal storage reached 1,000 records. Preserve operation records and review history before generating more.")
      }
    }
    try storeProposal(ProposalRecord(version: 1, sourceScope: scope, policyVersion: Self.proposalPolicyVersion, proposal: proposal, rejected: false, operationID: nil, resultRevision: nil), previous: nil)
    return proposal
  }

  public func relationProposalHistory(documentID: String, limit: Int = 20) async throws -> [WikiRelationProposalStatus] {
    try requireOpen()
    guard (1...100).contains(limit) else { throw WikiError.invalidSource("History limit must be 1...100.") }
    guard FileManager.default.fileExists(atPath: proposalsDirectory.path) else { return [] }
    let files = try FileManager.default.contentsOfDirectory(atPath: proposalsDirectory.path).filter { $0.hasSuffix(".json") }.sorted()
    guard files.count <= 1000 else { throw WikiError.unavailable("Proposal history exceeds the 1,000-record review budget.") }
    var results: [WikiRelationProposalStatus] = []
    for file in files {
      try Task.checkCancellation()
      let id = String(file.dropLast(5))
      if try proposalRecord(id).proposal.source.documentID == documentID {
        results.append(try await relationProposalStatus(id: id))
      }
      if results.count == limit { break }
    }
    return results
  }

  public func relationProposalStatus(id: String) async throws -> WikiRelationProposalStatus {
    try requireOpen()
    let record = try proposalRecord(id)
    if let operation = record.operationID {
      let status = try operationStatus(operation)
      if status.state == .committed { return .init(proposal: record.proposal, state: .accepted, operationID: operation, receipt: status.receipt) }
      if status.state == .uncertain { return .init(proposal: record.proposal, state: .uncertain, operationID: operation, receipt: nil) }
    }
    let snapshot = try await refresh()
    let state: WikiRelationProposalStatus.State = record.rejected ? .rejected
      : snapshot.revision != record.proposal.workspaceRevision || !snapshot.coverageComplete || record.policyVersion != Self.proposalPolicyVersion ? .stale
      : record.operationID == nil ? .proposed : .prepared
    return .init(proposal: record.proposal, state: state, operationID: record.operationID, receipt: nil)
  }

  public func rejectRelationProposal(id: String) throws {
    try requireOpen()
    guard !proposalOperations.contains(id) else { throw WikiError.conflict("Proposal operation is active.") }
    var record = try proposalRecord(id)
    if let operation = record.operationID {
      guard try operationStatus(operation).state == .notObserved else {
        throw WikiError.conflict("Inspect the existing operation receipt before changing this proposal.")
      }
    }
    let previous = try proposalBytes(id)
    record.rejected = true
    try storeProposal(record, previous: previous)
  }

  /// Durable binding to the exact operation is published BEFORE the plan leaves
  /// this actor. A new service instance can recover the outcome through receipts.
  public func prepareRelationProposal(id: String, operationID: UUID) async throws -> WikiPreparedEdit {
    try requireOpen()
    guard proposalOperations.insert(id).inserted else { throw WikiError.conflict("Proposal operation is active.") }
    defer { proposalOperations.remove(id) }
    var record = try proposalRecord(id)
    guard record.policyVersion == Self.proposalPolicyVersion else { throw WikiError.changedSource }
    guard !record.rejected else { throw WikiError.conflict("Proposal was rejected.") }
    if let oldOperation = record.operationID {
      guard try operationStatus(oldOperation).state == .notObserved else {
        throw WikiError.conflict("Inspect the existing operation receipt; never replay an uncertain proposal.")
      }
    }
    let snapshot = try await refresh()
    guard snapshot.revision == record.proposal.workspaceRevision, snapshot.coverageComplete else { throw WikiError.changedSource }
    _ = try read([record.proposal.source, record.proposal.target])
    let bytes = try source(relativePath: record.proposal.source.relativePath)
    guard let patch = try WikiMarkdownEditor.addRelation(bytes: bytes, predicate: record.proposal.predicate,
      targetID: record.proposal.target.documentID) else { throw WikiError.conflict("Relation already exists.") }
    let plan = try await prepareEdit(relativePath: record.proposal.source.relativePath,
      expectedRevision: record.proposal.source.sourceRevision, range: patch.range, replacement: patch.replacement, operationID: operationID)
    guard plan.workspaceRevision == record.proposal.workspaceRevision else { throw WikiError.changedSource }
    try Task.checkCancellation()
    let previous = try proposalBytes(id)
    record.operationID = operationID
    record.resultRevision = plan.resultRevision
    try storeProposal(record, previous: previous)
    return plan
  }

  public func executeRelationProposal(id: String, plan: WikiPreparedEdit, idempotencyKey: String? = nil) async throws -> WikiWriteReceipt {
    try requireOpen()
    guard proposalOperations.insert(id).inserted else { throw WikiError.conflict("Proposal operation is active.") }
    defer { proposalOperations.remove(id) }
    let record = try proposalRecord(id)
    guard record.policyVersion == Self.proposalPolicyVersion, !record.rejected, record.operationID == plan.operationID, record.resultRevision == plan.resultRevision,
      plan.workspaceID == workspaceID, plan.workspaceRevision == record.proposal.workspaceRevision,
      plan.relativePath == record.proposal.source.relativePath,
      plan.expectedRevision == record.proposal.source.sourceRevision else { throw WikiError.changedSource }
    return try await execute(plan, idempotencyKey: idempotencyKey)
  }

  private func proposalBytes(_ id: String) throws -> Data {
    guard id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw WikiError.invalidSource("Invalid proposal identifier.")
    }
    return try CoordinatedFiles.read(root: proposalsDirectory, path: id + ".json", maximumBytes: 65536)
  }
  private func proposalRecord(_ id: String) throws -> ProposalRecord {
    try requireOpen()
    let record = try JSONDecoder().decode(ProposalRecord.self, from: proposalBytes(id))
    guard record.version == 1, record.sourceScope == SourceDigest.sha256(root.standardizedFileURL.resolvingSymlinksInPath().path), record.proposal.id == id,
      record.proposal.source.workspaceID == workspaceID, record.proposal.target.workspaceID == workspaceID else { throw WikiError.changedSource }
    return record
  }
  private func storeProposal(_ record: ProposalRecord, previous: Data?) throws {
    try requireOpen()
    guard proposalsDirectory.standardizedFileURL.path == proposalsDirectory.resolvingSymlinksInPath().path else { throw WikiError.invalidPath("Proposal storage cannot follow a symlink.") }
    try WikiLocalStorage.createDirectory(proposalsDirectory)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(record)
    guard bytes.count <= 65536 else { throw WikiError.invalidSource("Proposal record exceeds 64 KiB.") }
    try CoordinatedFiles.write(root: proposalsDirectory, path: record.proposal.id + ".json",
      expectedRevision: previous.map(SourceDigest.sha256), bytes: bytes)
  }
}
