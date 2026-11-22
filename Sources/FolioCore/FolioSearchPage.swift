import Foundation
import FolioKnowledge

/// An opaque continuation bound to the originating workspace session and source.
/// Changing the source invalidates it rather than silently skipping results.
public struct FolioSearchContinuation: Sendable {
  let contextID: UUID
  let cursor: WikiSearchCursor
}

public struct FolioSearchPage: Sendable {
  public let results: [FolioSearchResult]
  public let totalCount: Int
  public let nextContinuation: FolioSearchContinuation?
  public let coverageComplete: Bool
  public let diagnostics: [String]
}
