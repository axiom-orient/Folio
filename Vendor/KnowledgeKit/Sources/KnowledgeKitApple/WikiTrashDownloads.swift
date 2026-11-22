import Darwin
import Foundation
import FolioKnowledge
import os

enum WikiTrashDownloadRequest: Sendable {
  case requested
  case failed(String)
}

extension WikiWorkspace {
  /// Explicit retry only restarts materialization. Restore remains a separate,
  /// revision-checked operation after the catalog reports ready source bytes.
  public func requestTrashDownload(id: UUID) throws {
    try requireOpen()
    let prefix = WikiFilePaths.trash + "/" + id.uuidString.lowercased() + "/"
    trashDownloadRequests = trashDownloadRequests.filter { !$0.key.hasPrefix(prefix) }
    do {
      let (record, _) = try WikiTrashRecord.read(root: root, id: id, workspaceID: workspaceID)
      for pending in try pendingTrashPayloadDownloads(record) {
        if let failure = requestTrashItem(pending, id: id) { throw WikiError.unavailable(failure) }
      }
    } catch let pending as WikiSourceAvailability.DownloadPending {
      if let failure = requestTrashItem(pending, id: id) { throw WikiError.unavailable(failure) }
    }
  }

  func pendingTrashEntry(id: UUID, metadata: WikiTrashRecord?,
    pending: [WikiSourceAvailability.DownloadPending]
  ) -> WikiTrashEntry {
    let failures = pending.compactMap { requestTrashItem($0, id: id) }
    let details = pending.map(\.localizedDescription) + failures
    return WikiTrashEntry(id: id, originalPath: metadata?.originalPath ?? "",
      deletedAt: metadata?.deletedAt ?? .distantPast, isDirectory: metadata?.isDirectory ?? false,
      revision: "", state: failures.isEmpty ? .downloading : .needsReview,
      metadataAvailable: metadata != nil, diagnostic: details.joined(separator: "\n"))
  }

  /// Enumerates metadata only. A payload is addressable only after its record
  /// passed workspace/ID/path validation; no guessed source path is downloaded.
  func pendingTrashPayloadDownloads(_ record: WikiTrashRecord) throws -> [WikiSourceAvailability.DownloadPending] {
    var pending: [WikiSourceAvailability.DownloadPending] = []
    func inspect(_ path: String) throws -> Bool {
      do {
        let exists = try WikiSourceAvailability.materializedItemPresent(root: root, path: path)
        if exists { trashDownloadRequests.removeValue(forKey: path) }
        return exists
      } catch let transfer as WikiSourceAvailability.DownloadPending {
        pending.append(transfer); return false
      }
    }
    guard try inspect(record.payloadPath), record.isDirectory else { return pending }
    try CoordinatedFiles.withParent(root: root, path: record.payloadPath + "/probe") { _, _ in }
    let directory = root.appendingPathComponent(record.payloadPath)
    var enumerationError: (any Error)?
    guard let enumerator = FileManager.default.enumerator(at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      errorHandler: { _, error in enumerationError = error; return false }) else {
      throw WikiError.unavailable("Cannot inspect the trash payload directory.")
    }
    var count = 0
    for case let url as URL in enumerator {
      count += 1
      guard count <= 8192, enumerator.level <= 32 else {
        throw WikiError.unavailable("Trash materialization exceeds the managed-folder inventory limit.")
      }
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
        throw WikiError.invalidPath("Trash payloads cannot contain links or special files.")
      }
      let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
      _ = try WikiPath.validate(relative)
      let path = record.payloadPath + "/" + relative
      if url.lastPathComponent.hasPrefix("."), url.lastPathComponent.hasSuffix(".icloud") {
        let name = String(url.lastPathComponent.dropFirst().dropLast(".icloud".count))
        guard !name.isEmpty, name != ".", name != "..", values.isRegularFile == true else {
          throw WikiError.invalidPath("Invalid trash payload placeholder.")
        }
        let original = (path as NSString).deletingLastPathComponent + "/" + name
        _ = try WikiPath.validate(original)
        pending.append(.init(path: original, reason: "ubiquity-placeholder"))
      } else if try !inspect(path), values.isDirectory == true { enumerator.skipDescendants() }
    }
    if let enumerationError { throw enumerationError }
    return pending
  }

  private func requestTrashItem(_ pending: WikiSourceAvailability.DownloadPending, id: UUID) -> String? {
    if let previous = trashDownloadRequests[pending.path] {
      if case .failed(let detail) = previous { return detail }
      return nil
    }
    do {
      let prefix = WikiFilePaths.trash + "/" + id.uuidString.lowercased() + "/"
      let path = try WikiPath.validate(pending.path)
      guard path.hasPrefix(prefix), trashDownloadRequests.count < 2048 else {
        throw WikiError.invalidPath("Trash download target or request budget is invalid.")
      }
      // Parent traversal and both candidate leaf names are descriptor checked.
      // The URL API never receives a symbolic link or arbitrary caller path.
      try CoordinatedFiles.withParent(root: root, path: path) { parent, name in
        for leaf in [name, "." + name + ".icloud"] {
          var info = stat()
          if fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else {
              throw WikiError.invalidPath("Trash download cannot follow links or special files.")
            }
          } else if errno != ENOENT { throw CoordinatedFiles.managementPOSIX() }
        }
      }
      // Mark before the OS call so a synchronous failure is retained for this
      // episode rather than repeatedly retried on every catalog refresh.
      trashDownloadRequests[path] = .requested
      try FileManager.default.startDownloadingUbiquitousItem(at: root.appendingPathComponent(path))
      return nil
    } catch {
      let detail = trashFailureDetail(error, stage: "download-request:" + pending.reason, id: id)
      trashDownloadRequests[pending.path] = .failed(detail)
      return detail
    }
  }

  func trashFailureDetail(_ error: any Error, stage: String, id: UUID) -> String {
    let underlying = error as NSError
    Logger(subsystem: "KnowledgeKitApple", category: "Trash").error(
      "Trash inspection failed id=\(id.uuidString, privacy: .public) stage=\(stage, privacy: .public) domain=\(underlying.domain, privacy: .public) code=\(underlying.code) detail=\(underlying.localizedDescription, privacy: .private)")
    return "Trash \(id.uuidString.lowercased()) \(stage): \(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription) [\(String(reflecting: error))]"
  }
}
