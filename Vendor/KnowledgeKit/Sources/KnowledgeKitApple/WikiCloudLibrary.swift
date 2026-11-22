import Foundation
import FolioKnowledge
import Observation

public struct WikiCloudStatus: Sendable, Equatable {
  public var observedItems = 0
  public var pendingDownloads = 0
  public var pendingUploads = 0
  public var conflicts = 0
  public var failures = 0
  public var gatheringComplete = false
  public var uploaded: Bool {
    gatheringComplete && observedItems > 0 && pendingDownloads == 0 && pendingUploads == 0
      && conflicts == 0 && failures == 0
  }

  /// Only source layout items participate; trash is source recovery data, not a private cache.
  @discardableResult mutating func includeItem(relativePath: String, downloadStatus: String?, isUploaded: Bool,
    hasConflict: Bool, hasFailure: Bool
  ) -> Bool {
    guard Self.isSourceItem(relativePath) else { return false }
    observedItems += 1
    if downloadStatus == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded
      || downloadStatus == NSMetadataUbiquitousItemDownloadingStatusDownloaded { pendingDownloads += 1 }
    if !isUploaded { pendingUploads += 1 }
    if hasConflict { conflicts += 1 }
    if hasFailure { failures += 1 }
    return true
  }

  private static func isSourceItem(_ path: String) -> Bool {
    if path == "_workspace.md" || path == "_ontology.md" || path.hasPrefix("notes/") || path.hasPrefix("attachments/") { return true }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.first == ".folio-trash" else { return false }
    if parts.count == 1 { return true }
    guard UUID(uuidString: String(parts[1])) != nil else { return false }
    if parts.count == 2 { return true }
    return (parts.count == 3 && parts[2] == "record.json") || ["payload", "purging"].contains(parts[2])
  }
}

/// Device-local discovery and transfer observations. Original files remain the source of truth.
@MainActor @Observable public final class WikiCloudLibrary {
  public private(set) var workspaces: [WikiManagedWorkspace] = []
  public private(set) var statusByWorkspace: [UUID: WikiCloudStatus] = [:]
  public private(set) var isGathering = false
  public private(set) var problem: String?
  @ObservationIgnored private var query: NSMetadataQuery?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var root: URL?
  @ObservationIgnored private var containerIdentifier: String?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var updateGeneration = 0
  @ObservationIgnored public var onMaterialized: (@MainActor (UUID) -> Void)?

  public init() {}
  isolated deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) }; query?.stop() }

  public func start(containerIdentifier: String) async {
    if query != nil, self.containerIdentifier == containerIdentifier { receive(); return }
    stop(); let current = generation
    self.containerIdentifier = containerIdentifier; problem = nil; isGathering = true
    do {
      let container = try await WikiWorkspaceAccess.cloudContainer(identifier: containerIdentifier)
      guard generation == current else { return }
      root = container.appendingPathComponent("Documents/Workspaces", isDirectory: true)
      let query = NSMetadataQuery()
      query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
      query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root!.path + "/")
      query.notificationBatchingInterval = 0.3
      for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.receive() }
        })
      }
      self.query = query
      guard query.start() else { throw WikiError.unavailable("iCloud 자료 목록을 시작하지 못했습니다. 다시 연결해 주세요.") }
      receive()
    } catch {
      guard generation == current else { return }
      stop()
      problem = error.localizedDescription; isGathering = false
    }
  }

  public func stop() {
    generation += 1; updateGeneration += 1
    query?.stop(); query = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []; root = nil; isGathering = false
    workspaces = []; statusByWorkspace = [:]
  }

  private func receive() {
    guard let query, let root, let containerIdentifier else { return }
    query.disableUpdates(); defer { query.enableUpdates() }
    let complete = !query.isGathering
    isGathering = !complete
    var ids: Set<UUID> = []; var states: [UUID: WikiCloudStatus] = [:]
    let prefix = root.standardizedFileURL.path + "/"
    for item in query.results.prefix(8192) {
      guard let item = item as? NSMetadataItem,
        let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
        url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
      let parts = url.standardizedFileURL.path.dropFirst(prefix.count).split(separator: "/")
      guard parts.count >= 2, let id = UUID(uuidString: String(parts[0])) else { continue }
      let relative = parts.dropFirst().joined(separator: "/")
      var state = states[id] ?? WikiCloudStatus()
      let download = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
      guard state.includeItem(relativePath: relative, downloadStatus: download,
        isUploaded: item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool == true,
        hasConflict: item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool == true,
        hasFailure: item.value(forAttribute: NSMetadataUbiquitousItemDownloadingErrorKey) != nil
          || item.value(forAttribute: NSMetadataUbiquitousItemUploadingErrorKey) != nil) else { continue }
      ids.insert(id)
      state.gatheringComplete = complete && query.resultCount <= 8192
      states[id] = state
    }
    let previous = statusByWorkspace
    statusByWorkspace = states
    for (id, state) in states {
      if let old = previous[id], state.pendingDownloads < old.pendingDownloads { onMaterialized?(id) }
    }
    updateGeneration += 1; let update = updateGeneration; let current = generation
    Task {
      do {
        let choices = try await Self.choices(root: root, knownIDs: ids, containerIdentifier: containerIdentifier)
        guard generation == current, updateGeneration == update else { return }
        workspaces = choices; problem = nil
      } catch {
        guard generation == current, updateGeneration == update else { return }
        problem = error.localizedDescription
      }
    }
  }

  @concurrent private static func choices(root: URL, knownIDs: Set<UUID>, containerIdentifier: String) async throws -> [WikiManagedWorkspace] {
    var ids = knownIDs
    if FileManager.default.fileExists(atPath: root.path) {
      for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
        if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
          let id = UUID(uuidString: entry.lastPathComponent) { ids.insert(id) }
      }
    }
    return ids.map { id in
      let directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
      let marker = directory.appendingPathComponent("_workspace.md")
      let values = try? marker.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
      // Names are source metadata: materialize only the small identity file for the picker.
      if values?.ubiquitousItemDownloadingStatus == .notDownloaded {
        try? FileManager.default.startDownloadingUbiquitousItem(at: marker)
      }
      let identity = values?.ubiquitousItemDownloadingStatus == .notDownloaded ? nil
        : try? WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: directory, path: "_workspace.md", maximumBytes: 65536))
      return WikiManagedWorkspace(id: id, name: identity?.id == id ? identity!.name : "다운로드할 자료함",
        location: .managedCloud(containerIdentifier: containerIdentifier, workspaceID: id), availableLocally: identity?.id == id)
    }.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
  }
}

extension WikiWorkspaceAccess {
  /// Container lookup can block on account/network state; never perform it on the UI executor.
  @concurrent public static func cloudContainer(identifier: String?) async throws -> URL {
    guard FileManager.default.ubiquityIdentityToken != nil,
      let container = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else {
      throw WikiError.unavailable("iCloud를 사용할 수 없습니다. 같은 Apple 계정의 iCloud Drive와 Folio 접근을 확인해 주세요.")
    }
    return container
  }
}
