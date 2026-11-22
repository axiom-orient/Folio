import Foundation
import FolioKnowledge

/// Checks source references only. It does not decide whether a question is
/// answerable, or whether the referenced statements are true.
public struct WikiEvidenceVerification: Codable, Sendable {
  public struct Item: Codable, Sendable {
    public enum State: String, Codable, Sendable { case current, changed, invalid, unavailable }
    public let reference: WikiEvidenceReference
    public let state: State
    public let diagnostic: String?
  }
  public let items: [Item]
  public let atomicSnapshot = false
  public var allCurrent: Bool { !items.isEmpty && items.allSatisfy { $0.state == .current } }

  private enum CodingKeys: String, CodingKey { case items, atomicSnapshot, allCurrent }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(items, forKey: .items)
    try values.encode(atomicSnapshot, forKey: .atomicSnapshot)
    try values.encode(allCurrent, forKey: .allCurrent)
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    items = try values.decode([Item].self, forKey: .items)
  }
  init(items: [Item]) { self.items = items }
}

extension WikiWorkspace {
  /// Admission failure and cancellation throw. Individual stale or unreadable
  /// references remain explicit, in request order, without returning stale text.
  public func verifyEvidence(_ references: [WikiEvidenceReference]) throws -> WikiEvidenceVerification {
    try Task.checkCancellation()
    try requireOpen()
    guard references.count <= 100 else { throw WikiError.invalidSource("Verification accepts at most 100 references.") }
    var items: [WikiEvidenceVerification.Item] = []
    for reference in references {
      try Task.checkCancellation()
      do {
        _ = try read(reference)
        items.append(.init(reference: reference, state: .current, diagnostic: nil))
      } catch is CancellationError { throw CancellationError() }
      catch {
        let state: WikiEvidenceVerification.Item.State
        switch error {
        case WikiError.changedSource: state = .changed
        case WikiError.invalidSource, WikiError.invalidPath: state = .invalid
        default: state = .unavailable
        }
        items.append(.init(reference: reference, state: state, diagnostic: error.localizedDescription))
      }
    }
    return WikiEvidenceVerification(items: items)
  }
}
