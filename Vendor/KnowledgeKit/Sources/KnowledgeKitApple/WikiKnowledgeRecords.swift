import Foundation
import FolioKnowledge

/// Current source and historical publication are independent states for every knowledge record.
public enum WikiKnowledgeRecordCurrentness: String, Sendable { case current, changed, inaccessible, unknown }

public struct WikiKnowledgeAssertionRecord: Sendable {
  public let assertion: WikiKnowledgeAssertion
  public let relativePath: String
  public let revision: String
  public let record: WikiOntologyRecord
}

public struct WikiKnowledgeAssertionInventory: Sendable {
  public let records: [WikiKnowledgeAssertionRecord]
  public let fingerprint: String
  public let diagnostics: [String]
  public let complete: Bool
}

public struct WikiKnowledgeAssertionOperationStatus: Sendable {
  public let assertionID: String
  public let relativePath: String
  public let resultRevision: String
  public let operation: WikiOperationStatus
  public let sourceObserved: Bool
  public let currentness: WikiKnowledgeRecordCurrentness
}

struct WikiKnowledgeConceptBinding: Codable, Equatable, Sendable {
  let relativePath: String
  let revision: String
}

enum WikiKnowledgeRecordPayload: Equatable {
  case concept(WikiKnowledgeConcept)
  case assertion(WikiKnowledgeAssertion)

  var id: String { switch self { case .concept(let value): value.id; case .assertion(let value): value.id } }
  var role: String { switch self { case .concept: "concept"; case .assertion: "assertion" } }
  var accepted: Bool { switch self { case .concept(let value): value.state == .accepted; case .assertion(let value): value.state == .accepted } }
  var evidence: [WikiKnowledgeEvidence] {
    switch self { case .concept(let value): value.mentions.map(\.evidence); case .assertion(let value): value.allEvidence }
  }
  var conceptIDs: [String] { if case .assertion(let value) = self { value.conceptIDs } else { [] } }

  func validate() throws {
    switch self { case .concept(let value): _ = try value.validated(); case .assertion(let value): _ = try value.validated() }
  }
  static func decode(_ record: WikiOntologyRecord) throws -> Self {
    guard record.schemaVersion == 1 else { throw WikiError.unavailable("지원하지 않는 지식 레코드 버전입니다.") }
    switch record.role {
    case "concept": return .concept(try WikiKnowledgeConcept.decode(record))
    case "assertion": return .assertion(try WikiKnowledgeAssertion.decode(record))
    default: throw WikiError.unavailable("지원하지 않는 지식 레코드 종류입니다.")
    }
  }
  func data() throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    switch self { case .concept(let value): return try encoder.encode(value); case .assertion(let value): return try encoder.encode(value) }
  }
  func evidenceDigest() throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    // Preserve the exact O2 durable digest, which includes isDefinition.
    switch self {
    case .concept(let value): return SourceDigest.sha256(try encoder.encode(value.mentions))
    case .assertion(let value): return SourceDigest.sha256(try encoder.encode(value.evidence))
    }
  }
}

/// The concept key and missing conceptBindings decode the existing O2 operation format unchanged.
private struct KnowledgeRecordOperation: Codable {
  let version: Int
  let sourceScope: String
  let workspaceID: UUID
  let operationID: UUID
  let workspaceRevision: String
  let relativePath: String
  let expectedRevision: String?
  let resultRevision: String
  let concept: WikiKnowledgeConcept?
  let assertion: WikiKnowledgeAssertion?
  let evidenceDigest: String
  let conceptBindings: [String: WikiKnowledgeConceptBinding]?
  let extraction: KnowledgeRecordExtraction?

  var payload: WikiKnowledgeRecordPayload {
    get throws {
      switch (concept, assertion) {
      case (.some(let value), nil): return .concept(value)
      case (nil, .some(let value)): return .assertion(value)
      default: throw WikiError.changedSource
      }
    }
  }
}

struct KnowledgeRecordExtraction: Codable, Equatable, Sendable {
  let proposalID: String
  let providerID: String
  let inputDigest: String
  let policyVersion: Int
  let schemaVersion: Int
}

