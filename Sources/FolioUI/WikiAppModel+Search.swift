import Foundation
import FolioKnowledge

extension WikiAppModel {
  public func search(_ window: WikiWindowState, append: Bool = false) async {
    guard hasOpenWorkspace, let service = session.service, window.hasSearchQuery else {
      window.invalidateSearch(); window.searchState = .idle; return
    }
    let criteria = window.searchCriteria
    let generation = window.searchGeneration
    let workspaceGeneration = self.workspaceGeneration
    let cursor = append ? window.searchState.results?.nextCursor : nil
    guard let request = window.searchState.begin(append: append) else { return }
    do {
      let page = try await service.searchPage(criteria.query, filter: criteria.filter, cursor: cursor)
      guard !Task.isCancelled, generation == window.searchGeneration,
        criteria == window.searchCriteria, workspaceGeneration == self.workspaceGeneration else { return }
      window.searchState.complete(request: request, page: page)
    } catch is CancellationError {
      if generation == window.searchGeneration { window.searchState.fail(request: request, message: "검색이 중단됐습니다. 다시 시도해 주세요.") }
    } catch {
      guard generation == window.searchGeneration, criteria == window.searchCriteria,
        workspaceGeneration == self.workspaceGeneration else { return }
      if case WikiError.changedSource = error {
        window.invalidateSearch()
        guard let retry = window.searchState.begin(append: false) else { return }
        window.searchState.fail(request: retry, message: "검색 중 원문이 바뀌었습니다. 새로 검색해 주세요.")
      } else { window.searchState.fail(request: request, message: error.localizedDescription) }
    }
  }
}
