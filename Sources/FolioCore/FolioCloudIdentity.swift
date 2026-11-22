import Darwin
import Foundation
import FolioKnowledge
import FolioKnowledgeApple

/// Maps opaque iCloud identity tokens to private, random draft namespaces.
/// Tokens are compared as objects, never by the bytes produced by an archive.
@MainActor
public enum FolioCloudIdentity {
  private struct Entry: Codable {
    let id: UUID
    let token: Data
  }
  private struct Registry: Codable {
    let version: Int
    var entries: [Entry]
  }

  private static let registryName = "cloud-accounts-v1.json"
  private static let lockName = ".cloud-accounts-v1.lock"
  private static let maximumRegistryBytes = 1024 * 1024
  private static let maximumTokenBytes = 64 * 1024
  private static let maximumAccounts = 128

  public static func accountID(for token: (any NSObjectProtocol)?, directory: URL) throws -> UUID {
    try accountID(for: token, directory: directory, sdkRecovery: nil)
  }

  static func accountID(for token: (any NSObjectProtocol)?, directory: URL,
    sdkRecovery: ((Bool) throws -> FolioRecoveryScope.AccountEvidence)?
  ) throws -> UUID {
    guard let token, token is any NSSecureCoding else {
      throw failure("iCloud 계정 정보를 안전하게 확인할 수 없습니다.")
    }
    try WikiLocalStorage.createDirectory(directory)
    let lockPath = directory.appendingPathComponent(lockName).path
    let lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard lock >= 0 else { throw failure("iCloud 편집 복구본 잠금을 열 수 없습니다.") }
    defer { _ = close(lock) }
    var lockInfo = stat()
    guard fstat(lock, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
      flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      throw failure("다른 작업이 iCloud 편집 복구본을 확인하고 있습니다. 잠시 후 다시 시도해 주세요.")
    }
    defer { _ = flock(lock, LOCK_UN) }

    let registryURL = directory.appendingPathComponent(registryName)
    let previous = try readRegistryBytes(registryURL)
    let sdkEvidence = try sdkRecovery?(previous == nil)
      ?? FolioRecoveryScope.AccountEvidence(accounts: [], hasUnclassifiedDrafts: false)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    let accountFiles = files.filter { $0.hasPrefix("account-") && $0.hasSuffix(".json") }
    if previous == nil {
      guard accountFiles.isEmpty, sdkEvidence.accounts.isEmpty else {
        throw failure("iCloud 계정 복구 정보가 없어 기존 편집 복사본을 확인해야 합니다.")
      }
    }
    let registry: Registry
    if let previous {
      do { registry = try JSONDecoder().decode(Registry.self, from: previous) }
      catch { throw failure("iCloud 계정 복구 정보를 읽지 못했습니다.") }
    } else { registry = Registry(version: 1, entries: []) }
    guard registry.version == 1, registry.entries.count <= maximumAccounts,
      Set(registry.entries.map(\.id)).count == registry.entries.count else {
      throw failure("iCloud 계정 복구 정보가 올바르지 않습니다.")
    }
    let registeredIDs = Set(registry.entries.map(\.id))
    guard sdkEvidence.accounts.isSubset(of: registeredIDs) else {
      throw failure("기존 SDK 편집 복사본의 계정 정보를 확인할 수 없습니다.")
    }
    for name in accountFiles {
      guard let id = accountID(fromRecoveryFilename: name), registeredIDs.contains(id) else {
        throw failure("기존 iCloud 편집 복사본의 계정 정보를 확인할 수 없습니다.")
      }
    }

    let tokenClass: AnyClass = type(of: token as AnyObject)
    let allowedClasses: [AnyClass] = [tokenClass, NSData.self, NSString.self, NSNumber.self,
      NSDate.self, NSUUID.self, NSArray.self, NSDictionary.self]
    var decoded: [(UUID, any NSObjectProtocol)] = []
    for entry in registry.entries {
      guard !entry.token.isEmpty, entry.token.count <= maximumTokenBytes else {
        throw failure("iCloud 계정 복구 정보를 확인할 수 없습니다.")
      }
      let object: Any?
      do { object = try NSKeyedUnarchiver.unarchivedObject(ofClasses: allowedClasses, from: entry.token) }
      catch { throw failure("iCloud 계정 복구 정보를 안전하게 읽지 못했습니다.") }
      guard let restored = object as? any NSObjectProtocol, restored is any NSSecureCoding else {
        throw failure("iCloud 계정 복구 정보를 안전하게 확인할 수 없습니다.")
      }
      // Duplicate equivalent tokens with different IDs are ambiguous even if
      // the current token belongs to a different account.
      guard !decoded.contains(where: { $0.1.isEqual(restored) || restored.isEqual($0.1) }) else {
        throw failure("iCloud 계정 복구 정보가 중복되어 확인이 필요합니다.")
      }
      decoded.append((entry.id, restored))
    }
    let matches = decoded.filter { token.isEqual($0.1) && $0.1.isEqual(token) }
    guard matches.count <= 1 else { throw failure("iCloud 계정 복구 정보가 중복되어 확인이 필요합니다.") }
    if let match = matches.first { return match.0 }
    guard !sdkEvidence.hasUnclassifiedDrafts else {
      throw failure("이전 SDK 편집 복사본을 먼저 확인해야 새 iCloud 계정을 등록할 수 있습니다.")
    }
    guard registry.entries.count < maximumAccounts else { throw failure("iCloud 계정 복구 정보가 너무 많습니다.") }

    let archived: Data
    do { archived = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) }
    catch { throw failure("iCloud 계정 정보를 안전하게 보관할 수 없습니다.") }
    guard !archived.isEmpty, archived.count <= maximumTokenBytes else {
      throw failure("iCloud 계정 정보를 안전하게 보관할 수 없습니다.")
    }
    // Verify that this particular token really can be restored and compared
    // before persisting a namespace or admitting any draft writes.
    let roundTrip: Any?
    do { roundTrip = try NSKeyedUnarchiver.unarchivedObject(ofClasses: allowedClasses, from: archived) }
    catch { throw failure("iCloud 계정 정보를 안전하게 복원할 수 없습니다.") }
    guard let restored = roundTrip as? any NSObjectProtocol,
      token.isEqual(restored), restored.isEqual(token) else {
      throw failure("iCloud 계정 정보를 안전하게 복원할 수 없습니다.")
    }
    let id = UUID()
    var updated = registry
    updated.entries.append(Entry(id: id, token: archived))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(updated)
    guard bytes.count <= maximumRegistryBytes else { throw failure("iCloud 계정 복구 정보가 너무 큽니다.") }
    try writeRegistry(bytes, to: registryURL, previous: previous)
    return id
  }

  private static func readRegistryBytes(_ url: URL) throws -> Data? {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw failure("iCloud 계정 복구 정보를 열 수 없습니다.")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size <= maximumRegistryBytes else { throw failure("iCloud 계정 복구 정보가 올바르지 않습니다.") }
    let data = try handle.read(upToCount: maximumRegistryBytes + 1) ?? Data()
    guard data.count <= maximumRegistryBytes else { throw failure("iCloud 계정 복구 정보가 너무 큽니다.") }
    return data
  }

  private static func accountID(fromRecoveryFilename name: String) -> UUID? {
    guard name.hasPrefix("account-"), name.hasSuffix(".json") else { return nil }
    let body = name.dropFirst("account-".count).dropLast(".json".count)
    guard body.utf8.count == 36 + 1 + 64 else { return nil }
    let idString = String(body.prefix(36))
    let remainder = body.dropFirst(36)
    guard remainder.first == "-", let id = UUID(uuidString: idString),
      idString == id.uuidString.lowercased() else { return nil }
    let digest = remainder.dropFirst()
    guard digest.utf8.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
    return id
  }

  private static func writeRegistry(_ data: Data, to url: URL, previous: Data?) throws {
    let stage = url.deletingLastPathComponent().appendingPathComponent(".cloud-accounts-" + UUID().uuidString + ".tmp")
    let descriptor = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw failure("iCloud 계정 복구 정보를 안전하게 준비하지 못했습니다.") }
    var stagePresent = true
    defer { if stagePresent { _ = unlink(stage.path) } }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    guard try readRegistryBytes(url) == previous else { throw failure("iCloud 계정 복구 정보가 변경되어 다시 확인해야 합니다.") }
    if previous == nil {
      guard link(stage.path, url.path) == 0 else { throw failure("iCloud 계정 복구 정보를 안전하게 저장하지 못했습니다.") }
      guard unlink(stage.path) == 0 else { throw failure("iCloud 계정 복구 정보 저장 결과를 다시 확인해 주세요.") }
      stagePresent = false
    } else {
      guard rename(stage.path, url.path) == 0 else { throw failure("iCloud 계정 복구 정보를 안전하게 저장하지 못했습니다.") }
      stagePresent = false
    }
  }

  private static func failure(_ message: String) -> WikiError { .unavailable(message + " 기존 편집 복사본은 보존됩니다.") }
}
