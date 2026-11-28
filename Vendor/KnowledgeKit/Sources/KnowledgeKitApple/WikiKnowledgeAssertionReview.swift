import Foundation
import FolioKnowledge

/// An explicit review snapshot, separate from a current knowledge result.
/// Original quotations and the rendered record must still be valid.
public struct WikiKnowledgeAssertionReview: Sendable {
  public struct ConceptChange: Sendable, Identifiable {
    public enum State: String, Sendable { case changed, unavailable }
    public let conceptID: String
    public let name: String
    public let state: State
    /// Verified current concept content for the caller's explicit review.
    public let currentConcept: WikiKnowledgeConcept?
    public var id: String { conceptID }
  }

  public let record: WikiKnowledgeAssertionRecord
  public let conceptChanges: [ConceptChange]
  /// Pin the exact accepted Concept versions shown during this explicit review.
  public let currentConceptRevisions: [String: String]
  public var requiresConceptReview: Bool { !conceptChanges.isEmpty }
}

extension WikiWorkspace {
  /// Reads a saved assertion for an explicit same-file review. This does not
  /// rebind concepts, approve a write, or admit the assertion as current knowledge.
  public func reviewKnowledgeAssertion(id: String) async throws -> WikiKnowledgeAssertionReview {
    let snapshot = try await refresh()
    try requireKnowledgeAccess()
    guard let document = snapshot.documents.first(where: { $0.id == id }),
      let raw = try knowledgeRecord(document, role: "assertion"),
      case .assertion(let assertion) = raw.payload else {
      throw WikiError.unavailable("현재 자료함에서 검토할 주장을 읽을 수 없습니다.")
    }
    let previous = try conceptBindings(in: raw.record, ids: assertion.conceptIDs)
    // A changed original requires new quotations, never an automatic rebase.
    _ = try readKnowledgeEvidence(assertion.allEvidence)
    var changes: [WikiKnowledgeAssertionReview.ConceptChange] = []
    var observed: [String: WikiKnowledgeConceptBinding] = [:]
    for conceptID in assertion.conceptIDs {
      try Task.checkCancellation()
      guard let conceptDocument = snapshot.documents.first(where: { $0.id == conceptID }) else {
        changes.append(.init(conceptID: conceptID, name: "연결한 개념", state: .unavailable, currentConcept: nil))
        continue
      }
      var name = conceptDocument.title
      do {
        guard let current = try knowledgeRecord(conceptDocument, role: "concept"),
          case .concept(let concept) = current.payload else { throw WikiError.changedSource }
        name = concept.labels.first?.preferred ?? "연결한 개념"
        guard concept.state == .accepted else { throw WikiError.changedSource }
        let binding = WikiKnowledgeConceptBinding(relativePath: current.relativePath, revision: current.revision)
        try validateKnowledgeConceptBindings([conceptID: binding])
        observed[conceptID] = binding
        if previous[conceptID] != binding {
          changes.append(.init(conceptID: conceptID, name: name, state: .changed, currentConcept: concept))
        }
      } catch is CancellationError { throw CancellationError() }
      catch {
        try requireKnowledgeAccess()
        changes.append(.init(conceptID: conceptID, name: name, state: .unavailable, currentConcept: nil))
      }
    }
    try validateKnowledgeConceptBindings(observed)
    _ = try readKnowledgeEvidence(assertion.allEvidence)
    guard SourceDigest.sha256(try knowledgeRead(path: raw.relativePath, maximumBytes: 256 * 1024)) == raw.revision else {
      throw WikiError.changedSource
    }
    try requireKnowledgeAccess()
    return .init(record: .init(assertion: assertion, relativePath: raw.relativePath,
      revision: raw.revision, record: raw.record), conceptChanges: changes,
      currentConceptRevisions: observed.mapValues(\.revision))
  }
}
