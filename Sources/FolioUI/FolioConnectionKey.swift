import CryptoKit
import Foundation
import Security

struct FolioConnectionKey: Sendable {
  let key: Data
  var fingerprint: String { SHA256.hash(data: key).prefix(6).map { String(format: "%02X", $0) }.joined(separator: " ") }

  static func generate() -> Self {
    Self(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
  }
  func validate() throws {
    guard key.count == 32 else { throw FolioTransferStorage.failure("연결 정보를 읽지 못했습니다.") }
  }

}

enum FolioConnectionKeychain {
  private static var query: [String: Any] {
    var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.axient.Folio.nearby", kSecAttrAccount as String: "connection-v1",
      kSecAttrSynchronizable as String: true]
    #if os(macOS)
    value[kSecUseDataProtectionKeychain as String] = true
    #endif
    return value
  }
  static func read() throws -> FolioConnectionKey? {
    #if os(iOS)
    let updated = SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary)
    guard updated == errSecSuccess || updated == errSecItemNotFound else { throw error(updated) }
    #endif
    var value = query; value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(value as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw error(status) }
    let key = FolioConnectionKey(key: data); try key.validate(); return key
  }
  /// No silent replacement: a different existing key may be needed by unknown
  /// outgoing operations. A duplicate creation race resolves to the stored key.
  static func install(_ key: FolioConnectionKey) throws {
    try key.validate()
    if let existing = try read() {
      guard existing.key == key.key else { throw FolioTransferStorage.failure("이미 다른 연결키가 있습니다. 양쪽 기기의 기존 연결키를 사용해 주세요.") }
      return
    }
    var value = query; value[kSecValueData as String] = key.key
    value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(value as CFDictionary, nil)
    if status == errSecDuplicateItem, try read()?.key == key.key { return }
    guard status == errSecSuccess else { throw error(status) }
  }
  private static func error(_ status: OSStatus) -> NSError {
    FolioTransferStorage.failure("연결키를 Apple 키체인에서 읽거나 저장하지 못했습니다 (\(status)). 기기 잠금과 iCloud 키체인 설정을 확인해 주세요.")
  }
}
