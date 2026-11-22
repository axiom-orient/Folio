import Foundation
import Observation
import FolioNearbyTransport
import FolioKnowledge
import FolioKnowledgeApple

/// Coordinates shared services with windows and application-wide presentation.
/// Each service retains its own mutable state and asynchronous work.
@MainActor @Observable
public final class WikiAppModel {
  typealias Draft = FolioDraft
  var conflictSelection: ConflictSelection?
  let sourceRepairs = FolioSourceRepairs()
  var repairSelection: RepairSelection? {
    get { sourceRepairs.selection }
    set {
      if !sourceRepairs.present(newValue) { message = "먼저 열린 원문 편집을 저장하거나 명시적으로 버려 주세요." }
    }
  }
  var mergeSelection: MergeSelection?
  private(set) var windows: [UUID: WikiWindowState] = [:]
  private(set) var terminationRequested = false
  public var message: String?
  public var previewURL: URL? {
    get { fileIntake.previewURL }
    set { fileIntake.previewURL = newValue }
  }
  public var isBusy: Bool {
    get { terminationRequested || session.isBusy || documentLibrary.phase.isApplying }
    set { session.isBusy = newValue }
  }
  public var isSuspended: Bool { session.isSuspended }
  public var protectedDataAvailable: Bool { storageAccess.protectedDataAvailable }
  public var recentDocumentIDs: [String] { libraryHistory.recentDocumentIDs }
  public var recentDocuments: [WikiDocument] { recentDocumentIDs.compactMap { session.document(id: $0) } }
  func reconcileRecentFiles(replacements: [String: String], removedIDs: Set<String>) {
    libraryHistory.reconcileRecent(replacements: replacements, removedIDs: removedIDs,
      availableIDs: Set(snapshot?.documents.map(\.id) ?? []), workspaceID: snapshot?.workspace.id)
  }
  public var snapshot: WikiSnapshot? { session.snapshot }
  public var openedSourceRoot: URL? { session.openedSourceRoot }
  var archivedLibraryIDs: Set<FolioLibraryIdentity> { libraryHistory.archivedLibraryIDs }
  let libraryHistory: FolioLibraryHistory
  private let documentReader: FolioDocumentReader
  var editorGeneration: Int { draftStore.editingGeneration }
  let draftStore = FolioDraftStore()
  let documentLibrary = FolioDocumentLibrary()
  let markdownImports = FolioMarkdownImports()
  @ObservationIgnored let knowledgeSaves = FolioKnowledgeSaves()
  var drafts: [String: Draft] { draftStore.drafts }
  var legacyDrafts: [String: Draft] { draftStore.legacyDrafts }
  var savingDocuments: Set<String> { draftStore.savingDocuments }
  public var pendingAttachments: [WikiAttachmentImport] { session.pendingAttachments }
  var linkingAttachments: Set<UUID> { fileIntake.linkingAttachments }
  let session: FolioWorkspaceSession
  var workspaceGeneration: Int { session.generation }
  var documentContextGeneration: Int { session.documentGeneration }
  let cloudAccount: FolioCloudAccount
  var access: WikiWorkspaceAccess { session.access }
  var workspace: WikiWorkspace? { session.workspace }
  var location: WikiWorkspaceLocation? { session.location }
  let storageAccess: FolioStorageAccess
  var hasStorageAccess: Bool { storageAccess.isReady }
  #if os(iOS)
  var isPreparingStorage: Bool { storageAccess.isPreparing }
  #endif
  public var cloudLibrary: WikiCloudLibrary { session.cloudLibrary }
  let nearby: FolioNearbyModel
  let fileIntake: FolioFileIntake
  var isImportingReceived: Bool { fileIntake.isImportingReceived }
  var receivedFileTarget: FolioReceivedTarget? { hasOpenWorkspace ? FolioReceivedTarget.current(in: session) : nil }
  public var connectionMessage: String {
    get { session.connectionMessage }
    set { session.connectionMessage = newValue }
  }

