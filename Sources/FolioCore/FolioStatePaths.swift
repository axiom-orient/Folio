import Darwin
import Foundation
import FolioKnowledge

/// Validates the host's derived-storage tree before any directory, registry,
/// lock or index is created. A symlink is never adopted as a new state location.
struct FolioStatePaths {
  let hostDirectory: URL
  private let base: URL
  private let sourceRoot: URL

  /// Foundation leaves `/var` unresolved when a URL has a missing tail. Resolve
  /// an existing ancestor first, then restore the missing names without I/O
  /// effects. The result is stable before and after creating the directory.
  static func canonicalDirectoryLocation(_ url: URL) throws -> URL {
    var ancestor = url.standardizedFileURL
    var missing: [String] = []
    while true {
      var info = stat()
      if lstat(ancestor.path, &info) == 0 { break }
      guard errno == ENOENT, ancestor.path != "/" else { throw FolioError.recoveryDamaged }
      missing.append(ancestor.lastPathComponent)
      ancestor.deleteLastPathComponent()
    }
    var resolved = ancestor.resolvingSymlinksInPath()
    for component in missing.reversed() { resolved.appendPathComponent(component, isDirectory: true) }
    return resolved.standardizedFileURL
  }

  init(configuration: FolioConfiguration, sourceRoot: URL) throws {
    base = configuration.stateDirectory.standardizedFileURL
    self.sourceRoot = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
    guard try Self.canonicalDirectoryLocation(base).path == base.path,
      !Self.contains(base, self.sourceRoot), !Self.contains(self.sourceRoot, base) else {
      throw FolioError.sourceStateOverlap
    }
    hostDirectory = base.appendingPathComponent(SourceDigest.sha256(configuration.namespace), isDirectory: true)
    try validateDirectory(base)
    try validateDirectory(hostDirectory)
    let accounts = hostDirectory.appendingPathComponent("Accounts", isDirectory: true)
    try validateDirectory(accounts)
    try validateFile(accounts.appendingPathComponent("cloud-accounts-v1.json"))
    try validateFile(accounts.appendingPathComponent(".cloud-accounts-v1.lock"))
  }

  func workspaceDirectory(scope: String, workspaceID: UUID) throws -> URL {
    guard scope.utf8.count == 64,
      scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw FolioError.invalidConfiguration
    }
    // Revalidate the shared ancestors after the caller's identity preflight.
    try validateDirectory(base)
    try validateDirectory(hostDirectory)
    let scopeRoot = hostDirectory.appendingPathComponent(scope, isDirectory: true)
    let workspace = scopeRoot.appendingPathComponent(workspaceID.uuidString, isDirectory: true)
    try validateDirectory(scopeRoot)
    try validateFile(scopeRoot.appendingPathComponent("scope-v1.json"))
    try validateDirectory(workspace)
    try validateFile(workspace.appendingPathComponent(".session.lock"))
    try validateFile(workspace.appendingPathComponent("drafts-v1.json"))
    let index = workspace.appendingPathComponent("Index", isDirectory: true)
    try validateDirectory(index)
    try validateDirectory(index.appendingPathComponent("OperationReceipts", isDirectory: true))
    for name in ["knowledge.sqlite", "knowledge.sqlite-wal", "knowledge.sqlite-shm", "knowledge.sqlite-journal"] {
      try validateFile(index.appendingPathComponent(name))
    }
    return workspace
  }

  func recordScope(_ scope: FolioRecoveryScope) throws {
    let directory = hostDirectory.appendingPathComponent(try scope.digest, isDirectory: true)
    try validateDirectory(base)
    try validateDirectory(hostDirectory)
    try validateDirectory(directory)
    try validateFile(directory.appendingPathComponent("scope-v1.json"))
    try scope.persist(in: directory)
  }

  private func validateDirectory(_ url: URL) throws {
    try validate(url, leafKind: S_IFDIR)
  }

  private func validateFile(_ url: URL) throws {
    try validate(url, leafKind: S_IFREG)
  }

  private func validate(_ url: URL, leafKind: mode_t) throws {
    let normalized = url.standardizedFileURL
    let resolved = try Self.canonicalDirectoryLocation(normalized)
    guard normalized.path == resolved.path,
      Self.contains(base, normalized), !Self.contains(sourceRoot, resolved) else {
      throw FolioError.sourceStateOverlap
    }
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    let components = normalized.pathComponents.dropFirst()
    for (offset, component) in components.enumerated() {
      current.appendPathComponent(component)
      var info = stat()
      if lstat(current.path, &info) != 0 {
        // Nothing below a missing ancestor exists. Leave creation to the owner.
        if errno == ENOENT { return }
        throw FolioError.recoveryDamaged
      }
      let expected = offset == components.count - 1 ? leafKind : S_IFDIR
      // Foundation deliberately presents system locations such as /private/var
      // as /var even after resolving symlinks. Ancestors above the configured
      // base may therefore be OS aliases. The canonical-location check above
      // still detects repointed ancestors; the base and all derived children
      // must themselves pass lstat without following any symlink.
      if !Self.contains(base, current), (info.st_mode & S_IFMT) == S_IFLNK {
        guard stat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
          throw FolioError.recoveryDamaged
        }
      } else {
        guard (info.st_mode & S_IFMT) == expected else { throw FolioError.recoveryDamaged }
      }
    }
  }

  private static func contains(_ parent: URL, _ child: URL) -> Bool {
    let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
    return parent.path == child.path || child.path.hasPrefix(prefix)
  }
}