struct WikiKnowledgeRawRecord {
  let payload: WikiKnowledgeRecordPayload
  let relativePath: String
  let revision: String
  let record: WikiOntologyRecord
  let bytes: Data
}

extension WikiWorkspace {
  func knowledgeRecord(_ document: WikiDocument, role: String? = nil) throws -> WikiKnowledgeRawRecord? {
    let bytes = try knowledgeRead(path: document.relativePath, maximumBytes: 256 * 1024)
    guard SourceDigest.sha256(bytes) == document.revision else { throw WikiError.changedSource }
    guard let record = try WikiOntologyRecord.read(bytes: bytes) else { return nil }
    guard try WikiMarkdownParser.isDerivedKnowledgeNote(bytes: bytes), document.stableID == record.recordID else {
      throw WikiError.changedSource
    }
    if let role, record.role != role, ["concept", "assertion"].contains(record.role) { return nil }
    let payload = try WikiKnowledgeRecordPayload.decode(record)
    if case .assertion = payload { _ = try assertionRenderedRange(payload, in: bytes, path: document.relativePath) }
    return .init(payload: payload, relativePath: document.relativePath, revision: document.revision, record: record, bytes: bytes)
  }

  /// No retrieval or generation is needed when the caller already has the stable assertion ID.
  public func readKnowledgeAssertion(id: String) async throws -> WikiKnowledgeAssertionRecord {
    let snapshot = try await refresh()
    try requireKnowledgeAccess()
    guard let document = snapshot.documents.first(where: { $0.id == id }), let raw = try knowledgeRecord(document, role: "assertion"),
      case .assertion(let assertion) = raw.payload else { throw WikiError.unavailable("현재 자료함에서 주장을 읽을 수 없습니다.") }
    try validateKnowledgeConceptBindings(try conceptBindings(in: raw.record, ids: assertion.conceptIDs))
    _ = try readKnowledgeEvidence(assertion.allEvidence)
    guard SourceDigest.sha256(try knowledgeRead(path: raw.relativePath, maximumBytes: 256 * 1024)) == raw.revision else { throw WikiError.changedSource }
    return .init(assertion: assertion, relativePath: raw.relativePath, revision: raw.revision, record: raw.record)
  }

  /// Checks exact content before any listing limit. An incomplete scan cannot prove absence.
  /// Matching content is still validated against current originals and Concept revisions.
  public func matchingKnowledgeAssertion(_ assertion: WikiKnowledgeAssertion) async throws -> WikiKnowledgeAssertionRecord? {
    _ = try assertion.validated()
    let digest = try assertion.contentDigest()
    let snapshot = try await refresh()
    try requireKnowledgeAccess()
    var unreadable = !snapshot.coverageComplete || !snapshot.diagnostics.isEmpty
    for document in snapshot.documents.sorted(by: { $0.id < $1.id }) {
      try Task.checkCancellation()
      let raw: WikiKnowledgeRawRecord?
      do { raw = try knowledgeRecord(document, role: "assertion") }
      catch is CancellationError { throw CancellationError() }
      catch { unreadable = true; continue }
      guard let raw, case .assertion(let candidate) = raw.payload,
        try candidate.contentDigest() == digest else { continue }
      let current = try await readKnowledgeAssertion(id: candidate.id)
      guard try current.assertion.contentDigest() == digest else { throw WikiError.changedSource }
      return current
    }
    try requireKnowledgeAccess()
    guard !unreadable else {
      throw WikiError.unavailable("일부 주장 기록을 읽을 수 없어 중복 여부를 확인하지 못했습니다. 자료함의 원문 상태를 확인한 뒤 다시 저장해 주세요.")
    }
    return nil
  }

