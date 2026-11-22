import Foundation
import FolioSemanticModels
import FolioKnowledge
import FolioKnowledgeApple
import Observation

/// Application projection and job lifetime for the selected workspace.
/// WikiWorkspaceAccess retains sole ownership of filesystem access and leases.
@MainActor @Observable
final class FolioWorkspaceSession {
  enum RefreshMode { case selectionAndSearch, selectionOnly }
  typealias ConnectProvider = @MainActor (WikiSearchService, @escaping @MainActor (String) -> Void) async -> Void
  typealias DisconnectProvider = @MainActor () async -> Void

  private(set) var generation = 0
  private(set) var documentGeneration = 0
  private(set) var workspace: WikiWorkspace?
  private(set) var service: WikiSearchService?
  private(set) var location: WikiWorkspaceLocation?
  private(set) var pendingLocation: WikiWorkspaceLocation?
  private(set) var snapshot: WikiSnapshot?
  private(set) var openedSourceRoot: URL?
  private(set) var pendingAttachments: [WikiAttachmentImport] = []
  var isBusy = false
  private(set) var isSuspended = false
  var protectedDataAvailable: Bool { storageAccess.protectedDataAvailable }
  var isRefreshing: Bool { jobs.isRefreshing }
  var connectionMessage = "SEMI 연결 안 됨"
  let cloudLibrary = WikiCloudLibrary()
  let access = WikiWorkspaceAccess()

  @ObservationIgnored var onMessage: (@MainActor (String) -> Void)?
  @ObservationIgnored var onRefresh: (@MainActor (RefreshMode) async -> Void)?
  @ObservationIgnored private var closeTask: Task<Void, Never>?
  @ObservationIgnored private var cloudSourceObservation: NSObjectProtocol?
  @ObservationIgnored private let jobs = FolioWorkspaceJobs()
  private let storageAccess: FolioStorageAccess
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let stateRoot: @MainActor () throws -> URL
  @ObservationIgnored private let connectProvider: ConnectProvider?
  @ObservationIgnored private let disconnectProvider: DisconnectProvider?
  @ObservationIgnored private let applyIndex: @MainActor (WikiSearchService) async throws -> Void
  private var requestedCloudDownloads: Set<String> = []

