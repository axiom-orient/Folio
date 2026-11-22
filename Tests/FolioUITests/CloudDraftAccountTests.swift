import Darwin
import Foundation
import Testing
import FolioCore

@Test @MainActor func cloudDraftAccountsUseOpaqueEqualityAcrossReopenAndSeparateAccounts() throws {
  let fixture = try CloudDraftAccountFixture()
  defer { fixture.cleanup() }
  let firstArchive = try NSKeyedArchiver.archivedData(withRootObject: DraftAccountToken("A"), requiringSecureCoding: true)
  let nextArchive = try NSKeyedArchiver.archivedData(withRootObject: DraftAccountToken("A"), requiringSecureCoding: true)
  #expect(firstArchive != nextArchive)
  let first = try FolioCore.FolioCloudIdentity.accountID(for: DraftAccountToken("A"), directory: fixture.directory)
  let equivalent = try FolioCore.FolioCloudIdentity.accountID(for: DraftAccountToken("A"), directory: fixture.directory)
  let different = try FolioCore.FolioCloudIdentity.accountID(for: DraftAccountToken("B"), directory: fixture.directory)
  let reopened = try FolioCore.FolioCloudIdentity.accountID(for: DraftAccountToken("A"), directory: fixture.directory)
  #expect(first == equivalent)
  #expect(first == reopened)
  #expect(first != different)
}

@Test @MainActor func missingOrMalformedAccountRecordDoesNotHideExistingScopedDraft() throws {
  let fixture = try CloudDraftAccountFixture()
  defer { fixture.cleanup() }
  struct Registry: Encodable { let version: Int; let entries: [String] }
  let token = DraftAccountToken("A")
  let id = try FolioCore.FolioCloudIdentity.accountID(for: token, directory: fixture.directory)
  let recovery = fixture.directory.appendingPathComponent("account-" + id.uuidString.lowercased() + "-" + String(repeating: "a", count: 64) + ".json")
  let draft = Data("important existing draft".utf8)
  try draft.write(to: recovery)
  let registry = fixture.directory.appendingPathComponent("cloud-accounts-v1.json")
  let completeRegistry = try Data(contentsOf: registry)
  let emptyRegistry = try JSONEncoder().encode(Registry(version: 1, entries: []))
  try emptyRegistry.write(to: registry)
  #expect(throws: (any Error).self) { try FolioCore.FolioCloudIdentity.accountID(for: token, directory: fixture.directory) }
  #expect(try Data(contentsOf: registry) == emptyRegistry)
  #expect(try Data(contentsOf: recovery) == draft)

  try completeRegistry.write(to: registry)
  let unknown = fixture.directory.appendingPathComponent("account-unknown.json")
  try draft.write(to: unknown)
  #expect(throws: (any Error).self) { try FolioCore.FolioCloudIdentity.accountID(for: token, directory: fixture.directory) }
  #expect(try Data(contentsOf: registry) == completeRegistry)
  #expect(try Data(contentsOf: unknown) == draft)
  #expect(try Data(contentsOf: recovery) == draft)
}

@Test @MainActor func unavailableOrDamagedCloudIdentityNeverReplacesExistingRecovery() throws {
  let fixture = try CloudDraftAccountFixture()
  defer { fixture.cleanup() }
  let registry = fixture.directory.appendingPathComponent("cloud-accounts-v1.json")
  let recovery = fixture.directory.appendingPathComponent("account-existing.json")
  let existingDraft = Data("existing private recovery".utf8)
  try existingDraft.write(to: recovery)
  #expect(throws: (any Error).self) { try FolioCore.FolioCloudIdentity.accountID(for: nil, directory: fixture.directory) }
  #expect(throws: (any Error).self) { try FolioCore.FolioCloudIdentity.accountID(for: DraftAccountToken("A"), directory: fixture.directory) }
  #expect(!FileManager.default.fileExists(atPath: registry.path))
  #expect(try Data(contentsOf: recovery) == existingDraft)

  let invalid = Data("invalid registry".utf8)
  try invalid.write(to: registry)
  #expect(throws: (any Error).self) { try FolioCore.FolioCloudIdentity.accountID(for: DraftAccountToken("A"), directory: fixture.directory) }
  #expect(try Data(contentsOf: registry) == invalid)
  #expect(try Data(contentsOf: recovery) == existingDraft)
}

@Test @MainActor func duplicateAccountRecordsAndConcurrentRegistryLockFailClosed() throws {
  let fixture = try CloudDraftAccountFixture()
  defer { fixture.cleanup() }
  struct Entry: Encodable { let id: UUID; let token: Data }
  struct Registry: Encodable { let version: Int; let entries: [Entry] }
  let token = DraftAccountToken("A")
  let bytes = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
  let registry = fixture.directory.appendingPathComponent("cloud-accounts-v1.json")
  let duplicate = try JSONEncoder().encode(Registry(version: 1, entries: [
    Entry(id: UUID(), token: bytes), Entry(id: UUID(), token: bytes)
  ]))
  try duplicate.write(to: registry)
  #expect(throws: (any Error).self) { try FolioCore.FolioCloudIdentity.accountID(for: token, directory: fixture.directory) }
  #expect(try Data(contentsOf: registry) == duplicate)

  let lock = open(fixture.directory.appendingPathComponent(".cloud-accounts-v1.lock").path, O_RDWR | O_CLOEXEC)
  try #require(lock >= 0)
  defer { _ = flock(lock, LOCK_UN); _ = close(lock) }
  try #require(flock(lock, LOCK_EX | LOCK_NB) == 0)
  #expect(throws: (any Error).self) { try FolioCore.FolioCloudIdentity.accountID(for: token, directory: fixture.directory) }
  #expect(try Data(contentsOf: registry) == duplicate)
}

private struct CloudDraftAccountFixture {
  let directory: URL
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioCloudDraftAccounts-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@objc(FolioCloudDraftAccountTestToken)
private final class DraftAccountToken: NSObject, NSSecureCoding {
  static var supportsSecureCoding: Bool { true }
  let value: String
  init(_ value: String) { self.value = value }
  required init?(coder: NSCoder) {
    guard let value = coder.decodeObject(of: NSString.self, forKey: "value") as String? else { return nil }
    self.value = value
  }
  func encode(with coder: NSCoder) {
    coder.encode(value as NSString, forKey: "value")
    coder.encode(UUID().uuidString as NSString, forKey: "nonce")
  }
  override func isEqual(_ object: Any?) -> Bool { (object as? DraftAccountToken)?.value == value }
  override var hash: Int { value.hashValue }
}
