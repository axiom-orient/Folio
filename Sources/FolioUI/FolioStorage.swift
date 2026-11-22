import Foundation
import FolioKnowledge
#if os(iOS)
import Security
#endif

/// One-time host migration. Source IDs, drafts and durable receipts move together.
enum FolioStorage {
  static func migrate() throws {
    let manager = FileManager.default
    let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let previous = support.appendingPathComponent("SourceWiki", isDirectory: true)
    let current = support.appendingPathComponent("Folio", isDirectory: true)
    if manager.fileExists(atPath: previous.path) {
      guard !manager.fileExists(atPath: current.path) else {
        throw WikiError.unavailable("이전 자료와 Folio 자료 폴더가 모두 있습니다. 덮어쓰지 않았습니다. Finder에서 두 폴더를 확인하고 한 폴더를 다른 위치에 보관한 뒤 다시 실행해 주세요.")
      }
      // Same-volume rename: failure leaves the old tree intact. Never merge or overwrite.
      try manager.moveItem(at: previous, to: current)
    }

    let defaults = UserDefaults.standard
    let marker = "Folio.storageMigrationCompleted"
    guard !defaults.bool(forKey: marker) else { return }
    var saved = defaults.persistentDomain(forName: "com.axient.SourceWiki") ?? [:]
    saved.merge(defaults.dictionaryRepresentation(), uniquingKeysWith: { _, current in current })
    for (key, value) in saved where key.hasPrefix("SourceWiki.") {
      let replacement = "Folio." + key.dropFirst("SourceWiki.".count)
      if defaults.object(forKey: replacement) == nil { defaults.set(value, forKey: replacement) }
    }
    defaults.set(true, forKey: marker)
  }
  #if os(iOS)
  private static let mobileMigrationMarker = "Folio.firstUnlockStorageMigration.v1"
  private static var mobileAvailabilityQuery: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.axient.Folio.storage", kSecAttrAccount as String: "availability"]
  }

  /// Class C readiness is independent of UIKit's Class A lock notification.
  /// The non-secret Keychain marker can be read only after the first unlock.
  static func mobileDataReady(migrateLegacyStorage: Bool = true) -> Bool {
    var query = mobileAvailabilityQuery
    query[kSecReturnData as String] = true
    var result: CFTypeRef?
    return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
      && (!migrateLegacyStorage || UserDefaults.standard.bool(forKey: mobileMigrationMarker))
  }

  @concurrent static func prepareMobileAccess(migrateLegacyStorage: Bool = true) async throws -> Bool {
    try migrateMobileAccess(migrateLegacyStorage: migrateLegacyStorage)
  }

  private static func migrateMobileAccess(migrateLegacyStorage: Bool) throws -> Bool {
    let query = mobileAvailabilityQuery
    var read = query; read[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(read as CFDictionary, &result)
    if status == errSecInteractionNotAllowed || status == errSecNotAvailable { return false }
    if status == errSecItemNotFound {
      var add = query; add[kSecValueData as String] = Data([1])
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(add as CFDictionary, nil)
      if added == errSecInteractionNotAllowed || added == errSecNotAvailable { return false }
      guard added == errSecSuccess || added == errSecDuplicateItem else {
        throw WikiError.unavailable("자료 준비에 실패했습니다 (\(added)).")
      }
    } else if status != errSecSuccess { throw WikiError.unavailable("자료 준비에 실패했습니다 (\(status)).") }
    guard migrateLegacyStorage else { return true }
    try migrate()
    if !UserDefaults.standard.bool(forKey: mobileMigrationMarker) {
      let manager = FileManager.default
      let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      var roots = [support.appendingPathComponent("Folio", isDirectory: true)]
      if let groupID = Bundle.main.object(forInfoDictionaryKey: "FolioAppGroupID") as? String {
        guard let group = manager.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
          throw WikiError.unavailable("자료 저장 공간을 열지 못했습니다.")
        }
        roots.append(group.appendingPathComponent("Indexes", isDirectory: true))
      }
      let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
      for root in roots where manager.fileExists(atPath: root.path) {
        try manager.setAttributes(attributes, ofItemAtPath: root.path)
        var failure: (any Error)?
        guard let items = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
          errorHandler: { _, error in failure = error; return false }) else { throw WikiError.unavailable("기존 자료를 준비하지 못했습니다.") }
        for case let url as URL in items {
          try Task.checkCancellation()
          if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { items.skipDescendants(); continue }
          try manager.setAttributes(attributes, ofItemAtPath: url.path)
        }
        if let failure { throw failure }
      }
      UserDefaults.standard.set(true, forKey: mobileMigrationMarker)
    }
    return true
  }
  #endif

}
