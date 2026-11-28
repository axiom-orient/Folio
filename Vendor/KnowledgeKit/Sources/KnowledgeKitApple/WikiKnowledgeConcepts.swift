import Foundation
import FolioKnowledge

/// A caller-reviewed link to an original quotation. A mention is not automatically a definition.
public struct WikiKnowledgeConceptMention: Codable, Hashable, Sendable {
  public let evidence: WikiKnowledgeEvidence
  public let isDefinition: Bool
  public init(evidence: WikiKnowledgeEvidence, isDefinition: Bool = false) {
    self.evidence = evidence; self.isDefinition = isDefinition
  }
}

public struct WikiKnowledgeConcept: Codable, Hashable, Sendable, Identifiable {
  public enum State: String, Codable, Hashable, Sendable { case draft, accepted }
  public let id: String
  public let domain: String
  public let labels: [WikiConceptLabel]
  public let mentions: [WikiKnowledgeConceptMention]
  public let state: State

  public init(id: String, domain: String = "", labels: [WikiConceptLabel],
    mentions: [WikiKnowledgeConceptMention], state: State = .accepted
  ) {
    self.id = id; self.domain = domain; self.labels = labels; self.mentions = mentions; self.state = state
  }
  private enum CodingKeys: String, CodingKey { case id = "recordID", domain, labels, mentions, state }

  package func validated() throws -> Self {
    guard !id.isEmpty, id.utf8.count <= 512, !id.hasPrefix("path:"),
      !id.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" || $0 == "\0" }),
      domain.utf8.count <= 256, !domain.contains("\0"), !labels.isEmpty, labels.count <= 32,
      mentions.count <= 64, state == .draft || !mentions.isEmpty else {
      throw WikiError.invalidSource("개념 이름과 원문 근거를 확인해 주세요.")
    }
    var languages = Set<String>()
    for label in labels {
      guard !label.language.isEmpty, label.language.utf8.count <= 63,
        label.language.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
        languages.insert(label.language.lowercased()).inserted,
        label.aliases.count <= 64 else { throw WikiError.invalidSource("개념의 언어별 이름이 올바르지 않습니다.") }
      for text in [label.preferred] + label.aliases {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 512,
          !text.contains(where: { $0.isNewline || $0 == "\0" }) else {
          throw WikiError.invalidSource("개념 이름과 별칭은 한 줄로 입력해 주세요.")
        }
      }
    }
    guard Set(mentions.map { $0.evidence.id }).count == mentions.count else {
      throw WikiError.invalidSource("같은 원문 근거가 중복됐습니다.")
    }
    return self
  }

  package static func decode(_ record: WikiOntologyRecord) throws -> Self {
    guard record.schemaVersion == 1, record.role == "concept" else {
      throw WikiError.unavailable("지원하지 않는 지식 레코드 형식입니다.")
    }
    let value = try JSONDecoder().decode(Self.self, from: record.encoded())
    guard value.id == record.recordID else { throw WikiError.changedSource }
    return try value.validated()
  }
}

/// Record admission is separate from primary-source admission. Its revision is the original Markdown hash.
public struct WikiKnowledgeConceptRecord: Sendable {
  public let concept: WikiKnowledgeConcept
  public let relativePath: String
  public let revision: String
  public let record: WikiOntologyRecord
}

public struct WikiKnowledgeConceptInventory: Sendable {
  public let records: [WikiKnowledgeConceptRecord]
  public let fingerprint: String
  public let diagnostics: [String]
}

public struct WikiKnowledgeConceptOperationStatus: Sendable {
  public typealias Currentness = WikiKnowledgeRecordCurrentness
  public let conceptID: String
  public let relativePath: String
  public let resultRevision: String
  public let operation: WikiOperationStatus
  /// The exact requested bytes are present, even if receipt publication was interrupted.
  public let sourceObserved: Bool
  /// Currentness of the backing original quotations, independently of historical commit state.
  public let currentness: Currentness
}

extension WikiWorkspace {
  /// Derived records remain separate from primary source admission.
  public func knowledgeConceptInventory() async throws -> WikiKnowledgeConceptInventory {
    let snapshot = try await refresh()
    try requireKnowledgeAccess()
    var records: [WikiKnowledgeConceptRecord] = []
    var diagnostics = snapshot.diagnostics.map { "\($0.path): \($0.reason)" }
    for document in snapshot.documents {
      try Task.checkCancellation()
      do {
        guard let raw = try knowledgeRecord(document, role: "concept"), case .concept(let concept) = raw.payload else { continue }
        guard records.count < 1000 else { throw WikiError.unavailable("개념 레코드 조회 한도를 넘었습니다.") }
        records.append(.init(concept: concept, relativePath: raw.relativePath, revision: raw.revision, record: raw.record))
      } catch is CancellationError { throw CancellationError() }
      catch { diagnostics.append("\(document.relativePath): \(error.localizedDescription)") }
    }
    records.sort { $0.concept.id < $1.concept.id }; diagnostics.sort()
    let fingerprint = SourceDigest.sha256(try JSONEncoder().encode([knowledgeScopeID, snapshot.revision, diagnostics.joined(separator: "\n")]))
    try requireKnowledgeAccess()
    return .init(records: records, fingerprint: fingerprint, diagnostics: diagnostics)
  }

  public func readKnowledgeConcept(id: String) async throws -> WikiKnowledgeConceptRecord {
    let snapshot = try await refresh()
    try requireKnowledgeAccess()
    guard let document = snapshot.documents.first(where: { $0.id == id }),
      let raw = try knowledgeRecord(document, role: "concept"), case .concept(let concept) = raw.payload else {
      throw WikiError.unavailable("현재 자료함에서 개념을 읽을 수 없습니다.")
    }
    _ = try readKnowledgeEvidence(concept.mentions.map(\.evidence))
    guard SourceDigest.sha256(try knowledgeRead(path: raw.relativePath, maximumBytes: 256 * 1024)) == raw.revision else { throw WikiError.changedSource }
    return .init(concept: concept, relativePath: raw.relativePath, revision: raw.revision, record: raw.record)
  }

  public func prepareKnowledgeConcept(_ concept: WikiKnowledgeConcept, relativePath: String? = nil,
    expectedRevision: String? = nil, operationID: UUID) async throws -> WikiPreparedEdit {
    try await prepareKnowledgeRecord(.concept(concept), relativePath: relativePath,
      expectedRevision: expectedRevision, operationID: operationID)
  }

  public func executeKnowledgeConcept(_ plan: WikiPreparedEdit, idempotencyKey: String? = nil) async throws -> WikiWriteReceipt {
    try await executeKnowledgeRecord(plan, role: "concept", idempotencyKey: idempotencyKey)
  }

  public func knowledgeConceptOperationStatus(operationID: UUID) throws -> WikiKnowledgeConceptOperationStatus {
    let value = try knowledgeRecordOperationStatus(operationID, role: "concept")
    return .init(conceptID: value.id, relativePath: value.relativePath, resultRevision: value.resultRevision,
      operation: value.operation, sourceObserved: value.sourceObserved, currentness: value.currentness)
  }
}