  public convenience init(connectProvider: (@MainActor (WikiSearchService, @escaping @MainActor (String) -> Void) async -> Void)? = nil,
    disconnectProvider: (@MainActor () async -> Void)? = nil,
    nearbyEnabled: Bool = true, migrateLegacyStorage: Bool = true
  ) {
    let storageAccess = FolioStorageAccess()
    let session = FolioWorkspaceSession(storageAccess: storageAccess,
      connectProvider: connectProvider, disconnectProvider: disconnectProvider)
    self.init(session: session, storageAccess: storageAccess, history: FolioLibraryHistory(),
      nearbyEnabled: nearbyEnabled, migrateLegacyStorage: migrateLegacyStorage,
      cloudToken: FileManager.default.ubiquityIdentityToken)
  }

  /// Internal composition permits isolated stores and workspace roots without
  /// touching the application's recovery files or standard defaults.
  init(session: FolioWorkspaceSession, storageAccess: FolioStorageAccess, history: FolioLibraryHistory,
    nearbyEnabled: Bool, migrateLegacyStorage: Bool, cloudToken: (any NSObjectProtocol)? = nil
  ) {
    self.session = session
    self.storageAccess = storageAccess
    libraryHistory = history
    nearby = FolioNearbyModel(enabled: nearbyEnabled)
    cloudAccount = FolioCloudAccount(session: session, storageAccess: storageAccess, token: cloudToken)
    fileIntake = FolioFileIntake(session: session, documentLibrary: documentLibrary, nearby: nearby)
    documentReader = FolioDocumentReader(session: session, draftStore: draftStore, history: history)
    cloudAccount.onMessage = { [weak self] in self?.message = $0 }
    fileIntake.onMessage = { [weak self] in self?.message = $0 }
    fileIntake.canWriteSource = { [weak self] in self?.hasOpenWorkspace == true }
    fileIntake.recoveryScope = { [weak self] in self?.draftStore.recoveryScopeURL }
    documentReader.onMessage = { [weak self] in self?.message = $0 }
    draftStore.onFailure = { [weak self] in self?.message = $0 }
    session.onMessage = { [weak self] in self?.message = $0 }
    session.onRefresh = { [weak self] mode in await self?.refreshWindows(after: mode) }
    do { try libraryHistory.restoreArchived() }
    catch { message = "보관 목록을 읽지 못했습니다. 자료함 원문은 그대로 보존되어 있습니다." }
    let storageProblem = storageAccess.initializeApplication(migrateLegacyStorage: migrateLegacyStorage)
    if !hasStorageAccess || !protectedDataAvailable { nearby.restrict() }
    if let storageProblem { message = storageProblem }
  }
  private func refreshWindows(after mode: FolioWorkspaceSession.RefreshMode) async {
    let generation = workspaceGeneration
    for window in windows.values {
      guard session.isCurrent(generation) else { return }
      await loadSelection(window)
      guard session.isCurrent(generation) else { return }
      if mode == .selectionAndSearch, window.hasSearchQuery { await search(window) }
      guard session.isCurrent(generation) else { return }
      if !documentLibrary.phase.isApplying {
        window.reconcileDocuments(snapshot?.documents ?? [],
          unavailableDocumentIDs: Set(snapshot?.staleDocuments.map(\.id) ?? []))
      }
    }
    if !documentLibrary.phase.isApplying, let context = documentContext,
      documentLibrary.context == context { await reloadDocumentLibrary(context: context) }
  }

  public func loadSelection(_ window: WikiWindowState) async { await documentReader.loadSelection(window) }
  public func attach(_ window: WikiWindowState) async {
    await session.waitForClose()
    guard !terminationRequested else { return }
    windows[window.id] = window
    #if os(iOS)
    await prepareStorageAccess()
    guard hasStorageAccess, protectedDataAvailable else { return }
    nearby.allowAccess()
    #endif
    if snapshot != nil && !isSuspended { window.selectedDocumentID = snapshot?.documents.first?.id; await loadSelection(window) }
    else if !isBusy { await restore() }
    if hasStorageAccess, protectedDataAvailable { await nearby.ready() }
  }
  public func detach(_ window: WikiWindowState) async {
    persistDrafts(); windows.removeValue(forKey: window.id)
    if windows.isEmpty { await nearby.stop() }
    #if os(iOS)
    if windows.isEmpty { await close() }
    #endif
  }

