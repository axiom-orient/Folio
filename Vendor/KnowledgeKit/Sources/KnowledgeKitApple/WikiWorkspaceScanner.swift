import Foundation
import FolioKnowledge

/// Synchronous source inspection runs inside the workspace actor's admitted I/O segment.
/// The scanner owns no mutable session, projection, or publication state.
struct WikiWorkspaceScanner {
  let root: URL

  func scan(previous: [WikiDocument]) throws -> WikiScan {
    try Task.checkCancellation()
    guard NSFileVersion.unresolvedConflictVersionsOfItem(at: root.appendingPathComponent("_workspace.md"))?.isEmpty != false else {
      throw WikiError.conflict("_workspace.md")
    }
    let identity = try WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: root, path: "_workspace.md", maximumBytes: 65536))
    var diagnostics: [WikiDiagnostic] = []; var complete = true
    var documents: [WikiDocument] = []; var paths = Set<String>()
    var ontology: WikiOntology?; var ontologyUnavailable = false
    let ontologyURL = root.appendingPathComponent("_ontology.md")
    do {
      _ = try FileManager.default.attributesOfItem(atPath: ontologyURL.path)
      if try ontologyURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus == .notDownloaded {
        throw WikiError.unavailable("Relation rules download is pending.")
      }
      guard NSFileVersion.unresolvedConflictVersionsOfItem(at: ontologyURL)?.isEmpty != false else {
        throw WikiError.conflict("_ontology.md")
      }
      ontology = try WikiOntology(bytes: CoordinatedFiles.read(root: root, path: "_ontology.md", maximumBytes: 65536))
    } catch {
      let cocoa = error as? CocoaError
      let missing = cocoa?.code == .fileNoSuchFile || cocoa?.code == .fileReadNoSuchFile
      if !missing || FileManager.default.fileExists(atPath: root.appendingPathComponent("._ontology.md.icloud").path) {
        ontologyUnavailable = true
        let metadataURL = root.appendingPathComponent("_ontology.md")
        let values = try? metadataURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        let reason = if case WikiError.conflict = error { "source_conflict" }
          else if values?.ubiquitousItemDownloadingStatus == .notDownloaded
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("._ontology.md.icloud").path) { "download_pending" }
          else { error.localizedDescription }
        diagnostics.append(.init(path: "_ontology.md", reason: reason))
      }
    }
    let previousByPath = Dictionary(previous.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    guard let enumerator = FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
      options: [.skipsPackageDescendants], errorHandler: { url, error in
        diagnostics.append(.init(path: url.path, reason: error.localizedDescription)); complete = false; return true
      }) else { throw WikiError.unavailable("Cannot enumerate workspace.") }
    for case let url as URL in enumerator {
      try Task.checkCancellation()
      let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
      let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
      guard canonicalPath.hasPrefix(rootPrefix) else {
        diagnostics.append(.init(path: url.path, reason: "path_outside_workspace")); if directory { enumerator.skipDescendants() }; continue
      }
      let relative = String(canonicalPath.dropFirst(rootPrefix.count))
      if url.lastPathComponent.hasPrefix("."), url.lastPathComponent.hasSuffix(".icloud") {
        let originalName = String(url.lastPathComponent.dropFirst().dropLast(".icloud".count))
        let originalURL = url.deletingLastPathComponent().appendingPathComponent(originalName)
        let originalPath = String(originalURL.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(rootPrefix.count))
        if ["md", "markdown"].contains(originalURL.pathExtension.lowercased()) {
          paths.insert(originalPath)
          diagnostics.append(.init(path: originalPath, reason: "download_pending"))
        }
        continue
      }
      if url.lastPathComponent.hasPrefix(".") || ["node_modules", "DerivedData"].contains(url.lastPathComponent) {
        if directory { enumerator.skipDescendants() }; continue
      }
      guard ["md", "markdown"].contains(url.pathExtension.lowercased()), relative != "_workspace.md", relative != "_ontology.md" else { continue }
      paths.insert(relative)
      do {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isSymbolicLink != true else { throw WikiError.invalidPath("Symbolic links are not source documents.") }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
          throw WikiError.unavailable("Source download is pending.")
        }
        guard NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty != false else { throw WikiError.conflict(relative) }
        let bytes = try CoordinatedFiles.read(root: root, path: relative, maximumBytes: 256 * 1024)
        if let cached = previousByPath[relative], cached.metadataVersion == WikiMarkdownParser.metadataVersion,
          cached.revision == SourceDigest.sha256(bytes) { documents.append(cached) }
        else { documents.append(try WikiMarkdownParser.document(relativePath: relative, bytes: bytes)) }
      } catch is CancellationError { throw CancellationError() }
      catch {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        let reason = if case WikiError.conflict = error { "source_conflict" }
          else if values?.ubiquitousItemDownloadingStatus == .notDownloaded { "download_pending" }
          else { error.localizedDescription }
        diagnostics.append(.init(path: relative, reason: reason))
      }
    }
    return WikiScan(workspace: identity, documents: documents, observedPaths: paths, ontology: ontology,
      ontologyUnavailable: ontologyUnavailable, diagnostics: diagnostics, enumerationComplete: complete)
  }
}
