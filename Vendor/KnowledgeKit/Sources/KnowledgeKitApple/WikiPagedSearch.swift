import Foundation
import FolioKnowledge

extension WikiWorkspace {
  /// Local-complete search validates current source evidence before publishing a page.
  /// A changed source invalidates the whole continuation instead of silently dropping hits.
  /// This local path does not create a Spotlight index or register a delegate.
  public func localSearchPage(_ query: String, filter: WikiDocumentFilter = .init(),
    cursor: WikiSearchCursor? = nil, pageSize: Int = 50
  ) async throws -> WikiSearchPage {
    try Task.checkCancellation()
    let before = try await refresh()
    let page = try await projection.searchPage(query, filter: filter, cursor: cursor, pageSize: pageSize)
    guard page.sourceRevision == (try WikiSearchEpoch.revision(before)) else { throw WikiError.changedSource }
    _ = try read(page.hits.map(\.reference))
    let after = try await refresh()
    guard page.sourceRevision == (try WikiSearchEpoch.revision(after)) else { throw WikiError.changedSource }
    try Task.checkCancellation()
    return page
  }
}
