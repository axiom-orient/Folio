import Foundation
import FolioKnowledge
import ZIPFoundation

/// The consuming app selects its private storage policy. Complete protection is
/// the default; source owned by another provider keeps that provider's policy.
public enum WikiLocalStorage {
  #if os(iOS)
  public static var protection: FileProtectionType {
    Bundle.main.object(forInfoDictionaryKey: "KnowledgeDataProtection") as? String == "after-first-unlock"
      ? .completeUntilFirstUserAuthentication : .complete
  }
  #endif
  public static func createDirectory(_ url: URL) throws {
    #if os(iOS)
    let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700, .protectionKey: protection]
    #else
    let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    #endif
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
    #if os(iOS)
    try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    #endif
  }
}

extension WikiWorkspace {
  /// Export exact committed bytes. An unsaved editor draft is never substituted.
  public func exportMarkdown(relativePath: String, expectedRevision: String) throws -> URL {
    try requireOpen()
    guard NSFileVersion.unresolvedConflictVersionsOfItem(at: root.appendingPathComponent(try WikiPath.validate(relativePath)))?.isEmpty != false else {
      throw WikiError.conflict(relativePath)
    }
    let bytes = try source(relativePath: relativePath)
    guard SourceDigest.sha256(bytes) == expectedRevision else { throw WikiError.changedSource }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioExports/\(UUID())")
    try WikiLocalStorage.createDirectory(directory)
    let url = directory.appendingPathComponent(URL(fileURLWithPath: relativePath).lastPathComponent)
    try bytes.write(to: url, options: .atomic)
    return url
  }

  /// Only the source layout is shared, never local DB, drafts, model state or receipts.
  /// Several files are copied independently; this isn't an atomic cloud snapshot.
  public func exportSourceArchive() throws -> URL {
    try requireOpen()
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("FolioExports/\(UUID())")
    var completed = false
    defer { if !completed { try? FileManager.default.removeItem(at: parent) } }
    let staging = parent.appendingPathComponent("Folio", isDirectory: true)
    try Self.copySourceLayout(from: root, to: staging)
    defer { try? FileManager.default.removeItem(at: staging) }
    let destination = parent.appendingPathComponent("Folio.zip")
    // Foundation's upload ZIP omits empty directories. The private, validated
    // source stage uses the existing pinned archive writer to retain folders.
    try FileManager.default.zipItem(at: staging, to: destination, shouldKeepParent: true, compressionMethod: .deflate)
    guard FileManager.default.fileExists(atPath: destination.path) else { throw WikiError.unavailable("Source archive wasn't created.") }
    completed = true
    return destination
  }

  static func copySourceLayout(from source: URL, to destination: URL) throws {
    let root = source.standardizedFileURL.resolvingSymlinksInPath()
    let identity = try WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: root, path: "_workspace.md", maximumBytes: 65536))
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw WikiError.conflict("Import destination already exists.") }
    try WikiLocalStorage.createDirectory(destination)
    do {
      var enumerationError: (any Error)?
      guard let enumerator = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey], options: [.skipsPackageDescendants],
        errorHandler: { _, error in enumerationError = error; return false }) else {
        throw WikiError.unavailable("Cannot enumerate source files.")
      }
      var count = 0; var total = 0
      var revisions: [String: (revision: String, limit: Int)] = [:]
      for case let url as URL in enumerator {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw WikiError.invalidPath("Source export/import cannot follow symbolic links.") }
        let prefix = root.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw WikiError.invalidPath("Source outside workspace.") }
        let path = try WikiPath.validate(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
        if url.lastPathComponent.hasPrefix(".") {
          if url.lastPathComponent.hasSuffix(".icloud"), path.hasPrefix("notes/") || path.hasPrefix("attachments/") || path == "._ontology.md.icloud" {
            throw WikiError.unavailable("Download source before exporting/importing: " + path)
          }
          if values.isDirectory == true { enumerator.skipDescendants() }; continue
        }
        let eligible = ["_workspace.md", "_ontology.md", "notes", "attachments"].contains(path) || path.hasPrefix("notes/") || path.hasPrefix("attachments/")
        if !eligible && values.isDirectory == true { enumerator.skipDescendants() }
        if eligible, values.isDirectory == true {
          try WikiLocalStorage.createDirectory(destination.appendingPathComponent(path, isDirectory: true))
        }
        guard eligible, values.isRegularFile == true else { continue }
        count += 1; guard count <= 2048 else { throw WikiError.unavailable("Source export/import is limited to 2,048 files.") }
        let limit = path.hasPrefix("attachments/") ? 50 * 1024 * 1024 : path.hasPrefix("notes/") ? 256 * 1024 : 65536
        guard NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty != false else { throw WikiError.conflict(path) }
        let bytes = try CoordinatedFiles.read(root: root, path: path, maximumBytes: limit)
        revisions[path] = (SourceDigest.sha256(bytes), limit)
        total += bytes.count; guard total <= 256 * 1024 * 1024 else { throw WikiError.unavailable("Source export/import exceeds 256 MiB.") }
        let target = destination.appendingPathComponent(path)
        try WikiLocalStorage.createDirectory(target.deletingLastPathComponent())
        try bytes.write(to: target, options: .atomic)
      }
      if let enumerationError { throw enumerationError }
      // Detect edits/deletions during a multi-file copy; this is not a cloud transaction.
      for (path, expected) in revisions {
        guard SourceDigest.sha256(try CoordinatedFiles.read(root: root, path: path, maximumBytes: expected.limit)) == expected.revision else {
          throw WikiError.changedSource
        }
      }
      let copied = try WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: destination, path: "_workspace.md", maximumBytes: 65536))
      let current = try WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: root, path: "_workspace.md", maximumBytes: 65536))
      guard current.id == identity.id, copied.id == identity.id else { throw WikiError.changedSource }
    } catch { try? FileManager.default.removeItem(at: destination); throw error }
  }
}
