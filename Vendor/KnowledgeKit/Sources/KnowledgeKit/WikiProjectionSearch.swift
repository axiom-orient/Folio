import Foundation

extension WikiProjection {
  /// Complete local exact/FTS candidates, filtered before deterministic pagination.
  /// An empty query browses every eligible section. Semantic/system candidates are not paginated.
  public func searchPage(_ query: String, filter: WikiDocumentFilter = .init(),
    cursor: WikiSearchCursor? = nil, pageSize: Int = 50
  ) throws -> WikiSearchPage {
    guard (1...100).contains(pageSize) else { throw WikiError.invalidSource("Search page size must be 1...100.") }
    try filter.validate()
    let query = try WikiSearchQuery(query, allowEmpty: true)
    guard let snapshot = try snapshot() else { throw WikiError.unavailable("Workspace has not been scanned.") }
    let ranking = WikiSearchRanking(snapshot: snapshot, query: query, filter: filter, fts: try ftsCandidates(query, legacyLimit: false))
    let source = try WikiSearchEpoch.revision(snapshot)
    let binding = try WikiSearchContinuation.binding(query: query.normalized, filter: filter, pageSize: pageSize)
    let rankedRevision = try WikiSearchEpoch.digest(ranking.ids)
    let offset = try WikiSearchContinuation.offset(cursor: cursor, binding: binding, source: source, ranking: rankedRevision, count: ranking.ids.count)
    let end = min(offset + pageSize, ranking.ids.count)
    let next = end < ranking.ids.count ? try WikiSearchContinuation(version: 1, binding: binding, source: source, ranking: rankedRevision, offset: end).cursor() : nil
    return WikiSearchPage(hits: ranking.hits(offset..<end), totalCount: ranking.ids.count, nextCursor: next,
      coverageComplete: snapshot.coverageComplete, diagnostics: snapshot.diagnostics,
      sourceRevision: source, semanticState: "local")
  }

  func ftsCandidates(_ query: WikiSearchQuery, legacyLimit: Bool) throws -> [String] {
    guard !query.expression.isEmpty else { return [] }
    let sql = "SELECT section_id FROM fts_sections WHERE fts_sections MATCH ? ORDER BY bm25(fts_sections), section_id"
      + (legacyLimit ? " LIMIT 500" : "")
    return try database.rows(sql, [.text(query.expression)]).compactMap { $0[0] }
  }
}
