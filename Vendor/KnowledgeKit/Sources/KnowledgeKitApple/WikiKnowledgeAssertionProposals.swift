import Foundation
import FolioKnowledge

public struct WikiKnowledgeAssertionExtractionInput: Encodable, Sendable {
  public struct Source: Encodable, Sendable {
    public let id: String
    public let text: String
    public let title: String
    public let location: String
    public let usesOCR: Bool
  }
  public struct Concept: Encodable, Sendable {
    public let id: String
    public let name: String
    public let domain: String
  }
  public let schemaVersion: Int
  public let policyVersion: Int
  public let question: String
  public let sources: [Source]
  public let concepts: [Concept]
  /// All sources are data. The provider receives no workspace URL, file reader, writer or approval tool.
  public let responseSchemaJSON: String
}

public protocol WikiKnowledgeAssertionExtractionProvider: Sendable {
  /// Stable model/prompt revision identifier, without credentials or endpoints.
  var identifier: String { get }
  func extract(from input: WikiKnowledgeAssertionExtractionInput) async throws -> Data
}

/// Constructed by the host only. Saving still requires a separate explicit writer plan.
public struct WikiKnowledgeAssertionProposal: Sendable {
  public let assertion: WikiKnowledgeAssertion
  public let providerID: String
  public let schemaVersion: Int
  public let policyVersion: Int
  public let inputDigest: String
  public let proposalID: String
  public let conceptRevisions: [String: String]
  public let scopeID: String

  package init(assertion: WikiKnowledgeAssertion, providerID: String, schemaVersion: Int, policyVersion: Int,
    inputDigest: String, proposalID: String, conceptRevisions: [String: String], scopeID: String
  ) {
    self.assertion = assertion; self.providerID = providerID; self.schemaVersion = schemaVersion
    self.policyVersion = policyVersion; self.inputDigest = inputDigest; self.proposalID = proposalID
    self.conceptRevisions = conceptRevisions; self.scopeID = scopeID
  }
}

