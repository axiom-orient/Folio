import Darwin
import Foundation
import FolioKnowledge

extension CoordinatedFiles {
  /// Shared exact publication primitive. False means publication happened but
  /// directory durability is unconfirmed; callers must never treat it as absence.
  static func publish(parent: Int32, name: String, expectedRevision: String?, bytes: Data,
    maximumExistingBytes: Int = 4 * 1024 * 1024) throws -> Bool {
    if let expectedRevision {
      guard SourceDigest.sha256(try read(parent: parent, name: name, maximumBytes: maximumExistingBytes)) == expectedRevision else { throw WikiError.changedSource }
    } else {
      var info = stat()
      guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw WikiError.changedSource }
    }
    let temporary = ".folio-\(UUID().uuidString).tmp"
    let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw managementPOSIX() }
    defer { close(fd); unlinkat(parent, temporary, 0) }
    if expectedRevision != nil {
      var previous = stat()
      if fstatat(parent, name, &previous, AT_SYMLINK_NOFOLLOW) == 0 { _ = fchmod(fd, previous.st_mode & 0o777) }
    }
    try bytes.withUnsafeBytes { buffer in
      var written = 0
      while written < buffer.count {
        let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw managementPOSIX() }; written += count
      }
    }
    guard fsync(fd) == 0 else { throw managementPOSIX() }
    if let expectedRevision {
      guard SourceDigest.sha256(try read(parent: parent, name: name, maximumBytes: maximumExistingBytes)) == expectedRevision else { throw WikiError.changedSource }
      guard renameat(parent, temporary, parent, name) == 0 else { throw managementPOSIX() }
    } else {
      guard linkat(parent, temporary, parent, name, 0) == 0 else { throw managementPOSIX() }
    }
    return fsync(parent) == 0
  }

  static func publish(root: URL, path: String, expectedRevision: String?, bytes: Data) throws -> Bool {
    try withParent(root: root, path: try WikiPath.validate(path)) {
      try publish(parent: $0, name: $1, expectedRevision: expectedRevision, bytes: bytes)
    }
  }

  static func workspaceMutation<T>(root: URL, _ body: (NSFileCoordinator) throws -> T) throws -> T {
    var failure: NSError?; var result: Result<T, any Error>?
    let coordinator = NSFileCoordinator()
    // A directory's ordinary/.forMerging grant does not exclude child writers.
    // .forMoving provides a containment barrier for this child mutation batch;
    // the workspace root itself remains at its selected URL.
    coordinator.coordinate(writingItemAt: root, options: .forMoving, error: &failure) { actual in
      result = Result {
        guard actual.standardizedFileURL == root.standardizedFileURL else { throw WikiError.changedSource }
        return try body(coordinator)
      }
    }
    if let failure { throw failure }
    guard let result else { throw WikiError.unavailable("File coordination did not grant source management.") }
    return try result.get()
  }

  @discardableResult static func ensureDirectory(root: URL, path: String, exclusive: Bool = false) throws -> Bool {
    try withParent(root: root, path: try WikiPath.validate(path)) { parent, name in
      if mkdirat(parent, name, 0o700) != 0 {
        var info = stat()
        guard !exclusive, errno == EEXIST, fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
          info.st_mode & S_IFMT == S_IFDIR else { throw managementPOSIX() }
      }
      return fsync(parent) == 0
    }
  }

  static func requireAbsent(root: URL, path: String) throws {
    try withParent(root: root, path: try WikiPath.validate(path)) { parent, name in
      var info = stat()
      guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw WikiError.conflict("Destination already exists.") }
      let parentURL = root.appendingPathComponent(path).deletingLastPathComponent()
      let aliases = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
      guard !aliases.contains(where: { WikiFilePaths.aliasKey($0) == WikiFilePaths.aliasKey(name) }) else { throw WikiError.conflict("Destination aliases an existing entry.") }
    }
  }

  static func itemExists(root: URL, path: String) throws -> Bool {
    try withParent(root: root, path: try WikiPath.validate(path)) { parent, name in
      var info = stat()
      if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
      guard errno == ENOENT else { throw managementPOSIX() }
      return false
    }
  }

  static func requireMoveDestination(root: URL, from: String, to: String) throws {
    guard from != to else { throw WikiError.invalidPath("Source and destination are identical.") }
    let source = from.split(separator: "/").map(String.init)
    let target = to.split(separator: "/").map(String.init)
    guard source.dropLast().elementsEqual(target.dropLast()),
      WikiFilePaths.aliasKey(from) == WikiFilePaths.aliasKey(to) else {
      try requireAbsent(root: root, path: to); return
    }
    try withParent(root: root, path: from) { parent, name in
      var original = stat(); var destination = stat()
      guard fstatat(parent, name, &original, AT_SYMLINK_NOFOLLOW) == 0,
        [S_IFDIR, S_IFREG].contains(original.st_mode & S_IFMT), let newName = target.last else { throw WikiError.changedSource }
      if fstatat(parent, newName, &destination, AT_SYMLINK_NOFOLLOW) == 0 {
        guard destination.st_dev == original.st_dev, destination.st_ino == original.st_ino else { throw WikiError.conflict("Destination aliases a different item.") }
      } else if errno != ENOENT { throw managementPOSIX() }
      let aliases = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(from).deletingLastPathComponent().path)
        .filter { WikiFilePaths.aliasKey($0) == WikiFilePaths.aliasKey(name) }
      // One readdir entry proves this is a spelling change, not two separate
      // hard-linked/case-sensitive entries that happen to share bytes or inode.
      guard aliases.count == 1, aliases.first == name else { throw WikiError.conflict("Destination collides with another directory entry.") }
    }
  }

  /// Both parent directories are descriptor-bound; publication is exclusive.
  static func moveExclusive(root: URL, from: String, to: String, coordinator: NSFileCoordinator) throws -> Bool {
    try requireMoveDestination(root: root, from: from, to: to)
    return try withParent(root: root, path: from) { source, name in
      try withParent(root: root, path: to) { destination, newName in
        let oldURL = root.appendingPathComponent(from); let newURL = root.appendingPathComponent(to)
        coordinator.item(at: oldURL, willMoveTo: newURL)
        guard renameatx_np(source, name, destination, newName, UInt32(RENAME_EXCL)) == 0 else { throw managementPOSIX() }
        coordinator.item(at: oldURL, didMoveTo: newURL)
        let first = fsync(source) == 0; let second = fsync(destination) == 0
        return first && second
      }
    }
  }

  static func managementPOSIX() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
