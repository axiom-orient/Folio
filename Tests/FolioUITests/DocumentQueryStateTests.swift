import Foundation
import FolioKnowledge
import Testing
@testable import FolioUI

@Suite struct DocumentQueryStateTests {
  @Test func firstPagePublishesCoverageAndRejectsDuplicateCompletion() throws {
    let hit = try queryStateHit(section: "first")
    let diagnostic = WikiDiagnostic(path: "unreadable.md", reason: "read_failed")
    let page = queryStatePage(hits: [hit, hit], totalCount: 7, coverageComplete: false, diagnostics: [diagnostic])
    var state = FolioSearchState.waiting
    let requestResult = state.begin(append: false)
    let request = try #require(requestResult)

    let transitionResult1 = state.complete(request: request, page: page)
    #expect(transitionResult1)
    #expect(state.hits.map(\.id) == [hit.id])
    #expect(state.results?.totalCount == 7)
    #expect(state.results?.coverageComplete == false)
    #expect(state.results?.diagnostics == [diagnostic])
    #expect(!state.isLoading && !state.isLoadingMore)
    #expect(state.error == nil)
    let transitionResult2 = !state.complete(request: request, page: queryStatePage(hits: [], totalCount: 0))
    #expect(transitionResult2)
    let transitionResult3 = !state.fail(request: request, message: "완료된 요청의 늦은 실패")
    #expect(transitionResult3)
    #expect(state.hits.map(\.id) == [hit.id])
  }

  @Test func nextPageAppendsUniqueSectionsInOrderAndKeepsDifferentSectionsOfOneDocument() throws {
    let first = try queryStateHit(section: "first", title: "Original")
    let overlapping = try queryStateHit(section: "first", title: "Duplicate")
    let second = try queryStateHit(section: "second")
    let third = try queryStateHit(section: "third", document: "other")
    let cursor = try queryStateCursor()
    var state = FolioSearchState.ready(FolioSearchResults(hits: [first], totalCount: 3, nextCursor: cursor))
    let requestResult = state.begin(append: true)
    let request = try #require(requestResult)

    #expect(state.isLoadingMore && !state.isLoading)
    #expect(state.hits.map(\.id) == [first.id])
    let transitionResult4 = state.begin(append: true) == nil
    #expect(transitionResult4)
    let transitionResult5 = state.complete(request: request, page: queryStatePage(hits: [overlapping, second, second, third], totalCount: 3))
    #expect(transitionResult5)
    #expect(state.hits.map(\.id) == [first.id, second.id, third.id])
    #expect(state.hits.first?.title == "Original")
    #expect(state.results?.nextCursor == nil)
    let transitionResult6 = state.begin(append: true) == nil
    #expect(transitionResult6)
    let transitionResult7 = !state.complete(request: request, page: queryStatePage(hits: [third], totalCount: 1))
    #expect(transitionResult7)
  }

  @Test func nextPageFailurePreservesResultsAndCursorForRetry() throws {
    let first = try queryStateHit(section: "first")
    let second = try queryStateHit(section: "second")
    let cursor = try queryStateCursor()
    let diagnostic = WikiDiagnostic(path: "partial.md", reason: "partial_scan")
    var state = FolioSearchState.ready(FolioSearchResults(hits: [first], totalCount: 2, nextCursor: cursor,
      coverageComplete: false, diagnostics: [diagnostic]))
    let failedResult = state.begin(append: true)
    let failed = try #require(failedResult)

    let transitionResult8 = state.fail(request: failed, message: "다음 페이지 실패")
    #expect(transitionResult8)
    #expect(state.hits.map(\.id) == [first.id])
    #expect(state.results?.nextCursor == cursor)
    #expect(state.results?.totalCount == 2)
    #expect(state.results?.coverageComplete == false)
    #expect(state.results?.diagnostics == [diagnostic])
    #expect(state.error == "다음 페이지 실패")
    let retryResult = state.begin(append: true)
    let retry = try #require(retryResult)
    #expect(retry != failed)
    #expect(state.isLoadingMore)
    #expect(state.error == nil)
    #expect(state.results?.nextCursor == cursor)
    let transitionResult9 = !state.fail(request: failed, message: "이전 페이지 요청의 늦은 실패")
    #expect(transitionResult9)
    let transitionResult10 = !state.complete(request: failed, page: queryStatePage(hits: [], totalCount: 0))
    #expect(transitionResult10)
    let transitionResult11 = state.complete(request: retry, page: queryStatePage(hits: [second], totalCount: 2))
    #expect(transitionResult11)
    #expect(state.hits.map(\.id) == [first.id, second.id])
    #expect(state.results?.coverageComplete == true)
    #expect(state.results?.diagnostics.isEmpty == true)
    #expect(state.error == nil)
  }

