import Darwin
import Foundation
import FolioKnowledge

/// Descriptor-bound access preserves the existing MarkdownWiki no-symlink boundary,
/// with a source-wiki layout and coordinated revision checks instead of wiki-only writes.
enum CoordinatedFiles {
  /// A selected File Provider URL may be materialized at a different coordinated URL.
  /// The caller owns the original URL's security scope for the whole accessor.
  static func readSelectedFile(at url: URL, maximumBytes: Int) throws -> Data {
    var failure: NSError?; var result: Result<Data, any Error>?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { actual in
      result = Result {
        let values = try actual.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size > 0, size <= maximumBytes else {
          throw WikiError.invalidSource("Select a nonempty regular file within the requested byte limit.")
        }
        let handle = try FileHandle(forReadingFrom: actual); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw WikiError.invalidSource("Selected file exceeds its byte limit.") }
        return bytes
      }
    }
    if let failure { throw failure }
    guard let result else { throw WikiError.unavailable("Selected file wasn't materialized.") }
    return try result.get()
  }

  static func read(root: URL, path: String, maximumBytes: Int = 4 * 1024 * 1024) throws -> Data {
    let path = try WikiPath.validate(path)
    let url = root.appendingPathComponent(path)
    var failure: NSError?; var result: Result<Data, any Error>?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(readingItemAt: url, options: [], error: &failure) { coordinatedURL in
      result = Result {
        guard coordinatedURL.standardizedFileURL == url.standardizedFileURL else {
          throw WikiError.changedSource
        }
        return try withParent(root: root, path: path) { parent, name in
          try read(parent: parent, name: name, maximumBytes: maximumBytes)
        }
      }
    }
    if let failure { throw failure }
    guard let result else { throw WikiError.unavailable("File coordination did not grant a read.") }
    return try result.get()
  }

  static func write(root: URL, path: String, expectedRevision: String?, bytes: Data, resolvingConflict: Bool = false,
    maximumExistingBytes: Int = 4 * 1024 * 1024,
    validateAccess: @Sendable () throws -> Void = {}
  ) throws {
    let path = try WikiPath.validate(path); let url = root.appendingPathComponent(path)
    var failure: NSError?; var result: Result<Void, any Error>?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(writingItemAt: url, options: [], error: &failure) { coordinatedURL in
      result = Result {
        guard coordinatedURL.standardizedFileURL == url.standardizedFileURL else { throw WikiError.changedSource }
        guard resolvingConflict || NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinatedURL)?.isEmpty != false else {
          throw WikiError.conflict(path)
        }
        try withParent(root: root, path: path) { parent, name in
          // Host/account admission is checked after coordination has granted
          // access, immediately before the source CAS and publication.
          try validateAccess()
          guard try publish(parent: parent, name: name, expectedRevision: expectedRevision,
            bytes: bytes, maximumExistingBytes: maximumExistingBytes) else {
            throw WikiError.unavailable("Source published; directory durability is unconfirmed.")
          }
        }
      }
    }
    if let failure { throw failure }
    guard let result else { throw WikiError.unavailable("File coordination did not grant a write.") }
    try result.get()
  }

  static func withParent<T>(root: URL, path: String, _ body: (Int32, String) throws -> T) throws -> T {
    guard root.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL else {
      throw WikiError.invalidPath("Workspace root is a symbolic link.")
    }
    var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw managementPOSIX() }
    defer { close(descriptor) }
    let components = path.split(separator: "/").map(String.init)
    for component in components.dropLast() {
      let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw managementPOSIX() }; close(descriptor); descriptor = next
    }
    return try body(descriptor, components.last!)
  }

  static func read(parent: Int32, name: String, maximumBytes: Int) throws -> Data {
    let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw managementPOSIX() }; defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size >= 0, info.st_size <= maximumBytes else {
      throw WikiError.invalidSource("Expected a bounded regular source file.")
    }
    var result = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw managementPOSIX() }
      if count == 0 { return result }
      guard result.count + count <= maximumBytes else { throw WikiError.invalidSource("Source grew beyond the read budget.") }
      result.append(contentsOf: buffer.prefix(count))
    }
  }
}
