import Foundation
import Observation
import FolioKnowledge
import FolioKnowledgeApple

/// Navigation belongs to a window. Source access, projection and per-note drafts belong to the app.
@MainActor @Observable
public final class WikiWindowState {
  let id = UUID()
  public var query = "" {
    didSet {
      guard query != oldValue else { return }
      invalidateSearch()
    }
  }
  public var filter = WikiDocumentFilter() {
    didSet { if filter != oldValue { invalidateSearch() } }
  }
  struct SearchCriteria: Hashable { let query: String; let filter: WikiDocumentFilter }
  var searchCriteria: SearchCriteria { .init(query: query, filter: filter) }
  var hasSearchQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var searchState: FolioSearchState = .idle
  var hits: [WikiSearchHit] { searchState.hits }
  var isSearching: Bool { searchState.isLoading }
  func invalidateSearch() {
    searchGeneration += 1; searchState.reset(waiting: hasSearchQuery)
  }
  var fileBrowserContext: FolioDocumentContext?
  var isSearchVisible = false
  enum QuickCreation {
    case idle, working
    case awaitingResult(FolioSubmittedDocument)
  }
  var quickCreation: QuickCreation = .idle
  var isCreatingDocument: Bool { if case .working = quickCreation { true } else { false } }
  var quickCreationTitle: String { if case .awaitingResult = quickCreation { "생성 결과 확인" } else { "새 문서" } }
  var fileAction: WikiFileAction?
  var metadataSelection: WikiMetadataSelection?
  struct SavedCitation: Identifiable {
    enum Content {
      case markdown(WikiDocument, sectionID: String, location: String)
      case pdf(WikiKnowledgePDFPreview)
    }
    let id = UUID()
    let documentID: String
    let workspaceGeneration: Int
    let content: Content
  }
  var savedCitation: SavedCitation?
  public var showSidebar = true
  public var selectedDocumentID: String? {
    didSet {
      guard selectedDocumentID != oldValue else { return }
      navigationGeneration += 1
      savedCitation = nil
      editorStartsAtEnd = false
      selectedSectionID = selectedDocumentID.flatMap { readingAnchors[$0] }; isEditing = false
      if recordingHistory, let oldValue {
        backHistory.append(oldValue); backHistory = Array(backHistory.suffix(64)); forwardHistory = []
      }
    }
  }
  private(set) var navigationGeneration = 0
  func beginNavigation() -> Int { navigationGeneration += 1; return navigationGeneration }
  @discardableResult func completeNavigation(_ intent: Int, documentID: String, sectionID: String?) -> Bool {
    guard intent == navigationGeneration else { return false }
    selectedDocumentID = documentID; selectedSectionID = sectionID
    return true
  }
  var readingAnchors: [String: String] = [:]
  private var backHistory: [String] = []
  private var forwardHistory: [String] = []
  private var recordingHistory = true
  private var fileReplacements: [String: String] = [:]
  private var navigationDocumentIDs: Set<String> = []
  private(set) var documentCatalogRevision = 0
  var canGoBack: Bool { !backHistory.isEmpty }
  var canGoForward: Bool { !forwardHistory.isEmpty }
  func goBack() {
    guard let previous = backHistory.popLast() else { return }
    if let current = selectedDocumentID { forwardHistory.append(current) }
    recordingHistory = false; selectedDocumentID = previous; recordingHistory = true
  }
  func goForward() {
    guard let next = forwardHistory.popLast() else { return }
    if let current = selectedDocumentID { backHistory.append(current) }
    recordingHistory = false; selectedDocumentID = next; recordingHistory = true
  }
  func resetNavigation() {
    navigationGeneration += 1; invalidateSearch()
    isSearchVisible = false
    filter = WikiDocumentFilter(); searchState = .idle
    recordingHistory = false; selectedDocumentID = nil; recordingHistory = true
    backHistory = []; forwardHistory = []; readingAnchors = [:]; selectedSectionID = nil; isEditing = false
    fileReplacements = [:]; navigationDocumentIDs = []; documentCatalogRevision += 1
    fileBrowserContext = nil; fileAction = nil
    metadataSelection = nil
    savedCitation = nil
  }
  func applyFileChanges(replacements: [String: String], removedIDs: Set<String>) {
    fileReplacements = replacements
    let affectsSelection = selectedDocumentID.map { removedIDs.contains($0) || replacements[$0] != nil } ?? false
    func mapped(_ id: String) -> String? { removedIDs.contains(id) ? nil : replacements[id] ?? id }
    backHistory = backHistory.compactMap(mapped); forwardHistory = forwardHistory.compactMap(mapped)
    readingAnchors = readingAnchors.filter { !removedIDs.contains($0.key) && replacements[$0.key] == nil }
    recordingHistory = false
    selectedDocumentID = selectedDocumentID.flatMap(mapped)
    recordingHistory = true
    if affectsSelection { selectedSectionID = nil; isEditing = false }
    navigationGeneration += 1; invalidateSearch()
  }
  func reconcileDocuments(_ documents: [WikiDocument], unavailableDocumentIDs: Set<String> = [],
    preservingFileChanges: Bool = false
  ) {
    if !preservingFileChanges { fileReplacements = [:] }
    // Observed but unreadable sources retain their route, never source or editing authority.
    navigationDocumentIDs = Set(documents.map(\.id)).union(unavailableDocumentIDs)
    backHistory.removeAll { !navigationDocumentIDs.contains($0) }
    forwardHistory.removeAll { !navigationDocumentIDs.contains($0) }
    readingAnchors = readingAnchors.filter { navigationDocumentIDs.contains($0.key) }
    if let id = selectedDocumentID, !navigationDocumentIDs.contains(id) {
      recordingHistory = false; selectedDocumentID = nil; recordingHistory = true
    }
    documentCatalogRevision += 1
  }
  func reconcileNavigationPath(_ path: [String]) -> [String] {
    path.map { fileReplacements[$0] ?? $0 }.filter { navigationDocumentIDs.contains($0) }
  }
  func navigationPath(selecting id: String?, in path: [String]) -> [String] {
    guard let id else { return [] }
    let reconciled = reconcileNavigationPath(path)
    guard navigationDocumentIDs.contains(id), reconciled.last != id else { return reconciled }
    return reconciled + [id]
  }
  func selectMarkdownLink(_ link: String, document: WikiDocument) {
    selectedDocumentID = document.id
    selectedSectionID = nil
    if let fragment = link.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first {
      let anchor = String(fragment).removingPercentEncoding ?? String(fragment)
      selectedSectionID = document.sections.first { section in
        section.headingPath.last?.lowercased().replacingOccurrences(of: " ", with: "-") == anchor.lowercased()
      }?.id
      if let selectedSectionID { readingAnchors[document.id] = selectedSectionID }
    }
  }
  public var selectedSectionID: String?
  public var isEditing = false
  var editorStartsAtEnd = false
  public var showConnections = false
  var searchGeneration = 0
  public init() {}
}