/// One bounded provider execution. Cancellation cannot free its slot while the provider is still running.
public actor WikiKnowledgeAssertionProposer {
  private let workspace: WikiWorkspace
  private let provider: (any WikiKnowledgeAssertionExtractionProvider)?
  private var busy = false

  public init(workspace: WikiWorkspace, provider: (any WikiKnowledgeAssertionExtractionProvider)? = nil) {
    self.workspace = workspace; self.provider = provider
  }

  public func propose(question: String, evidence: [WikiKnowledgeEvidence], conceptIDs: [String] = []) async throws -> [WikiKnowledgeAssertionProposal] {
    try Task.checkCancellation()
    guard !busy else { throw WikiError.unavailable("다른 주장 후보를 확인하고 있습니다.") }
    guard let provider else { throw WikiError.unavailable("주장 추출 모델이 설정되지 않았습니다. 원문에서 직접 저장할 수 있습니다.") }
    guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      question.utf8.count <= 8_192, !question.contains("\0"), !evidence.isEmpty, evidence.count <= 64,
      Set(evidence.map(\.id)).count == evidence.count, conceptIDs.count <= 32,
      Set(conceptIDs).count == conceptIDs.count, !provider.identifier.isEmpty,
      provider.identifier.utf8.count <= 512, !provider.identifier.contains(where: { $0.isNewline || $0 == "\0" }) else {
      throw WikiError.invalidSource("질문·원문 근거·알려진 개념의 범위를 확인해 주세요.")
    }
    busy = true
    defer { busy = false }
    _ = try await workspace.readKnowledgeEvidence(evidence)
    let scope = await workspace.knowledgeScopeID
    var revisions: [String: String] = [:]
    var concepts: [WikiKnowledgeAssertionExtractionInput.Concept] = []
    for id in conceptIDs {
      let record = try await workspace.readKnowledgeConcept(id: id)
      guard record.concept.state == .accepted else { throw WikiError.changedSource }
      revisions[id] = record.revision
      concepts.append(.init(id: id, name: record.concept.labels[0].preferred, domain: record.concept.domain))
    }
    let input = WikiKnowledgeAssertionExtractionInput(schemaVersion: 1, policyVersion: 1, question: question,
      sources: evidence.map { .init(id: $0.id, text: $0.text, title: $0.source.title,
        location: $0.displayLocation, usesOCR: $0.pdfRegion?.kind == .ocrUnreviewed) },
      concepts: concepts, responseSchemaJSON: try Self.responseSchemaJSON())
    guard try JSONEncoder().encode(input).count <= 65_536 else {
      throw WikiError.invalidSource("주장 추출 입력이 64 KiB를 넘습니다. 원문 근거 수를 줄여 주세요.")
    }
    struct Binding: Encodable {
      let question: String
      let evidence: [WikiKnowledgeEvidence]
      let concepts: [String: String]
      let scope: String
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let digest = SourceDigest.sha256(try encoder.encode(Binding(question: question, evidence: evidence, concepts: revisions, scope: scope)))
    let output = try await provider.extract(from: input)
    try Task.checkCancellation()
    let raw = try WikiJSONValue.parse(output)
    guard let fields = raw.objectValue, Set(fields.keys) == ["schemaVersion", "candidates"],
      fields["schemaVersion"]?.integerValue == 1, let entries = fields["candidates"]?.arrayValue,
      entries.count <= 8 else { throw WikiError.invalidSource("주장 후보의 출력 형식이나 개수 한도가 올바르지 않습니다.") }
    let admitted = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
    var proposals: [WikiKnowledgeAssertionProposal] = []
    for entry in entries {
      let candidate = try JSONDecoder().decode(Candidate.self, from: entry.encoded())
      try WikiKnowledgeAssertion.validateInputShape(entry, matching: WikiJSONValue.parse(encoder.encode(candidate)))
      guard Set(candidate.conceptIDs).isSubset(of: conceptIDs) else {
        throw WikiError.invalidSource("읽지 않은 개념을 주장 후보에 연결할 수 없습니다.")
      }
      let items = try candidate.evidence.map { item -> WikiKnowledgeAssertionEvidence in
        guard let original = admitted[item.evidenceID] else {
          throw WikiError.invalidSource("읽지 않은 원문 근거를 주장 후보에 연결할 수 없습니다.")
        }
        return .init(evidence: original, role: item.role)
      }
      let assertion = try WikiKnowledgeAssertion(id: UUID().uuidString.lowercased(), statement: candidate.statement,
        polarity: candidate.polarity, conceptIDs: candidate.conceptIDs, conditions: candidate.conditions,
        value: candidate.value, unit: candidate.unit, edition: candidate.edition, evidence: items, state: .draft).validated()
      let id = SourceDigest.sha256(try encoder.encode([provider.identifier, digest,
        String(decoding: encoder.encode(assertion), as: UTF8.self)]))
      proposals.append(.init(assertion: assertion, providerID: provider.identifier, schemaVersion: 1, policyVersion: 1,
        inputDigest: digest, proposalID: id, conceptRevisions: revisions.filter { assertion.conceptIDs.contains($0.key) }, scopeID: scope))
    }
    _ = try await workspace.readKnowledgeEvidence(evidence)
    for (id, revision) in revisions {
      guard try await workspace.readKnowledgeConcept(id: id).revision == revision else { throw WikiError.changedSource }
    }
    guard await workspace.knowledgeScopeID == scope else { throw WikiError.changedSource }
    try Task.checkCancellation()
    return proposals
  }

  /// The provider output shares the domain schema, but references allowlisted IDs instead of copying evidence.
  public static func responseSchemaJSON() throws -> String {
    guard var assertion = try JSONSerialization.jsonObject(with: Data(WikiKnowledgeAssertion.inputSchemaJSON.utf8)) as? [String: Any],
      var properties = assertion["properties"] as? [String: Any],
      let required = assertion["required"] as? [String], var definitions = assertion.removeValue(forKey: "$defs") as? [String: Any] else {
      throw WikiError.invalidSource("주장 출력 schema를 구성하지 못했습니다.")
    }
    properties.removeValue(forKey: "recordID"); properties.removeValue(forKey: "state")
    assertion["properties"] = properties; assertion["required"] = required.filter { $0 != "recordID" && $0 != "state" }
    definitions["AssertionEvidence"] = ["type": "object", "additionalProperties": false,
      "properties": ["evidenceID": ["type": "string", "minLength": 1, "maxLength": 512],
        "role": ["type": "string", "enum": ["support", "context", "refute"]]],
      "required": ["evidenceID", "role"]]
    let root: [String: Any] = ["type": "object", "additionalProperties": false,
      "properties": ["schemaVersion": ["type": "integer", "const": 1],
        "candidates": ["type": "array", "maxItems": 8, "items": assertion]],
      "required": ["schemaVersion", "candidates"], "$defs": definitions]
    return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
  }

  private struct Candidate: Codable {
    struct Item: Codable {
      let evidenceID: String
      let role: WikiKnowledgeAssertionEvidence.Role
    }
    let statement: WikiKnowledgeAssertionText
    let polarity: WikiKnowledgeAssertion.Polarity
    let conceptIDs: [String]
    let conditions: [WikiKnowledgeAssertionText]
    let value: WikiKnowledgeAssertionText?
    let unit: WikiKnowledgeAssertionText?
    let edition: WikiKnowledgeAssertionText?
    let evidence: [Item]
  }
}
