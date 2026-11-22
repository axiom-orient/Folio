import Darwin
import Foundation
import FolioKnowledge
import FolioKnowledgeApple

/// The hash remains compatible with existing SDK recovery directories. Its
/// immutable descriptor lets account admission distinguish local and cloud data.
struct FolioRecoveryScope: Codable, Equatable {
  struct AccountEvidence {
    let accounts: Set<UUID>
    let hasUnclassifiedDrafts: Bool
  }

  let version: Int
  let namespace: String
  let path: String
  let location: String
  let account: UUID?

  init(namespace: String, path: String, location: FolioSourceLocation, account: UUID?) {
    version = 1; self.namespace = namespace; self.path = path; self.account = account
    self.location = switch location { case .local: "local"; case .iCloud(let container): "icloud:" + container }
  }

  var digest: String {
    get throws {
      struct Identity: Encodable {
        let namespace: String; let path: String; let location: String; let account: UUID?
      }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      return SourceDigest.sha256(try encoder.encode(Identity(namespace: namespace, path: path,
        location: location, account: account)))
    }
  }

  func persist(in directory: URL) throws {
    try validate(scope: directory.lastPathComponent, host: directory.deletingLastPathComponent())
    try WikiLocalStorage.createDirectory(directory)
    let destination = directory.appendingPathComponent("scope-v1.json")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(self)
    if let previous = try Self.read(destination, maximumBytes: 65536) {
      guard try JSONDecoder().decode(Self.self, from: previous) == self else { throw FolioError.recoveryDamaged }
      return
    }
    let stage = directory.appendingPathComponent(".scope-" + UUID().uuidString + ".tmp")
    let fd = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard fd >= 0 else { throw FolioError.recoveryDamaged }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close(); _ = unlink(stage.path) }
    try handle.write(contentsOf: bytes); try handle.synchronize()
    if link(stage.path, destination.path) != 0 {
      guard errno == EEXIST, try Self.read(destination, maximumBytes: 65536) == bytes else {
        throw FolioError.recoveryDamaged
      }
    }
  }

  /// Called while the account registry is locked. Legacy recovery without a
  /// descriptor cannot safely be assigned to either a local source or an account.
  static func cloudAccounts(in host: URL, registryMissing: Bool) throws -> AccountEvidence {
    var accounts = Set<UUID>()
    var hasUnclassifiedDrafts = false
    let roots = try FileManager.default.contentsOfDirectory(atPath: host.path)
      .filter { validDigest($0) }
    guard roots.count <= 10000 else { throw FolioError.recoveryDamaged }
    for name in roots {
      let directory = host.appendingPathComponent(name, isDirectory: true)
      try requireDirectory(directory)
      if let bytes = try read(directory.appendingPathComponent("scope-v1.json"), maximumBytes: 65536) {
        let scope = try JSONDecoder().decode(Self.self, from: bytes)
        try scope.validate(scope: name, host: host)
        if let account = scope.account { accounts.insert(account) }
      } else if try hasLegacyDrafts(in: directory, scope: name) {
        hasUnclassifiedDrafts = true
        if registryMissing {
          throw WikiError.unavailable("이전 SDK 편집 복사본의 계정을 확인할 수 없습니다. 기존 상태 폴더를 보존했습니다. 계정 복구 정보를 복원하거나 기존 편집 복사본을 먼저 확인해 주세요.")
        }
      }
    }
    return AccountEvidence(accounts: accounts, hasUnclassifiedDrafts: hasUnclassifiedDrafts)
  }

  private func validate(scope: String, host: URL) throws {
    guard version == 1, !namespace.isEmpty, SourceDigest.sha256(namespace) == host.lastPathComponent,
      path.hasPrefix("/"), !path.contains("\0"), try digest == scope,
      (location == "local" && account == nil)
        || (location.hasPrefix("icloud:") && location.count > "icloud:".count && account != nil) else {
      throw FolioError.recoveryDamaged
    }
  }

  private static func hasLegacyDrafts(in directory: URL, scope: String) throws -> Bool {
    struct LegacyFile: Decodable { let version: Int; let scope: String; let drafts: [String: SDKDraft] }
    let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { UUID(uuidString: $0) != nil }
    guard children.count <= 10000 else { throw FolioError.recoveryDamaged }
    for name in children {
      let workspace = directory.appendingPathComponent(name, isDirectory: true)
      try requireDirectory(workspace)
      if let bytes = try read(workspace.appendingPathComponent("drafts-v1.json"), maximumBytes: 16 * 1024 * 1024) {
        let recovery = try JSONDecoder().decode(LegacyFile.self, from: bytes)
        guard recovery.version == 1, recovery.scope == scope else { throw FolioError.recoveryDamaged }
        if !recovery.drafts.isEmpty { return true }
      }
    }
    return false
  }

  private static func requireDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw FolioError.recoveryDamaged }
  }

  private static func validDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func read(_ url: URL, maximumBytes: Int) throws -> Data? {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw FolioError.recoveryDamaged
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size <= maximumBytes else { throw FolioError.recoveryDamaged }
    let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard bytes.count <= maximumBytes else { throw FolioError.recoveryDamaged }
    return bytes
  }
}
