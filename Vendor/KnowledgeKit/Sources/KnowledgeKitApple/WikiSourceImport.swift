import Foundation
import FolioKnowledge
import ZIPFoundation

extension WikiWorkspaceAccess {
  /// Restore a source-only Folio ZIP into a new local workspace. The selected
  /// archive and an existing same-ID workspace are never modified.
  public func importArchive(from selectedArchive: URL) throws -> WikiWorkspaceLocation {
    guard selectedArchive.pathExtension.lowercased() == "zip" else {
      throw WikiError.invalidSource("Select a Folio workspace ZIP.")
    }
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("FolioImports/\(UUID())", isDirectory: true)
    try WikiLocalStorage.createDirectory(parent)
    defer { try? FileManager.default.removeItem(at: parent) }
    let source = parent.appendingPathComponent("Source", isDirectory: true)
    try Self.unpackSourceArchive(at: selectedArchive, to: source)
    try Task.checkCancellation()
    return try Self.importLocal(from: source)
  }

  /// Bounded extraction into a caller-owned, absent destination. No archive path
  /// is used to write outside that destination, including ignored private state.
  static func unpackSourceArchive(at selectedArchive: URL, to destination: URL) throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw WikiError.changedSource }
    let bytes = try CoordinatedFiles.readSelectedFile(at: selectedArchive, maximumBytes: 256 * 1024 * 1024)
    let archive = try Archive(data: bytes, accessMode: .read)
    var entries: [(entry: Entry, path: String)] = []
    var paths = Set<String>(); var files = Set<String>()
    var declared: UInt64 = 0
    let maximum: UInt64 = 256 * 1024 * 1024
    for entry in archive {
      try Task.checkCancellation()
      guard entries.count < 8192, entry.type != .symlink else {
        throw WikiError.invalidSource("ZIP has too many entries or a symbolic link.")
      }
      let raw = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
      let path = try WikiPath.validate(raw)
      guard path.utf8.count <= 4096, path.split(separator: "/").count <= 32 else {
        throw WikiError.invalidPath("ZIP path is too long or too deeply nested.")
      }
      // Reject aliases on the case-insensitive Apple filesystem before extraction.
      let key = path.precomposedStringWithCanonicalMapping.lowercased()
      guard paths.insert(key).inserted, entry.uncompressedSize <= maximum - declared else {
        throw WikiError.invalidSource("ZIP has duplicate paths or exceeds 256 MiB expanded.")
      }
      declared += entry.uncompressedSize
      if entry.type == .file { files.insert(key) }
      entries.append((entry, path))
    }
    for value in entries {
      let components = value.path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
      for length in 1..<components.count {
        guard !files.contains(components.prefix(length).joined(separator: "/")) else {
          throw WikiError.invalidPath("ZIP contains a file used as a parent directory.")
        }
      }
    }
    let markers = entries.filter { $0.entry.type == .file && $0.path.split(separator: "/").last == "_workspace.md" }
    guard markers.count == 1, let marker = markers.first else {
      throw WikiError.invalidSource("Folio ZIP must contain exactly one _workspace.md.")
    }
    let prefix = String(marker.path.dropLast("_workspace.md".count))
    try WikiLocalStorage.createDirectory(destination)
    do {
      var count = 0; var total = 0
      // Keep explicit empty source directories; private/trash layout stays excluded.
      for value in entries where value.entry.type == .directory && value.path.hasPrefix(prefix) && value.path != String(prefix.dropLast()) {
        let relative = String(value.path.dropFirst(prefix.count))
        guard !relative.isEmpty else { continue }
        let path = try WikiPath.validate(relative)
        guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
          path == "notes" || path == "attachments" || path.hasPrefix("notes/") || path.hasPrefix("attachments/") else { continue }
        try WikiLocalStorage.createDirectory(destination.appendingPathComponent(path, isDirectory: true))
      }
      for value in entries where value.entry.type == .file {
        try Task.checkCancellation()
        if value.path.hasPrefix("__MACOSX/") { continue }
        guard value.path.hasPrefix(prefix) else {
          throw WikiError.invalidSource("ZIP contains files outside its workspace folder.")
        }
        let path = try WikiPath.validate(String(value.path.dropFirst(prefix.count)))
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
        let eligible = path == "_workspace.md" || path == "_ontology.md" || path.hasPrefix("notes/") || path.hasPrefix("attachments/")
        guard eligible else { continue }
        count += 1
        guard count <= 2048 else { throw WikiError.invalidSource("Workspace ZIP is limited to 2,048 source files.") }
        let limit = path.hasPrefix("attachments/") ? 50 * 1024 * 1024 : path.hasPrefix("notes/") ? 256 * 1024 : 65536
        guard value.entry.uncompressedSize <= UInt64(limit) else { throw WikiError.invalidSource("ZIP source exceeds its file limit: " + path) }
        let target = destination.appendingPathComponent(path)
        try WikiLocalStorage.createDirectory(target.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: target.path),
          FileManager.default.createFile(atPath: target.path, contents: nil) else {
          throw WikiError.unavailable("Couldn't create imported source: " + path)
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        var written = 0
        let checksum = try archive.extract(value.entry, bufferSize: 64 * 1024) { chunk in
          try Task.checkCancellation()
          guard chunk.count <= limit - written, chunk.count <= 256 * 1024 * 1024 - total else {
            throw WikiError.invalidSource("ZIP expansion exceeds its source budget.")
          }
          written += chunk.count; total += chunk.count
          try handle.write(contentsOf: chunk)
        }
        guard checksum == value.entry.checksum, UInt64(written) == value.entry.uncompressedSize else {
          throw WikiError.invalidSource("ZIP checksum or source size mismatch: " + path)
        }
        try handle.close()
      }
      _ = try WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: destination, path: "_workspace.md", maximumBytes: 65536))
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }
}

extension WikiWorkspace {
  /// Prepare a selected Markdown file as a new note; strict ID/type/relation and
  /// CAS validation remain in prepareEdit. The host retains the selected URL scope.
  public func prepareMarkdownImport(fromSelectedURL selectedURL: URL, operationID: UUID) async throws -> WikiPreparedEdit {
    try requireOpen()
    guard ["md", "markdown"].contains(selectedURL.pathExtension.lowercased()) else {
      throw WikiError.invalidSource("Select a Markdown .md or .markdown file.")
    }
    let original = try CoordinatedFiles.readSelectedFile(at: selectedURL, maximumBytes: 256 * 1024)
    let bytes = try WikiMarkdownEditor.addingStableID(bytes: original, id: UUID().uuidString.lowercased())
    guard bytes.count <= 256 * 1024, let text = String(data: bytes, encoding: .utf8) else {
      throw WikiError.invalidSource("Imported Markdown must fit 256 KiB of UTF-8 including its ID.")
    }
    var path = try WikiPath.validate("notes/" + selectedURL.lastPathComponent)
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
      let stem = selectedURL.deletingPathExtension().lastPathComponent
      path = try WikiPath.validate("notes/\(stem)-\(UUID().uuidString.lowercased()).md")
    }
    return try await prepareEdit(relativePath: path, expectedRevision: nil, range: nil,
      replacement: text, operationID: operationID)
  }
}