  @Test func firstPageFailureCanRetryWithoutRetainingAnObsoleteRequest() throws {
    var state = FolioSearchState.idle
    state.reset(waiting: true)
    #expect(state.isLoading)
    #expect(state.hits.isEmpty)
    let firstResult = state.begin(append: false)
    let first = try #require(firstResult)
    #expect(state.isLoading)
    #expect(!state.isLoadingMore)

    let transitionResult12 = state.fail(request: first, message: "첫 페이지 실패")
    #expect(transitionResult12)
    #expect(!state.isLoading)
    #expect(state.results == nil)
    #expect(state.error == "첫 페이지 실패")

    let retryResult = state.begin(append: false)
    let retry = try #require(retryResult)
    #expect(retry != first)
    #expect(state.isLoading)
    #expect(state.error == nil)
    let transitionResult13 = !state.fail(request: first, message: "이전 요청의 늦은 실패")
    #expect(transitionResult13)
    #expect(state.isLoading)
    #expect(state.error == nil)
    let transitionResult14 = state.fail(request: retry, message: "재시도 실패")
    #expect(transitionResult14)
    #expect(state.error == "재시도 실패")
  }

  @Test func aPageWithoutACursorCannotStartAnotherPage() throws {
    let hit = try queryStateHit(section: "only-section")
    var state = FolioSearchState.ready(FolioSearchResults(hits: [hit], totalCount: 1))

    let transitionResult15 = state.begin(append: true) == nil
    #expect(transitionResult15)
    #expect(!state.isLoading && !state.isLoadingMore)
    #expect(state.hits.map(\.id) == [hit.id])
    #expect(state.results?.totalCount == 1)
    #expect(state.error == nil)
  }

  @Test func appendAdmissionCannotDisplaceAFirstPageRequest() throws {
    var state = FolioSearchState.waiting
    let transitionResult16 = state.begin(append: true) == nil
    #expect(transitionResult16)
    let firstResult = state.begin(append: false)
    let first = try #require(firstResult)

    let transitionResult17 = state.begin(append: true) == nil
    #expect(transitionResult17)
    let transitionResult18 = state.fail(request: first, message: "현재 요청 실패")
    #expect(transitionResult18)
    #expect(state.error == "현재 요청 실패")
  }

  @Test func restartingTheFirstPageRejectsLateAndDuplicateFailures() throws {
    var state = FolioSearchState.idle
    let oldResult = state.begin(append: false)
    let old = try #require(oldResult)
    let currentResult = state.begin(append: false)
    let current = try #require(currentResult)

    #expect(old != current)
    let transitionResult19 = !state.fail(request: old, message: "지난 검색의 실패")
    #expect(transitionResult19)
    #expect(state.isLoading)
    #expect(state.error == nil)
    let transitionResult20 = state.fail(request: current, message: "현재 검색의 실패")
    #expect(transitionResult20)
    let transitionResult21 = !state.fail(request: current, message: "중복 실패")
    #expect(transitionResult21)
    #expect(state.error == "현재 검색의 실패")
  }

  @Test(arguments: [true, false])
  func resetInvalidatesThePendingRequestAndClearsFailure(waiting: Bool) throws {
    var state = FolioSearchState.idle
    let obsoleteResult = state.begin(append: false)
    let obsolete = try #require(obsoleteResult)
    state.reset(waiting: waiting)

    let transitionResult22 = !state.fail(request: obsolete, message: "취소된 검색의 실패")
    #expect(transitionResult22)
    #expect(state.isLoading == waiting)
    #expect(!state.isLoadingMore)
    #expect(state.results == nil)
    #expect(state.hits.isEmpty)
    #expect(state.error == nil)
  }

  @MainActor @Test func queryAndFilterChangesInvalidateOnlyTheirWindowAndRejectLatePages() throws {
    let first = WikiWindowState()
    let other = WikiWindowState()
    let hit = try queryStateHit(section: "kept-in-other-window")
    let page = queryStatePage(hits: [hit], totalCount: 1)
    first.query = "before"
    other.query = "independent"
    other.searchState = .ready(FolioSearchResults(hits: [hit], totalCount: 1))
    let otherGeneration = other.searchGeneration
    let oldCriteria = first.searchCriteria
    let oldRequestResult = first.searchState.begin(append: false)
    let oldRequest = try #require(oldRequestResult)
    let beforeQuery = first.searchGeneration

    first.query = "after"
    #expect(first.searchGeneration == beforeQuery + 1)
    #expect(first.searchCriteria != oldCriteria)
    #expect(first.isSearching && first.hits.isEmpty)
    let transitionResult23 = !first.searchState.complete(request: oldRequest, page: page)
    #expect(transitionResult23)
    let filterRequestResult = first.searchState.begin(append: false)
    let filterRequest = try #require(filterRequestResult)
    let beforeFilter = first.searchGeneration
    let unfilteredCriteria = first.searchCriteria
    first.filter = WikiDocumentFilter(folder: "notes", tag: "swift", documentType: .named("article"))
    #expect(first.searchGeneration == beforeFilter + 1)
    #expect(first.searchCriteria != unfilteredCriteria)
    #expect(first.isSearching && first.hits.isEmpty)
    let transitionResult24 = !first.searchState.complete(request: filterRequest, page: page)
    #expect(transitionResult24)
    let transitionResult25 = !first.searchState.fail(request: filterRequest, message: "옛 필터의 실패")
    #expect(transitionResult25)
    #expect(other.searchGeneration == otherGeneration)
    #expect(other.query == "independent")
    #expect(other.filter == WikiDocumentFilter())
    #expect(other.hits.map(\.id) == [hit.id])
  }

