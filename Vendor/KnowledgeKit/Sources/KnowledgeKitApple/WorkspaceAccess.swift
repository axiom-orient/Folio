import Foundation
import FolioKnowledge

public enum WikiWorkspaceLocation: Codable, Sendable, Equatable {
  case localManaged(workspaceID: UUID)
  case managedCloud(containerIdentifier: String?, workspaceID: UUID)
  case externalMac(bookmark: Data)
}

public struct WikiManagedWorkspace: Sendable, Identifiable {
  public let id: UUID
  public let name: String
  public let location: WikiWorkspaceLocation
  public let availableLocally: Bool
}

/// The host retains this owner while the workspace is open and closes it explicitly.
public actor WikiWorkspaceAccess {
  private var scopedURL: URL?
  private var presenter: WikiFolderPresenter?
  private var activeWorkspace: WikiWorkspace?
  private var generation: UInt64 = 0

  public init() {}

  /// The host may supply a persisted installation namespace for its private local workspaces.
  public func open(_ location: WikiWorkspaceLocation, localStateRoot: URL, knowledgeAccountScope: UUID? = nil,
    validateSourceAccess: @escaping @Sendable () throws -> Void = {},
    managedLocalKnowledgeNamespace: UUID? = nil,
    onChange: @escaping @Sendable () -> Void = {}
  ) async throws -> WikiWorkspace {
    generation += 1; let openingGeneration = generation
    await closeCurrent()
    guard openingGeneration == generation else { throw WikiError.unavailable("Workspace opening was superseded.") }
    try validateSourceAccess()
    let root: URL
    switch location {
    case .localManaged(let workspaceID):
      root = try Self.localRoot(workspaceID: workspaceID, create: false)
    case .managedCloud(let containerID, let workspaceID):
      let container = try await Self.cloudContainer(identifier: containerID)
      guard openingGeneration == generation else { throw WikiError.unavailable("Workspace opening was superseded.") }
      try validateSourceAccess()
      root = container.appendingPathComponent("Documents/Workspaces/\(workspaceID.uuidString.lowercased())", isDirectory: true)
      let marker = root.appendingPathComponent("_workspace.md")
      let values = try? marker.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
      if values?.ubiquitousItemDownloadingStatus == .notDownloaded || !FileManager.default.fileExists(atPath: marker.path) {
        try FileManager.default.startDownloadingUbiquitousItem(at: marker)
        for _ in 0..<40 {
          try Task.checkCancellation()
          guard openingGeneration == generation else { throw WikiError.changedSource }
          try validateSourceAccess()
          let downloaded = try? marker.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
          if FileManager.default.fileExists(atPath: marker.path), downloaded?.ubiquitousItemDownloadingStatus != .notDownloaded { break }
          try await Task.sleep(for: .milliseconds(250))
        }
        let downloaded = try? marker.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard FileManager.default.fileExists(atPath: marker.path), downloaded?.ubiquitousItemDownloadingStatus != .notDownloaded else {
          throw WikiError.unavailable("자료함 다운로드를 요청했습니다. iCloud 자료함 목록에서 다운로드가 끝나면 열어 주세요.")
        }
      }
      // Fetch the selected wiki's text; attachments are still opened on demand.
      try validateSourceAccess()
      let notes = root.appendingPathComponent("notes", isDirectory: true)
      if FileManager.default.isUbiquitousItem(at: notes) { try FileManager.default.startDownloadingUbiquitousItem(at: notes) }
      let ontology = root.appendingPathComponent("_ontology.md")
      if FileManager.default.isUbiquitousItem(at: ontology) { try FileManager.default.startDownloadingUbiquitousItem(at: ontology) }
    case .externalMac(let bookmark):
      #if os(macOS)
      var stale = false
      root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
        relativeTo: nil, bookmarkDataIsStale: &stale)
      guard !stale else { throw WikiError.unavailable("Select the workspace again to renew its bookmark.") }
      if root.startAccessingSecurityScopedResource() { scopedURL = root }
      // Non-sandboxed development can access a normal selected folder without a security scope.
      #else
      throw WikiError.unavailable("External Mac workspaces are not available on iPhone.")
      #endif
    }
    do {
      let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
      let identity = try WikiWorkspace.identity(at: canonicalRoot, validateSourceAccess: validateSourceAccess)
      switch location {
      case .localManaged(let expectedID), .managedCloud(_, let expectedID):
        guard identity == expectedID else { throw WikiError.changedSource }
      case .externalMac: break
      }
      let localNamespace: UUID? = if case .localManaged = location { managedLocalKnowledgeNamespace } else { nil }
      let workspace = try WikiWorkspace(root: canonicalRoot,
        localStateDirectory: localStateRoot.appendingPathComponent(identity.uuidString.lowercased()),
        knowledgeAccountScope: knowledgeAccountScope, managedLocalKnowledgeNamespace: localNamespace,
        validateSourceAccess: validateSourceAccess)
      guard workspace.workspaceID == identity else { await workspace.close(); throw WikiError.changedSource }
      let presenter = WikiFolderPresenter(root: canonicalRoot, onChange: onChange)
      NSFileCoordinator.addFilePresenter(presenter); self.presenter = presenter
      activeWorkspace = workspace
      return workspace
    } catch { await closeCurrent(); throw error }
  }

  /// Remove observation before iOS suspension; close still owns source drain.
  public func pauseObservation() {
    generation += 1
    if let presenter { NSFileCoordinator.removeFilePresenter(presenter); self.presenter = nil }
  }

  public func importLocal(from selectedSource: URL) throws -> WikiWorkspaceLocation {
    try Self.importLocal(from: selectedSource)
  }

  public func createManaged(name: String, containerIdentifier: String) async throws -> WikiWorkspaceLocation {
    let container = try await Self.cloudContainer(identifier: containerIdentifier)
    try Task.checkCancellation()
    let id = UUID()
    let root = container.appendingPathComponent("Documents/Workspaces/\(id.uuidString.lowercased())", isDirectory: true)
    guard !FileManager.default.fileExists(atPath: root.path) else { throw WikiError.changedSource }
    try WikiWorkspace.create(at: root, name: name, workspaceID: id)
    return .managedCloud(containerIdentifier: containerIdentifier, workspaceID: id)
  }

  public static func importLocal(from selectedSource: URL) throws -> WikiWorkspaceLocation {
    let root = selectedSource.standardizedFileURL.resolvingSymlinksInPath()
    let identity = try WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: root, path: "_workspace.md", maximumBytes: 65536))
    let destination = try localRoot(workspaceID: identity.id, create: false)
    try WikiWorkspace.copySourceLayout(from: root, to: destination)
    return .localManaged(workspaceID: identity.id)
  }

  public func close() async {
    generation += 1; await closeCurrent()
  }

  private func closeCurrent() async {
    let workspace = activeWorkspace; activeWorkspace = nil
    let scope = scopedURL; scopedURL = nil
    let observer = presenter; presenter = nil
    if let observer { NSFileCoordinator.removeFilePresenter(observer) }
    if let workspace { await workspace.close() }
    scope?.stopAccessingSecurityScopedResource()
  }

  #if os(macOS)
  public static func bookmark(for selectedURL: URL) throws -> Data {
    try selectedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
  }
  #endif

  /// Source files live in the host's private Application Support, independently of iCloud.
  public static func localRoot(workspaceID: UUID, create: Bool) throws -> URL {
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: create)
    let root = support.appendingPathComponent("Folio/Workspaces/\(workspaceID.uuidString.lowercased())", isDirectory: true)
    if create { try WikiLocalStorage.createDirectory(root) }
    return root
  }

  public static func localWorkspaces() throws -> [WikiManagedWorkspace] {
    let directory = try localRoot(workspaceID: UUID(), create: false).deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .compactMap { root in
        guard let id = UUID(uuidString: root.lastPathComponent),
          let identity = try? WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: root, path: "_workspace.md", maximumBytes: 65536)),
          identity.id == id else { return nil }
        return WikiManagedWorkspace(id: id, name: identity.name, location: .localManaged(workspaceID: id), availableLocally: true)
      }.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
  }

  public static func managedRoot(containerIdentifier: String?, workspaceID: UUID, create: Bool) throws -> URL {
    guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
      throw WikiError.unavailable("iCloud Drive is unavailable.")
    }
    let root = container.appendingPathComponent("Documents/Workspaces/\(workspaceID.uuidString.lowercased())", isDirectory: true)
    if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    return root
  }

  public static func managedWorkspaces(containerIdentifier: String?) throws -> [WikiManagedWorkspace] {
    guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
      throw WikiError.unavailable("iCloud Drive is unavailable.")
    }
    let directory = container.appendingPathComponent("Documents/Workspaces", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
      .compactMap { root in
        guard let id = UUID(uuidString: root.lastPathComponent) else { return nil }
        let identity = try? WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: root, path: "_workspace.md", maximumBytes: 65536))
        return WikiManagedWorkspace(id: id, name: identity?.name ?? "동기화 대기 중인 위키",
          location: .managedCloud(containerIdentifier: containerIdentifier, workspaceID: id), availableLocally: identity?.id == id)
      }.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
  }
}

private final class WikiFolderPresenter: NSObject, NSFilePresenter, Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue
  private let onChange: @Sendable () -> Void

  init(root: URL, onChange: @escaping @Sendable () -> Void) {
    presentedItemURL = root; self.onChange = onChange
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
    queue.name = "Folio.FilePresenter"; presentedItemOperationQueue = queue
  }
  func presentedItemDidChange() { onChange() }
  func presentedSubitemDidChange(at url: URL) { onChange() }
  func presentedSubitemDidAppear(at url: URL) { onChange() }
  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange() }
  func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
    onChange(); completionHandler(nil)
  }
}