  init(defaults: UserDefaults = .standard,
    storageAccess: FolioStorageAccess = FolioStorageAccess(),
    stateRoot: @escaping @MainActor () throws -> URL = FolioWorkspaceSession.defaultStateRoot,
    connectProvider: ConnectProvider? = nil, disconnectProvider: DisconnectProvider? = nil,
    applyIndex: @escaping @MainActor (WikiSearchService) async throws -> Void = { try await FolioSpotlightIndexing.applyPending($0) }
  ) {
    self.defaults = defaults; self.stateRoot = stateRoot; self.storageAccess = storageAccess
    self.connectProvider = connectProvider; self.disconnectProvider = disconnectProvider
    self.applyIndex = applyIndex
    cloudLibrary.onMaterialized = { [weak self] id in
      guard let self, self.isCloudWorkspace, self.snapshot?.workspace.id == id else { return }
      self.requestRefresh()
    }
    cloudSourceObservation = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate,
      object: nil, queue: .main) { [weak self] note in
      let keys = [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey, NSMetadataQueryUpdateRemovedItemsKey]
      let paths = keys.flatMap { note.userInfo?[$0] as? [NSMetadataItem] ?? [] }
        .compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
      MainActor.assumeIsolated { self?.cloudSourceDidChange(paths) }
    }
  }

  isolated deinit {
    if let cloudSourceObservation { NotificationCenter.default.removeObserver(cloudSourceObservation) }
  }

  var hasOpenWorkspace: Bool { workspace != nil && !isSuspended && protectedDataAvailable }
  var isCloudWorkspace: Bool { if case .managedCloud = location { true } else { false } }
  var restoredLocation: WikiWorkspaceLocation? {
    guard let data = defaults.data(forKey: "Folio.location") else { return nil }
    return try? JSONDecoder().decode(WikiWorkspaceLocation.self, from: data)
  }

  func isCurrent(_ generation: Int) -> Bool { self.generation == generation }
  func document(id: String?) -> WikiDocument? { snapshot?.documents.first { $0.id == id } }
  func advanceDocumentGeneration(for opening: FolioWorkspaceOpening) {
    documentGeneration = opening.nextDocumentGeneration(after: documentGeneration)
  }
  func markSuspended() { isSuspended = true }
  func forgetLocation() {
    location = nil; pendingLocation = nil
    defaults.removeObject(forKey: "Folio.location")
  }
  func waitForClose() async { await closeTask?.value }

  /// Window/draft transitions stay with the application and run synchronously at
  /// their original checkpoints; the session owns all resource replacement I/O.
  func open(_ location: WikiWorkspaceLocation, preserveNavigation: Bool, knowledgeAccountScope: UUID? = nil,
    validateSourceAccess: @escaping @Sendable () throws -> Void = {},
    willReplace: @MainActor () -> Void,
    didLoad: @MainActor (WikiSnapshot) throws -> Void
  ) async throws -> Int? {
    generation += 1
    let current = generation
    requestedCloudDownloads = []
    pendingLocation = location
    isBusy = true
    defer { if isCurrent(current) { isBusy = false; pendingLocation = nil } }
    await jobs.drainIndex()
    guard isCurrent(current) else { return nil }
    await jobs.drainRefresh()
    guard isCurrent(current) else { return nil }
    await disconnectProvider?()
    guard isCurrent(current) else { return nil }
    connectionMessage = "SEMI 연결 안 됨"
    await service?.releaseSemanticResources()
    guard isCurrent(current) else { return nil }
    await service?.releaseKnowledgeResources()
    guard isCurrent(current) else { return nil }
    workspace = nil; service = nil
    if !preserveNavigation { snapshot = nil }
    willReplace()
    do {
      let workspace = try await access.open(location, localStateRoot: stateRoot(),
        knowledgeAccountScope: knowledgeAccountScope, validateSourceAccess: validateSourceAccess,
        managedLocalKnowledgeNamespace: managedLocalKnowledgeNamespace(for: location)) { [weak self] in
        Task { @MainActor in
          guard let self, self.isCurrent(current) else { return }
          self.requestRefresh()
        }
      }
      guard isCurrent(current) else { return nil }
      self.workspace = workspace
      let snapshot = try await workspace.refresh()
      guard isCurrent(current) else { return nil }
      self.snapshot = snapshot; self.location = location
      openedSourceRoot = workspace.root
      guard try await refreshPendingAttachments(from: workspace, generation: current) else { return nil }
      let service = WikiSearchService(workspace: workspace, workspaceID: snapshot.workspace.id,
        localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
      self.service = service
      try didLoad(snapshot)
      isSuspended = false
      defaults.set(try JSONEncoder().encode(location), forKey: "Folio.location")
      scheduleIndex(service)
      await requestCloudTextDownloads(snapshot, workspace: workspace, generation: current)
      guard isCurrent(current) else { return nil }
      await onRefresh?(.selectionAndSearch)
      return isCurrent(current) ? current : nil
    } catch {
      guard isCurrent(current) else { return nil }
      throw error
    }
  }

  private func managedLocalKnowledgeNamespace(for location: WikiWorkspaceLocation) -> UUID? {
    #if os(iOS)
    // App updates can relocate the sandbox without replacing this local library.
    guard case .localManaged = location else { return nil }
    let key = "Folio.localKnowledgeNamespace"
    if let value = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) { return value }
    let value = UUID()
    defaults.set(value.uuidString, forKey: key)
    return value
    #else
    return nil
    #endif
  }

  /// Reopening waits for both resource release and the close registration's release.
  func close(prepare: @escaping @MainActor () -> Void) async {
    if let closeTask { await closeTask.value; return }
    let task = Task {
      defer { closeTask = nil }
      await closeWorkspace(prepare: prepare)
    }
    closeTask = task
    await task.value
  }

  func closeWorkspace(preserveView: Bool = false, prepare: @MainActor () -> Void) async {
    cloudLibrary.stop()
    prepare()
    generation += 1
    let current = generation
    await jobs.drainRefresh()
    guard isCurrent(current) else { return }
    await jobs.drainIndex()
    guard isCurrent(current) else { return }
    await disconnectProvider?()
    guard isCurrent(current) else { return }
    await access.close()
    guard isCurrent(current) else { return }
    await service?.releaseSemanticResources()
    guard isCurrent(current) else { return }
    await service?.releaseKnowledgeResources()
    guard isCurrent(current) else { return }
    workspace = nil; service = nil
    if !preserveView { snapshot = nil }
  }

  /// Called synchronously before the application starts its background drain.
  func restrictMobileAccess(protectedDataAvailable: Bool, checkpoint: @MainActor () -> Void) {
    cloudLibrary.stop()
    storageAccess.updateProtectedDataAvailability(protectedDataAvailable); isSuspended = true
    generation += 1; isBusy = false
    checkpoint()
    jobs.cancel()
  }

  func connect() async {
    guard let service else { return }
    let current = generation
    await connectProvider?(service, { [weak self] status in
      guard let self, self.isCurrent(current) else { return }
      self.connectionMessage = status
    })
  }

  func refresh() async {
    let current = generation
    do { _ = try await refreshSnapshot() }
    catch { if isCurrent(current) { onMessage?(error.localizedDescription) } }
  }

  /// Retain the previous inventory on failure and reject responses from a retired source.
  func refreshPendingAttachments(from workspace: WikiWorkspace, generation current: Int) async throws -> Bool {
    guard isCurrent(current) else { return false }
    let attachments = try await workspace.pendingAttachmentImports()
    guard isCurrent(current) else { return false }
    pendingAttachments = attachments
    return true
  }

  @discardableResult
  func refreshSnapshot() async throws -> WikiSnapshot? {
    guard hasOpenWorkspace, let workspace else { return nil }
    let current = generation
    let snapshot = try await workspace.refresh()
    guard isCurrent(current) else { return nil }
    self.snapshot = snapshot
    await requestCloudTextDownloads(snapshot, workspace: workspace, generation: current)
    guard isCurrent(current) else { return nil }
    guard try await refreshPendingAttachments(from: workspace, generation: current) else { return nil }
    if let service { scheduleIndex(service) }
    await onRefresh?(.selectionAndSearch)
    return isCurrent(current) ? self.snapshot : nil
  }

  func recoverSearch() async {
    guard hasOpenWorkspace, let workspace else { return }
    let current = generation
    await jobs.drainIndex()
    guard isCurrent(current) else { return }
    do {
      try await workspace.projection.reset()
      guard isCurrent(current) else { return }
      let rebuilt = try await workspace.refresh()
      guard isCurrent(current) else { return }
      snapshot = rebuilt
      onMessage?(rebuilt.coverageComplete ? "원문에서 검색을 다시 준비했습니다." : "일부 자료를 읽지 못했습니다. 자료별 오류를 확인해 주세요.")
      if let service { scheduleIndex(service) }
      await onRefresh?(.selectionOnly)
    } catch { if isCurrent(current) { onMessage?(error.localizedDescription) } }
  }

  func requestRefresh() {
    jobs.requestRefresh { [weak self] in await self?.refresh() }
  }

  private func cloudSourceDidChange(_ paths: [String]) {
    guard hasOpenWorkspace, isCloudWorkspace, let root = openedSourceRoot else { return }
    if FolioCloudSourceChange.affectsText(paths: paths, root: root) { requestRefresh() }
  }

  private func requestCloudTextDownloads(_ snapshot: WikiSnapshot, workspace: WikiWorkspace, generation: Int) async {
    guard isCloudWorkspace, hasOpenWorkspace else { return }
    let observedPending = Set(snapshot.diagnostics.filter { diagnostic in
      diagnostic.reason == "download_pending" && (diagnostic.path == "_ontology.md"
        || (diagnostic.path.hasPrefix("notes/")
          && ["md", "markdown"].contains(URL(fileURLWithPath: diagnostic.path).pathExtension.lowercased())))
    }.map(\.path))
    guard let pending = FolioCloudDownloadRequests.reconcile(requested: &requestedCloudDownloads,
      pending: observedPending, expectedGeneration: generation, currentGeneration: self.generation) else { return }
    let budget = max(0, 2048 - requestedCloudDownloads.count)
    var failures = 0
    for path in pending.prefix(budget) {
      guard isCurrent(generation), hasOpenWorkspace else { return }
      requestedCloudDownloads.insert(path)
      do { try await workspace.requestSourceDownload(relativePath: path) }
      catch { failures += 1 }
    }
    guard isCurrent(generation) else { return }
    if failures > 0 { onMessage?("일부 원문 다운로드를 요청하지 못했습니다. 확인이 필요한 문서에서 다시 요청해 주세요.") }
    else if pending.count > budget { onMessage?("원문 2,048개의 다운로드를 요청했습니다. 나머지는 확인이 필요한 문서에서 내려받아 주세요.") }
  }

  private func scheduleIndex(_ service: WikiSearchService) {
    let current = generation
    let applyIndex = applyIndex
    jobs.scheduleIndex { [weak self] in
      do {
        try await applyIndex(service)
      } catch is CancellationError {}
      catch {
        if let self, self.isCurrent(current) { self.onMessage?("일반 검색을 사용할 수 있습니다. 시스템 검색: \(error.localizedDescription)") }
      }
    }
  }

  static func defaultStateRoot() throws -> URL {
    if let group = Bundle.main.object(forInfoDictionaryKey: "FolioAppGroupID") as? String {
      guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
        throw WikiError.unavailable("설정된 App Group에 접근할 수 없습니다. Xcode의 서명·그룹 설정을 확인해 주세요.")
      }
      return container.appendingPathComponent("Indexes", isDirectory: true)
    }
    return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("Folio/Indexes", isDirectory: true)
  }
}