  /// A selected source must contain the complete assertion evidence bundle; no partial claim is relabelled as complete.
  public func knowledgeAssertionInventory(conceptID: String? = nil, documentID: String? = nil,
    unit: String? = nil, edition: String? = nil, query: String? = nil, limit: Int = 100) async throws -> WikiKnowledgeAssertionInventory {
    guard (1...1000).contains(limit),
      conceptID.map({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }) ?? true,
      documentID.map({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }) ?? true else {
      throw WikiError.invalidSource("주장 조회 범위와 한도를 확인해 주세요.")
    }
    for filter in [unit, edition, query].compactMap({ $0 }) {
      guard !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, filter.utf8.count <= 8192, !filter.contains("\0") else { throw WikiError.invalidSource("주장 조회 조건의 문구와 길이를 확인해 주세요.") }
    }
    let snapshot = try await refresh()
    try requireKnowledgeAccess()
    if let documentID, !snapshot.documents.contains(where: { $0.id == documentID }) {
      throw WikiError.invalidSource("선택한 자료가 현재 자료함에 없습니다.")
    }
    var records: [WikiKnowledgeAssertionRecord] = []
    var diagnostics = snapshot.diagnostics.map { "\($0.path): \($0.reason)" }
    var truncated = false
    for document in snapshot.documents.sorted(by: { $0.id < $1.id }) {
      try Task.checkCancellation()
      do {
        guard let raw = try knowledgeRecord(document, role: "assertion"), case .assertion(let assertion) = raw.payload,
          assertion.state == .accepted else { continue }
        if let conceptID, !assertion.conceptIDs.contains(conceptID) { continue }
        func key(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
        if let unit, (assertion.unit?.text ?? "").precomposedStringWithCanonicalMapping
          != unit.precomposedStringWithCanonicalMapping { continue }
        if let edition, key(assertion.edition?.text ?? "") != key(edition) { continue }
        if let query {
          let texts = [assertion.statement.text] + assertion.conditions.map(\.text) + [assertion.value?.text, assertion.unit?.text, assertion.edition?.text].compactMap { $0 }
          if !texts.contains(where: { key($0).contains(key(query)) }) { continue }
        }
        if let documentID, !assertion.allEvidence.allSatisfy({ $0.source.documentID == documentID }) { continue }
        if records.count == limit { truncated = true; break }
        try validateKnowledgeConceptBindings(try conceptBindings(in: raw.record, ids: assertion.conceptIDs))
        _ = try readKnowledgeEvidence(assertion.allEvidence)
        guard SourceDigest.sha256(try knowledgeRead(path: raw.relativePath, maximumBytes: 256 * 1024)) == raw.revision else { throw WikiError.changedSource }
        records.append(.init(assertion: assertion, relativePath: raw.relativePath, revision: raw.revision, record: raw.record))
      } catch is CancellationError { throw CancellationError() }
      catch { diagnostics.append("\(document.relativePath): \(error.localizedDescription)") }
    }
    if truncated { diagnostics.append("주장 조회 한도에 도달했습니다. 범위를 좁혀 주세요.") }
    diagnostics.sort()
    try requireKnowledgeAccess()
    let fingerprint = SourceDigest.sha256(try JSONEncoder().encode([knowledgeScopeID, snapshot.revision, diagnostics.joined(separator: "\n")]))
    return .init(records: records, fingerprint: fingerprint, diagnostics: diagnostics, complete: diagnostics.isEmpty && !truncated)
  }

  public func prepareKnowledgeAssertion(_ assertion: WikiKnowledgeAssertion, relativePath: String? = nil,
    expectedRevision: String? = nil, expectedConceptRevisions: [String: String]? = nil,
    operationID: UUID) async throws -> WikiPreparedEdit {
    try await prepareKnowledgeRecord(.assertion(assertion), relativePath: relativePath,
      expectedRevision: expectedRevision, operationID: operationID,
      expectedConceptRevisions: expectedConceptRevisions)
  }

  /// The opaque read-only proposal gains persistence only after this explicit save request.
  public func prepareKnowledgeAssertion(_ proposal: WikiKnowledgeAssertionProposal, relativePath: String? = nil,
    expectedRevision: String? = nil, operationID: UUID) async throws -> WikiPreparedEdit {
    try requireKnowledgeAccess()
    guard proposal.scopeID == knowledgeScopeID, proposal.schemaVersion == 1, proposal.policyVersion == 1,
      proposal.assertion.state == .draft,
      !proposal.providerID.isEmpty, proposal.providerID.utf8.count <= 512,
      !proposal.providerID.contains(where: { $0.isNewline || $0 == "\0" }),
      [proposal.inputDigest, proposal.proposalID].allSatisfy({
        $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      }),
      Set(proposal.conceptRevisions.keys) == Set(proposal.assertion.conceptIDs) else { throw WikiError.changedSource }
    let extraction = KnowledgeRecordExtraction(proposalID: proposal.proposalID, providerID: proposal.providerID,
      inputDigest: proposal.inputDigest, policyVersion: proposal.policyVersion, schemaVersion: proposal.schemaVersion)
    return try await prepareKnowledgeRecord(.assertion(proposal.assertion.accepting()), relativePath: relativePath,
      expectedRevision: expectedRevision, operationID: operationID,
      expectedConceptRevisions: proposal.conceptRevisions, extraction: extraction)
  }

  public func executeKnowledgeAssertion(_ plan: WikiPreparedEdit, idempotencyKey: String? = nil) async throws -> WikiWriteReceipt {
    try await executeKnowledgeRecord(plan, role: "assertion", idempotencyKey: idempotencyKey)
  }

  public func knowledgeAssertionOperationStatus(operationID: UUID) throws -> WikiKnowledgeAssertionOperationStatus {
    let value = try knowledgeRecordOperationStatus(operationID, role: "assertion")
    return .init(assertionID: value.id, relativePath: value.relativePath, resultRevision: value.resultRevision,
      operation: value.operation, sourceObserved: value.sourceObserved, currentness: value.currentness)
  }

  func prepareKnowledgeRecord(_ requested: WikiKnowledgeRecordPayload, relativePath: String?,
    expectedRevision: String?, operationID: UUID, expectedConceptRevisions: [String: String]? = nil,
    extraction: KnowledgeRecordExtraction? = nil) async throws -> WikiPreparedEdit {
    try requireKnowledgeAccess()
    let key = "knowledge:" + operationID.uuidString
    guard proposalOperations.insert(key).inserted else { throw WikiError.conflict("같은 지식 기록을 저장하고 있습니다.") }
    defer { proposalOperations.remove(key) }
    try requested.validate()
    let path = try WikiPath.validate(relativePath ?? "notes/\(requested.id).md")
    guard path.hasPrefix("notes/"), ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { throw WikiError.invalidPath(path) }
    guard !["concept", "assertion"].contains(where: { FileManager.default.fileExists(atPath: knowledgeOperationURL(operationID, role: $0).path) }),
      try operationStatus(operationID).state == .notObserved else { throw WikiError.conflict("기존 저장 작업의 결과를 먼저 확인해 주세요.") }
    let oldBytes: Data?
    let old: WikiKnowledgeRawRecord?
    if let expectedRevision {
      let bytes = try knowledgeRead(path: path, maximumBytes: 256 * 1024)
      guard SourceDigest.sha256(bytes) == expectedRevision else { throw WikiError.changedSource }
      let document = try WikiMarkdownParser.document(relativePath: path, bytes: bytes)
      guard let value = try knowledgeRecord(document), value.payload.role == requested.role,
        value.payload.id == requested.id else { throw WikiError.changedSource }
      oldBytes = bytes; old = value
    } else { oldBytes = nil; old = nil }
    let payload: WikiKnowledgeRecordPayload
    if case .concept(let concept) = requested, let old, case .concept(let previous) = old.payload {
      payload = .concept(try Self.mergingKnowledgeConcept(concept, into: previous))
    } else { payload = requested }
    let bindings = try await currentKnowledgeConceptBindings(payload.conceptIDs)
    if let expectedConceptRevisions, bindings.mapValues(\.revision) != expectedConceptRevisions { throw WikiError.changedSource }
    let record = try Self.knowledgeRecordMetadata(payload, preserving: old?.record, bindings: bindings, extraction: extraction)
    let bytes: Data
    if let oldBytes, let old {
      var updated = try WikiOntologyRecord.replacingRecord(in: oldBytes, with: record)
      if case .assertion = payload {
        let range = try assertionRenderedRange(old.payload, in: updated, path: path)
        let newline = Self.knowledgeNewline(oldBytes)
        let replacement = try Self.knowledgeRecordBody(payload, path: path).replacingOccurrences(of: "\n", with: newline)
        updated = updated.prefix(range.lowerBound) + Data(replacement.utf8) + updated.suffix(from: range.upperBound)
      } else if case .concept(let value) = payload, case .concept(let previous) = old.payload {
        let oldIDs = Set(previous.mentions.map { $0.evidence.id })
        let added = value.mentions.filter { !oldIDs.contains($0.evidence.id) }.map(\.evidence)
        if !added.isEmpty {
          let newline = Self.knowledgeNewline(oldBytes)
          updated.append(contentsOf: (newline + (try Self.knowledgeCitations(added, from: path)).replacingOccurrences(of: "\n", with: newline)).utf8)
        }
      }
      bytes = updated
    } else {
      let id = String(decoding: try JSONEncoder().encode(payload.id), as: UTF8.self)
      bytes = Data(("---\nid: " + id + "\nfolio_knowledge_note: true\n" + (try record.frontmatterLine())
        + "---\n" + (try Self.knowledgeRecordBody(payload, path: path))).utf8)
    }
    guard bytes.count <= 256 * 1024 else { throw WikiError.invalidSource("지식 노트가 저장 가능한 크기를 넘습니다.") }
    _ = try WikiOntologyRecord.read(bytes: bytes)
    _ = try readKnowledgeEvidence(payload.evidence)
    let plan = try await prepareEdit(relativePath: path, expectedRevision: expectedRevision, range: nil,
      replacement: String(decoding: bytes, as: UTF8.self), operationID: operationID)
    try validateKnowledgeConceptBindings(bindings)
    _ = try readKnowledgeEvidence(payload.evidence)
    let operation = KnowledgeRecordOperation(version: 1, sourceScope: knowledgeScopeID, workspaceID: workspaceID,
      operationID: operationID, workspaceRevision: plan.workspaceRevision, relativePath: plan.relativePath,
      expectedRevision: plan.expectedRevision, resultRevision: plan.resultRevision,
      concept: { if case .concept(let value) = payload { value } else { nil } }(),
      assertion: { if case .assertion(let value) = payload { value } else { nil } }(),
      evidenceDigest: try payload.evidenceDigest(), conceptBindings: bindings, extraction: extraction)
    try storeKnowledgeOperation(operation)
    return plan
  }

  func executeKnowledgeRecord(_ plan: WikiPreparedEdit, role: String, idempotencyKey: String?) async throws -> WikiWriteReceipt {
    try requireKnowledgeAccess()
    let key = "knowledge:" + plan.operationID.uuidString
    guard proposalOperations.insert(key).inserted else { throw WikiError.conflict("같은 지식 기록을 저장하고 있습니다.") }
    defer { proposalOperations.remove(key) }
    let binding = try knowledgeOperation(plan.operationID, role: role)
    let expected = try binding.payload
    guard binding.workspaceRevision == plan.workspaceRevision, binding.workspaceID == plan.workspaceID,
      binding.relativePath == plan.relativePath, binding.expectedRevision == plan.expectedRevision,
      binding.resultRevision == plan.resultRevision, SourceDigest.sha256(plan.replacementBytes) == plan.resultRevision,
      plan.after.utf8.elementsEqual(plan.replacementBytes), try WikiMarkdownParser.isDerivedKnowledgeNote(bytes: plan.replacementBytes),
      let record = try WikiOntologyRecord.read(bytes: plan.replacementBytes) else { throw WikiError.changedSource }
    let actual = try WikiKnowledgeRecordPayload.decode(record)
    guard actual == expected, try actual.evidenceDigest() == binding.evidenceDigest,
      try conceptBindings(in: record, ids: actual.conceptIDs) == binding.conceptBindings ?? [:] else { throw WikiError.changedSource }
    if case .assertion = actual { _ = try assertionRenderedRange(actual, in: plan.replacementBytes, path: plan.relativePath) }
    return try await execute(plan, idempotencyKey: idempotencyKey, checkingEvidence: actual.evidence,
      checkingConcepts: binding.conceptBindings ?? [:])
  }

  struct KnowledgeRecordStatus {
    let id: String; let relativePath: String; let resultRevision: String
    let operation: WikiOperationStatus; let sourceObserved: Bool; let currentness: WikiKnowledgeRecordCurrentness
  }

  func knowledgeRecordOperationStatus(_ id: UUID, role: String) throws -> KnowledgeRecordStatus {
    try requireKnowledgeAccess()
    let binding = try knowledgeOperation(id, role: role)
    let payload = try binding.payload
    let status = try operationStatus(id)
    if let receipt = status.receipt {
      guard receipt.relativePath == binding.relativePath, receipt.sourceRevision == binding.resultRevision,
        receipt.previousRevision == binding.expectedRevision else { throw WikiError.changedSource }
    }
    let observed = (try? knowledgeRead(path: binding.relativePath, maximumBytes: 256 * 1024))
      .map { SourceDigest.sha256($0) == binding.resultRevision } ?? false
    let currentness: WikiKnowledgeRecordCurrentness
    do {
      try validateKnowledgeConceptBindings(binding.conceptBindings ?? [:])
      _ = try readKnowledgeEvidence(payload.evidence)
      currentness = payload.evidence.isEmpty ? .unknown : .current
    } catch is CancellationError { throw CancellationError() }
    catch WikiError.changedSource { currentness = .changed }
    catch { currentness = .inaccessible }
    return .init(id: payload.id, relativePath: binding.relativePath, resultRevision: binding.resultRevision,
      operation: status, sourceObserved: observed, currentness: currentness)
  }

  private func knowledgeOperationsDirectory(role: String) -> URL {
    receiptDirectory.deletingLastPathComponent().appendingPathComponent(role == "concept" ? "ConceptOperations" : "KnowledgeOperations", isDirectory: true)
  }
  private func knowledgeOperationURL(_ id: UUID, role: String) -> URL {
    knowledgeOperationsDirectory(role: role).appendingPathComponent(id.uuidString.lowercased() + ".json")
  }
  private func knowledgeOperation(_ id: UUID, role: String) throws -> KnowledgeRecordOperation {
    let directory = knowledgeOperationsDirectory(role: role)
    let value = try JSONDecoder().decode(KnowledgeRecordOperation.self, from: CoordinatedFiles.read(root: directory,
      path: knowledgeOperationURL(id, role: role).lastPathComponent, maximumBytes: 65536))
    let payload = try value.payload
    guard value.version == 1, value.sourceScope == knowledgeScopeID, value.workspaceID == workspaceID,
      value.operationID == id, payload.role == role, try payload.evidenceDigest() == value.evidenceDigest,
      Set(value.conceptBindings?.keys.map { $0 } ?? []) == Set(payload.conceptIDs) else { throw WikiError.changedSource }
    try payload.validate()
    return value
  }
  private func storeKnowledgeOperation(_ operation: KnowledgeRecordOperation) throws {
    try requireKnowledgeAccess()
    let payload = try operation.payload, directory = knowledgeOperationsDirectory(role: payload.role)
    guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else { throw WikiError.invalidPath("지식 작업 기록은 심볼릭 링크를 사용할 수 없습니다.") }
    try WikiLocalStorage.createDirectory(directory)
    guard try FileManager.default.contentsOfDirectory(atPath: directory.path).filter({ $0.hasSuffix(".json") }).count < 1000 else {
      throw WikiError.unavailable("지식 작업 기록이 1,000건 한도에 도달했습니다. 저장 결과를 보존한 뒤 정리해 주세요.")
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(operation)
    guard bytes.count <= 65536 else { throw WikiError.invalidSource("지식 작업 기록이 64 KiB를 넘습니다. 원문 근거를 줄여 주세요.") }
    try CoordinatedFiles.write(root: directory, path: knowledgeOperationURL(operation.operationID, role: payload.role).lastPathComponent,
      expectedRevision: nil, bytes: bytes)
  }

  private func currentKnowledgeConceptBindings(_ ids: [String]) async throws -> [String: WikiKnowledgeConceptBinding] {
    var values: [String: WikiKnowledgeConceptBinding] = [:]
    for id in ids {
      let record = try await readKnowledgeConcept(id: id)
      guard record.concept.state == .accepted else { throw WikiError.changedSource }
      values[id] = .init(relativePath: record.relativePath, revision: record.revision)
    }
    return values
  }
  func conceptBindings(in record: WikiOntologyRecord, ids: [String]) throws -> [String: WikiKnowledgeConceptBinding] {
    guard let node = record.fields["conceptBindings"] else {
      guard ids.isEmpty else { throw WikiError.changedSource }; return [:]
    }
    let bindings = try JSONDecoder().decode([String: WikiKnowledgeConceptBinding].self, from: node.encoded())
    guard Set(bindings.keys) == Set(ids) else { throw WikiError.changedSource }
    return bindings
  }

  /// Runs synchronously in the writer after refresh and immediately before its intent/publication segment.
  func validateKnowledgeConceptBindings(_ bindings: [String: WikiKnowledgeConceptBinding]) throws {
    for (id, binding) in bindings {
      try requireKnowledgeAccess()
      guard try WikiPath.validate(binding.relativePath).hasPrefix("notes/") else { throw WikiError.changedSource }
      let bytes = try knowledgeRead(path: binding.relativePath, maximumBytes: 256 * 1024)
      guard SourceDigest.sha256(bytes) == binding.revision,
        try WikiMarkdownParser.document(relativePath: binding.relativePath, bytes: bytes).stableID == id,
        let record = try WikiOntologyRecord.read(bytes: bytes),
        case .concept(let value) = try WikiKnowledgeRecordPayload.decode(record), value.state == .accepted else { throw WikiError.changedSource }
      _ = try readKnowledgeEvidence(value.mentions.map(\.evidence))
    }
  }

  private static func knowledgeRecordMetadata(_ payload: WikiKnowledgeRecordPayload, preserving old: WikiOntologyRecord?,
    bindings: [String: WikiKnowledgeConceptBinding], extraction: KnowledgeRecordExtraction?) throws -> WikiOntologyRecord {
    var fields = old?.fields ?? [:]
    guard let typed = try WikiJSONValue.parse(payload.data()).objectValue else { throw WikiError.invalidSource("지식 레코드를 직렬화하지 못했습니다.") }
    if case .assertion = payload {
      for key in ["value", "unit", "edition"] where typed[key] == nil { fields.removeValue(forKey: key) }
    }
    for (key, value) in typed { fields[key] = mergeKnowledgeJSON(value, old: fields[key]) }
    fields["schemaVersion"] = .number("1"); fields["role"] = .string(payload.role)
    if case .assertion = payload {
      fields["conceptBindings"] = try WikiJSONValue.parse(JSONEncoder().encode(bindings))
      if let extraction {
        fields["extraction"] = try WikiJSONValue.parse(JSONEncoder().encode(extraction))
        fields.removeValue(forKey: "editedBy")
      } else if old?.fields["extraction"] != nil { fields["editedBy"] = .string("explicitCaller") }
    }
    if payload.accepted {
      fields["reviewedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
      fields["reviewedBy"] = .string("explicitCaller")
    }
    return try WikiOntologyRecord(fields: fields)
  }

  private static func mergeKnowledgeJSON(_ new: WikiJSONValue, old: WikiJSONValue?) -> WikiJSONValue {
    if case .object(let next) = new, let old, case .object(var original) = old {
      for (key, value) in next { original[key] = mergeKnowledgeJSON(value, old: original[key]) }
      return .object(original)
    }
    if case .array(let next) = new, let old, case .array(let original) = old {
      func key(_ value: WikiJSONValue) -> String? {
        let object = value.objectValue
        return object?["language"]?.stringValue ?? object?["id"]?.stringValue
          ?? object?["evidence"]?.objectValue?["id"]?.stringValue
          ?? object?["evidenceID"]?.stringValue.map { $0 + "\0" + (object?["quote"]?.stringValue ?? "") }
          ?? object?["text"]?.stringValue
      }
      return .array(next.enumerated().map { index, value in
        // Equal array position is not identity: another quotation can use a different
        // source representation and must not inherit its predecessor's location/region.
        let previous: WikiJSONValue?
        if let target = key(value) { previous = original.first { key($0) == target } }
        else { previous = original.count == next.count ? original[index] : nil }
        return mergeKnowledgeJSON(value, old: previous)
      })
    }
    return new
  }

  private static func knowledgeNewline(_ bytes: Data) -> String { String(decoding: bytes, as: UTF8.self).contains("\r\n") ? "\r\n" : "\n" }

  private func assertionRenderedRange(_ payload: WikiKnowledgeRecordPayload, in bytes: Data, path: String) throws -> Range<Data.Index> {
    let newline = Self.knowledgeNewline(bytes)
    let expected = Data(try Self.knowledgeRecordBody(payload, path: path).replacingOccurrences(of: "\n", with: newline).utf8)
    if let range = bytes.range(of: expected), bytes.range(of: expected, in: range.upperBound..<bytes.endIndex) == nil { return range }
    throw WikiError.invalidSource("주장 본문과 저장한 항목이 다릅니다. 원문 편집에서 내용을 검토해 주세요.")
  }

  private static func knowledgeRecordBody(_ payload: WikiKnowledgeRecordPayload, path: String) throws -> String {
    switch payload {
    case .concept(let value):
      return "# " + WikiMarkdownEditor.literalInline(value.labels[0].preferred) + "\n\n" + (try knowledgeCitations(value.mentions.map(\.evidence), from: path))
    case .assertion(let value):
      let title = String(value.statement.text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(100) ?? "주장")
      var parts = ["# " + WikiMarkdownEditor.literalInline(title),
        "## 주장\n\n" + (value.statement.origin == .interpretation ? "해석 · " : "") + WikiMarkdownEditor.literalInline(value.statement.text)]
      if value.polarity != .unspecified { parts.append("극성 · " + (value.polarity == .negated ? "부정" : "긍정")) }
      if !value.conditions.isEmpty {
        parts.append("## 조건\n\n" + value.conditions.map {
          "- " + ($0.origin == .interpretation ? "해석 · " : "") + WikiMarkdownEditor.literalInline($0.text)
        }.joined(separator: "\n"))
      }
      for (label, item) in [("값", value.value), ("단위", value.unit), ("판본", value.edition)] {
        if let item { parts.append("**" + label + "** · " + WikiMarkdownEditor.literalInline(item.text)) }
      }
      parts.append("## 원문 근거\n\n" + (try knowledgeCitations(value.allEvidence, from: path)))
      return parts.joined(separator: "\n\n") + "\n"
    }
  }

  private static func knowledgeCitations(_ values: [WikiKnowledgeEvidence], from path: String) throws -> String {
    guard !values.isEmpty else { return "" }
    return try values.map { try $0.savedCitationMarkdown(from: path) }.joined(separator: "\n\n") + "\n"
  }

  static func mergingKnowledgeConcept(_ requested: WikiKnowledgeConcept, into old: WikiKnowledgeConcept) throws -> WikiKnowledgeConcept {
    guard requested.domain.isEmpty || old.domain.isEmpty || requested.domain == old.domain else { throw WikiError.invalidSource("다른 분야의 개념은 별도로 등록해 주세요.") }
    var labels = old.labels
    for label in requested.labels {
      if let index = labels.firstIndex(where: { $0.language.lowercased() == label.language.lowercased() }) {
        let previous = labels[index]; var aliases = previous.aliases
        if previous.preferred != label.preferred { aliases.append(previous.preferred) }
        for alias in label.aliases where !aliases.contains(alias) { aliases.append(alias) }
        labels[index] = .init(language: label.language, preferred: label.preferred, aliases: aliases.filter { $0 != label.preferred })
      } else { labels.append(label) }
    }
    var mentions = old.mentions
    for mention in requested.mentions {
      if let index = mentions.firstIndex(where: { $0.evidence.id == mention.evidence.id }) {
        guard mentions[index].evidence == mention.evidence else { throw WikiError.changedSource }; mentions[index] = mention
      } else { mentions.append(mention) }
    }
    return try WikiKnowledgeConcept(id: old.id, domain: requested.domain.isEmpty ? old.domain : requested.domain,
      labels: labels, mentions: mentions, state: requested.state).validated()
  }
}
