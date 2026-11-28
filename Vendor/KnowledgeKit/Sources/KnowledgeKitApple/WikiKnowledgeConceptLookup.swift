import Foundation
import FolioKnowledge

public struct WikiKnowledgeConceptChoice: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let domain: String
  public let sourceTitle: String
}

/// Terminology resolution is independent of extraction coverage and factual support.
public struct WikiKnowledgeConceptResolution: Codable, Sendable {
  public let choices: [WikiKnowledgeConceptChoice]
  public let selectedConceptID: String?
  public let complete: Bool
  public let diagnostics: [String]
  public var isAmbiguous: Bool { selectedConceptID == nil && choices.count > 1 }
}

/// A bounded projection of admitted Concept records. It never owns source or writes knowledge notes.
struct WikiKnowledgeConceptLookup {
  let manifestRevision: String
  let resolution: WikiKnowledgeConceptResolution
  let evidence: [WikiKnowledgeEvidence]
  let projectionAvailable: Bool

  static func prepare(workspace: WikiWorkspace, query: String, sources: [String: WikiKnowledgeSource],
    conceptID: String?
  ) async throws -> Self {
    let inventory = try await workspace.knowledgeConceptInventory()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let projection = workspace.projection
    guard try await projection.ontologyComponentAvailable() else {
      if conceptID != nil { throw WikiError.unavailable("현재 버전에서 용어 연결 색인을 읽을 수 없습니다.") }
      return Self(manifestRevision: inventory.fingerprint,
        resolution: .init(choices: [], selectedConceptID: nil, complete: false,
          diagnostics: inventory.diagnostics + ["용어 연결 색인을 읽을 수 없어 원문 검색만 사용했습니다."]),
        evidence: [], projectionAvailable: false)
    }
    if try await projection.ontologyManifestRevision() != inventory.fingerprint {
      let records = try inventory.records.filter { $0.concept.state == .accepted }.map { record in
        let mentions = try record.concept.mentions.map { mention in
          let evidence = mention.evidence
          return WikiOntologyMentionRecord(id: evidence.id, sourceID: evidence.source.id,
            sourceRevision: evidence.source.indexRevision,
            payload: String(decoding: try encoder.encode(evidence), as: UTF8.self))
        }
        return WikiOntologyProjectionRecord(id: record.concept.id, revision: record.revision,
          payload: String(decoding: try record.record.encoded(), as: UTF8.self),
          labels: record.concept.labels, mentions: mentions)
      }
      try await projection.replaceOntologyRecords(records, manifestRevision: inventory.fingerprint)
    }
    let matches = try await projection.ontologyConceptMatches(query: query, sourceIDs: Set(sources.keys))
    let admitted = Dictionary(uniqueKeysWithValues: inventory.records.map { ($0.concept.id, $0) })
    var diagnostics = inventory.diagnostics
    var complete = matches.complete && diagnostics.isEmpty
    var staleConcepts = Set<String>()
    let choices = try matches.matches.map { match -> WikiKnowledgeConceptChoice in
      guard let record = admitted[match.id], record.revision == match.revision,
        record.concept.state == .accepted,
        String(decoding: try record.record.encoded(), as: UTF8.self) == match.payload else { throw WikiError.changedSource }
      let mentions = record.concept.mentions.filter { sources[$0.evidence.source.id] != nil }
      if mentions.contains(where: { sources[$0.evidence.source.id] != $0.evidence.source }) {
        staleConcepts.insert(match.id)
        diagnostics.append(record.concept.labels[0].preferred + ": 원문이 바뀐 연결이 있어 다시 확인해야 합니다.")
        complete = false
      }
      return .init(id: match.id, name: record.concept.labels[0].preferred, domain: record.concept.domain,
        sourceTitle: mentions.first?.evidence.source.title ?? "")
    }
    let selectedID: String?
    if let conceptID {
      guard choices.contains(where: { $0.id == conceptID }), !staleConcepts.contains(conceptID) else {
        throw WikiError.changedSource
      }
      selectedID = conceptID
    } else { selectedID = complete && choices.count == 1 ? choices[0].id : nil }
    var evidence: [WikiKnowledgeEvidence] = []
    if let selectedID {
      let rows = try await projection.ontologyMentions(recordIDs: [selectedID], sourceIDs: Set(sources.keys), limit: 61)
      if rows.count > 60 {
        complete = false
        diagnostics.append("개념에 연결된 근거 중 최대 60개를 확인했습니다.")
      }
      for row in rows.prefix(60) {
        let item = try JSONDecoder().decode(WikiKnowledgeEvidence.self, from: Data(row.payload.utf8))
        guard item.id == row.id, item.source.id == row.sourceID,
          item.source.indexRevision == row.sourceRevision, sources[row.sourceID] == item.source,
          admitted[selectedID]?.concept.mentions.contains(where: { $0.evidence == item }) == true else {
          throw WikiError.changedSource
        }
        evidence.append(item)
      }
      // A stored association is not authority to publish invented or stale quotations.
      if !evidence.isEmpty { _ = try await workspace.readKnowledgeEvidence(evidence) }
    }
    return Self(manifestRevision: inventory.fingerprint,
      resolution: .init(choices: choices, selectedConceptID: selectedID, complete: complete, diagnostics: diagnostics),
      evidence: evidence, projectionAvailable: true)
  }

  func validate(in workspace: WikiWorkspace) async throws {
    guard try await workspace.knowledgeConceptInventory().fingerprint == manifestRevision else { throw WikiError.changedSource }
    if projectionAvailable, try await workspace.projection.ontologyManifestRevision() != manifestRevision {
      throw WikiError.changedSource
    }
  }
}
