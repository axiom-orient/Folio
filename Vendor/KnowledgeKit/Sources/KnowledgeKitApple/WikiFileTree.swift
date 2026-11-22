import Darwin
import Foundation
import FolioKnowledge

/// An immutable inventory includes hidden files, binary children, and empty directories.
/// Folder CAS never relies on the derived document-only snapshot revision.
struct WikiFileTree: Sendable {
  struct Item: Codable, Sendable {
    let path: String
    let isDirectory: Bool
    let revision: String?
  }
  let path: String
  let items: [Item]
  let bytes: [String: Data]
  var isDirectory: Bool { items.first?.isDirectory == true }
  var digest: String {
    SourceDigest.sha256(items.map { "\($0.path.utf8.count):\($0.path):\($0.isDirectory ? "d" : "f"):\($0.revision ?? "")\n" }.joined())
  }
  var revision: String { isDirectory ? digest : items.first?.revision ?? digest }

  static func snapshot(root: URL, path: String, coordinated: Bool = true) throws -> Self {
    let path = try WikiPath.validate(path)
    var metadata = stat()
    try CoordinatedFiles.withParent(root: root, path: path) { parent, name in
      guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw WikiError.changedSource }
    }
    guard [S_IFDIR, S_IFREG].contains(metadata.st_mode & S_IFMT) else { throw WikiError.invalidPath("File management cannot follow links or special files.") }
    var entries: [(String, Bool)] = [("", metadata.st_mode & S_IFMT == S_IFDIR)]
    if metadata.st_mode & S_IFMT == S_IFDIR {
      var failure: (any Error)?
      guard let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(path),
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in failure = error; return false }) else {
        throw WikiError.unavailable("Cannot enumerate managed source.")
      }
      for case let url as URL in enumerator {
        guard entries.count < 8192 else { throw WikiError.unavailable("Managed folders are limited to 8,192 entries.") }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
          throw WikiError.invalidPath("Managed folders cannot contain links or special files.")
        }
        let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
        _ = try WikiPath.validate(relative)
        guard relative.split(separator: "/").count <= 32,
          !(url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.hasSuffix(".icloud")) else {
          throw WikiError.unavailable("Download source and use folders no deeper than 32 levels before managing it.")
        }
        entries.append((relative, values.isDirectory == true))
      }
      if let failure { throw failure }
    }
    var data: [String: Data] = [:]; var items: [Item] = []; var total = 0
    for (relative, directory) in entries.sorted(by: { $0.0 < $1.0 }) {
      let full = relative.isEmpty ? path : path + "/" + relative
      guard try WikiSourceAvailability.itemPresent(root: root, path: full) else { throw WikiError.changedSource }
      if directory {
        try CoordinatedFiles.withParent(root: root, path: full) { parent, name in
          var current = stat()
          guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, current.st_mode & S_IFMT == S_IFDIR else { throw WikiError.changedSource }
        }
        items.append(Item(path: relative, isDirectory: true, revision: nil)); continue
      }
      guard data.count < 2048 else { throw WikiError.unavailable("Managed folders are limited to 2,048 source files.") }
      let url = root.appendingPathComponent(full)
      let limit = ["md", "markdown"].contains(url.pathExtension.lowercased()) ? 256 * 1024 : 50 * 1024 * 1024
      let content = coordinated ? try CoordinatedFiles.read(root: root, path: full, maximumBytes: limit) :
        try CoordinatedFiles.withParent(root: root, path: full) { try CoordinatedFiles.read(parent: $0, name: $1, maximumBytes: limit) }
      total += content.count
      guard total <= 256 * 1024 * 1024 else { throw WikiError.unavailable("Managed source exceeds 256 MiB.") }
      data[relative] = content
      items.append(Item(path: relative, isDirectory: false, revision: SourceDigest.sha256(content)))
    }
    return Self(path: path, items: items, bytes: data)
  }

  func verify(root: URL, coordinated: Bool = true) throws {
    guard try Self.snapshot(root: root, path: path, coordinated: coordinated).digest == digest else { throw WikiError.changedSource }
  }

  func subtree(_ fullPath: String) throws -> Self {
    guard fullPath.hasPrefix(path + "/") else { throw WikiError.invalidPath(fullPath) }
    let prefix = String(fullPath.dropFirst(path.count + 1))
    guard items.contains(where: { $0.path == prefix }) else { throw WikiError.changedSource }
    var children: [Item] = []; var content: [String: Data] = [:]
    for item in items where item.path == prefix || item.path.hasPrefix(prefix + "/") {
      let relative = item.path == prefix ? "" : String(item.path.dropFirst(prefix.count + 1))
      children.append(Item(path: relative, isDirectory: item.isDirectory, revision: item.revision))
      if let data = bytes[item.path] { content[relative] = data }
    }
    return Self(path: fullPath, items: children, bytes: content)
  }

  func replacing(_ replacements: [String: Data]) -> Self {
    let updated = items.map { item -> Item in
      let full = item.path.isEmpty ? path : path + "/" + item.path
      return Item(path: item.path, isDirectory: item.isDirectory,
        revision: replacements[full].map(SourceDigest.sha256) ?? item.revision)
    }
    return Self(path: path, items: updated, bytes: bytes)
  }
}