  @MainActor @Test func unchangedCriteriaKeepTheCurrentRequestWhileBlankQueryUsesBrowseState() throws {
    let window = WikiWindowState()
    window.query = "term"
    window.filter = WikiDocumentFilter(tag: "swift")
    let criteria = window.searchCriteria
    let generation = window.searchGeneration
    let requestResult = window.searchState.begin(append: false)
    let request = try #require(requestResult)
    window.query = "term"
    window.filter = WikiDocumentFilter(tag: "swift")
    #expect(window.searchGeneration == generation)
    #expect(window.searchCriteria == criteria)
    let transitionResult26 = window.searchState.complete(request: request, page: queryStatePage(hits: [], totalCount: 0))
    #expect(transitionResult26)

    window.query = " \n\t "
    #expect(!window.hasSearchQuery)
    #expect(!window.isSearching)
    #expect(window.hits.isEmpty)
    #expect(window.searchState.results == nil)
    window.filter = WikiDocumentFilter(folder: "notes", tag: "swift")
    #expect(!window.hasSearchQuery && !window.isSearching)
    #expect(window.filter.folder == "notes")
    #expect(window.searchState.results == nil)
  }

  @MainActor @Test func resetNavigationInvalidatesPendingSearchAndClearsFiltersAndResults() throws {
    let window = WikiWindowState()
    let hit = try queryStateHit(section: "old-result")
    window.query = "term"
    window.filter = WikiDocumentFilter(folder: "notes", tag: "swift")
    window.searchState = .ready(FolioSearchResults(hits: [hit], totalCount: 2, nextCursor: try queryStateCursor()))
    let requestResult = window.searchState.begin(append: true)
    let request = try #require(requestResult)
    let generation = window.searchGeneration

    window.resetNavigation()
    #expect(window.searchGeneration > generation)
    #expect(window.filter == WikiDocumentFilter())
    #expect(window.hits.isEmpty)
    #expect(!window.isSearching && !window.searchState.isLoadingMore)
    #expect(window.searchState.results == nil)
    let transitionResult27 = !window.searchState.complete(request: request, page: queryStatePage(hits: [hit], totalCount: 1))
    #expect(transitionResult27)
    let transitionResult28 = !window.searchState.fail(request: request, message: "이전 탐색의 늦은 실패")
    #expect(transitionResult28)
    #expect(window.searchState.error == nil)
  }
}

private func queryStatePage(hits: [WikiSearchHit], totalCount: Int, nextCursor: WikiSearchCursor? = nil,
  coverageComplete: Bool = true, diagnostics: [WikiDiagnostic] = []
) -> WikiSearchPage {
  WikiSearchPage(hits: hits, totalCount: totalCount, nextCursor: nextCursor, coverageComplete: coverageComplete,
    diagnostics: diagnostics, sourceRevision: "fixture-revision", semanticState: "local")
}

// The UI passes this opaque Codable value through; only the search service interprets its token.
private func queryStateCursor() throws -> WikiSearchCursor {
  try JSONDecoder().decode(WikiSearchCursor.self, from: Data(#"{"token":"fixture-continuation"}"#.utf8))
}

// Value-only fixtures keep these state tests independent of indexes and source I/O.
private func queryStateHit(section: String, document: String = "document", title: String = "Result") throws -> WikiSearchHit {
  let fields: [String: Any] = ["title": title, "breadcrumb": [String](), "snippet": "Matched source section",
    "provenance": ["fts"], "fusedRank": 1,
    "reference": ["workspaceID": "D1C2A33A-3A22-4BE5-8BB6-024FEBD23875", "documentID": document,
      "sectionID": section, "relativePath": "notes/\(document).md", "sourceRevision": "source-revision",
      "range": ["lowerBound": 0, "upperBound": 1, "startLine": 1, "endLine": 1], "excerptSHA256": "source-digest"]]
  return try JSONDecoder().decode(WikiSearchHit.self, from: JSONSerialization.data(withJSONObject: fields))
}
