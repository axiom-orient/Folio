import Foundation

/// The host owns pairing material and immutable outgoing copies. Acornry owns
/// incoming staging, final bytes and receipts; KnowledgeKit owns wiki writes.
enum FolioTransferStorage {
  static let maximumBytes = 256 * 1024 * 1024
  /// A received-file link opens review only; it never accepts or imports bytes.
  static func receivedTransfer(from url: URL) -> UUID? {
    guard url.absoluteString.utf8.count <= 512,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "folio", parts.host == "received", parts.path.isEmpty,
      parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
      let items = parts.queryItems, items.count == 1,
      items[0].name == "transfer", let value = items[0].value
    else { return nil }
    return UUID(uuidString: value)
  }
  static var root: URL {
    get throws {
      try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true).appendingPathComponent("Folio/Nearby", isDirectory: true)
    }
  }

  static func directory(_ url: URL) throws {
    var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    #if os(iOS)
    attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
    #endif
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else { throw failure("전송 저장 위치를 사용할 수 없습니다.") }
    try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
    var location = url; try location.setResourceValues(excluded)
  }

  static func peerID() throws -> UUID {
    let key = "Folio.nearby.peerID"
    if let stored = UserDefaults.standard.string(forKey: key) {
      guard let id = UUID(uuidString: stored) else { throw failure("이 기기의 전송 ID를 읽지 못했습니다. 기존 수신 자료는 보존됩니다.") }
      return id
    }
    let id = UUID(); UserDefaults.standard.set(id.uuidString.lowercased(), forKey: key); return id
  }

  /// Copy only the selected regular file while its security scope and coordinator
  /// lease are held. The asynchronous transfer never depends on a picker lease.
  @concurrent static func copyForSending(_ selected: URL) async throws -> URL {
    let scoped = selected.startAccessingSecurityScopedResource()
    defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
    let folder = try root.appendingPathComponent("Outgoing/\(UUID())", isDirectory: true)
    try directory(folder)
    var result: Result<URL, Error>?
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(readingItemAt: selected, options: .withoutChanges,
      error: &coordinationError) { source in
      result = Result {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size >= 0, size <= maximumBytes else {
          throw failure("일반 파일 하나를 선택해 주세요. 최대 크기는 256MB입니다.")
        }
        let target = folder.appendingPathComponent(source.lastPathComponent)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: attributes) else {
          throw failure("보낼 파일의 복사본을 만들지 못했습니다.")
        }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
        var count = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
          try Task.checkCancellation()
          guard chunk.count <= maximumBytes - count else { throw failure("파일 크기가 전송 한도를 넘었습니다.") }
          count += chunk.count; try output.write(contentsOf: chunk)
        }
        guard count == size else { throw failure("복사 중 파일이 변경되었습니다. 다시 선택해 주세요.") }
        try output.synchronize(); try output.close(); return target
      }
    }
    do {
      if let coordinationError { throw coordinationError }
      guard let result else { throw failure("선택한 파일을 읽지 못했습니다.") }
      return try result.get()
    } catch {
      try? FileManager.default.removeItem(at: folder); throw error
    }
  }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "Folio.Nearby", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
