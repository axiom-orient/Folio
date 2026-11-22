import Foundation
import FolioKnowledge

/// A window owns one query and its pages. The search service owns source access and ranking.
struct FolioSearchResults {
  let hits: [WikiSearchHit]
  let totalCount: Int
  let nextCursor: WikiSearchCursor?
  let coverageComplete: Bool
  let diagnostics: [WikiDiagnostic]

  init(hits: [WikiSearchHit], totalCount: Int, nextCursor: WikiSearchCursor? = nil,
    coverageComplete: Bool = true, diagnostics: [WikiDiagnostic] = []
  ) {
    self.hits = hits; self.totalCount = totalCount; self.nextCursor = nextCursor
    self.coverageComplete = coverageComplete; self.diagnostics = diagnostics
  }

  init(page: WikiSearchPage, previous: Self? = nil) {
    var seen = Set<String>()
    hits = ((previous?.hits ?? []) + page.hits).filter { seen.insert($0.id).inserted }
    totalCount = page.totalCount; nextCursor = page.nextCursor
    coverageComplete = page.coverageComplete; diagnostics = page.diagnostics
  }
}

enum FolioSearchState {
  case idle
  case waiting
  case loading(request: UUID)
  case ready(FolioSearchResults)
  case loadingMore(FolioSearchResults, request: UUID)
  case failed(previous: FolioSearchResults?, message: String)

  var results: FolioSearchResults? {
    switch self {
    case .ready(let results), .loadingMore(let results, _): results
    case .failed(let previous, _): previous
    default: nil
    }
  }
  var hits: [WikiSearchHit] { results?.hits ?? [] }
  var isLoading: Bool {
    switch self { case .waiting, .loading: true; default: false }
  }
  var isLoadingMore: Bool { if case .loadingMore = self { true } else { false } }
  var error: String? { if case .failed(_, let message) = self { message } else { nil } }
  private var request: UUID? {
    switch self { case .loading(let id), .loadingMore(_, let id): id; default: nil }
  }

  mutating func reset(waiting: Bool) { self = waiting ? .waiting : .idle }

  mutating func begin(append: Bool) -> UUID? {
    let id = UUID()
    if append {
      guard !isLoading, !isLoadingMore, let results, results.nextCursor != nil else { return nil }
      self = .loadingMore(results, request: id)
    } else { self = .loading(request: id) }
    return id
  }

  @discardableResult mutating func complete(request: UUID, page: WikiSearchPage) -> Bool {
    guard self.request == request else { return false }
    self = .ready(FolioSearchResults(page: page, previous: results))
    return true
  }

  @discardableResult mutating func fail(request: UUID, message: String) -> Bool {
    guard self.request == request else { return false }
    self = .failed(previous: results, message: message)
    return true
  }
}