  #if os(macOS)
  /// A failed checkpoint leaves the current editing lifetime open. After a
  /// successful checkpoint, no new input or workspace may replace that copy.
  public func closeForTermination() async throws {
    if terminationRequested { await close(); return }
    guard !sourceRepairs.restoreUnsavedInput() else {
      throw WikiError.unavailable("저장하지 않은 원문 편집이 있습니다. 원문을 저장하거나 ‘닫기’에서 ‘편집 버리고 닫기’를 선택한 뒤 다시 종료해 주세요.")
    }
    try draftStore.checkpoint()
    terminationRequested = true
    draftStore.stopPrivateInput()
    draftStore.cancelPendingWrite()
    nearby.restrict()
    await close()
  }
  #endif

  @discardableResult
  func importReceived(_ file: AcornrySavedFile, receipt: AcornryImportReceipt, target: FolioReceivedTarget?,
    in window: WikiWindowState) async -> Bool {
    if FolioTransferFileKind(url: file.fileURL) != .archive,
      (!hasOpenWorkspace || target == nil || receivedFileTarget != target) {
      message = "자료함이 바뀌었습니다. 받은 파일을 다시 선택해 주세요."
      return false
    }
    return await fileIntake.importReceived(file, receipt: receipt, target: target, importSource: { [weak self] url in
      guard let self else { return false }
      let expectedTarget = FolioTransferFileKind(url: file.fileURL) == .archive ? nil : target
      return await self.importSource(url, in: window, expectedTarget: expectedTarget, sourceIdentity: file.fileURL)
    }, didLink: attachmentPresentation(in: window))
  }

  func markdownShare(document: WikiDocument) -> WikiMarkdownShare? {
    guard hasOpenWorkspace, let workspace else { return nil }
    return WikiMarkdownShare(workspace: workspace, path: document.relativePath, revision: document.revision, title: document.title)
  }
  var archiveShare: WikiArchiveShare? {
    guard hasOpenWorkspace, let workspace, let snapshot else { return nil }
    return WikiArchiveShare(workspace: workspace, title: snapshot.workspace.name)
  }

  public func refresh() async {
    await session.refresh()
  }

  public func recoverSearch() async {
    await session.recoverSearch()
  }

  public func captureAttachment(_ url: URL, in window: WikiWindowState) async {
    guard hasOpenWorkspace else { return }
    _ = await fileIntake.capture(url, didLink: attachmentPresentation(in: window))
  }

  func captureAttachment(_ url: URL, in window: WikiWindowState, expectedTarget: FolioReceivedTarget) async {
    guard hasOpenWorkspace, receivedFileTarget == expectedTarget else {
      message = "자료함이 바뀌었습니다. 추가할 자료함에서 파일을 다시 선택하세요."
      return
    }
    _ = await fileIntake.capture(url, expectedTarget: expectedTarget, didLink: attachmentPresentation(in: window))
  }

  public func linkAttachment(_ record: WikiAttachmentImport, in window: WikiWindowState) async {
    guard hasOpenWorkspace else { return }
    _ = await fileIntake.link(record, didLink: attachmentPresentation(in: window))
  }

  public func previewAttachment(path: String) async { await fileIntake.preview(path: path) }

  func attachmentPresentation(in window: WikiWindowState) -> FolioFileIntake.DidLink {
    { [weak self] record, generation in
      guard let self else { return false }
      window.query = ""; window.selectedDocumentID = record.noteID
      await self.loadSelection(window)
      return generation == self.workspaceGeneration
    }
  }

  func declarationText(_ relation: WikiRelation) async throws -> String {
    try await documentReader.declarationText(relation)
  }
}
