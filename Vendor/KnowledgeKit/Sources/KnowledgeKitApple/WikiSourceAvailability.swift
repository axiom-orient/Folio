import Darwin
import Foundation
import FolioKnowledge

/// Source inventory and mutation share one local-readiness policy. A missing
/// pathname is not evidence that an iCloud payload was purged.
enum WikiSourceAvailability {
  struct DownloadPending: Error, LocalizedError, Sendable {
    let path: String
    let reason: String
    var errorDescription: String? { "Source download pending (\(reason)): \(path)" }
  }

  static func itemPresent(root: URL, path: String) throws -> Bool {
    do { return try materializedItemPresent(root: root, path: path) }
    catch let pending as DownloadPending { throw WikiError.unavailable(pending.localizedDescription) }
  }

  /// Catalogs need a typed transfer state; mutation callers retain the existing
  /// unavailable error contract and the identical readiness checks above.
  static func materializedItemPresent(root: URL, path: String) throws -> Bool {
    let path = try WikiPath.validate(path)
    let exists = try CoordinatedFiles.withParent(root: root, path: path) { parent, name in
      var placeholder = stat()
      let placeholderName = "." + name + ".icloud"
      if fstatat(parent, placeholderName, &placeholder, AT_SYMLINK_NOFOLLOW) == 0 {
        guard (placeholder.st_mode & S_IFMT) == S_IFREG else {
          throw WikiError.invalidPath("Source placeholders cannot be links or special files.")
        }
        throw DownloadPending(path: path, reason: "ubiquity-placeholder")
      }
      guard errno == ENOENT else { throw CoordinatedFiles.managementPOSIX() }
      var item = stat()
      if fstatat(parent, name, &item, AT_SYMLINK_NOFOLLOW) == 0 {
        guard [S_IFREG, S_IFDIR].contains(item.st_mode & S_IFMT) else { throw WikiError.invalidPath("Source cannot follow links or special files.") }
        return true
      }
      guard errno == ENOENT else { throw CoordinatedFiles.managementPOSIX() }
      return false
    }
    guard exists else { return false }
    let url = root.appendingPathComponent(path)
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey])
    if let reason = downloadReason(status: values.ubiquitousItemDownloadingStatus,
      isDownloading: values.ubiquitousItemIsDownloading == true) {
      throw DownloadPending(path: path, reason: reason)
    }
    try validateState(downloadStatus: values.ubiquitousItemDownloadingStatus,
      isDownloading: values.ubiquitousItemIsDownloading == true, isUbiquitous: values.isUbiquitousItem == true,
      isDirectory: values.isDirectory == true,
      hasConflict: NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty == false, path: path)
    return true
  }

  private static func downloadReason(status: URLUbiquitousItemDownloadingStatus?, isDownloading: Bool) -> String? {
    if isDownloading { return "isDownloading=true,status=" + (status?.rawValue ?? "unknown") }
    if status == .notDownloaded || status == .downloaded { return "status=" + status!.rawValue }
    return nil
  }

  static func validateState(downloadStatus: URLUbiquitousItemDownloadingStatus?, isDownloading: Bool,
    isUbiquitous: Bool, isDirectory: Bool, hasConflict: Bool, path: String
  ) throws {
    guard !isDownloading, downloadStatus != .notDownloaded, downloadStatus != .downloaded,
      !(isUbiquitous && !isDirectory && downloadStatus != .current) else {
      throw WikiError.unavailable("Source is not current on this device (status=\(downloadStatus?.rawValue ?? "unknown"), downloading=\(isDownloading), ubiquitous=\(isUbiquitous), directory=\(isDirectory)). Wait for iCloud before continuing.")
    }
    guard !hasConflict else { throw WikiError.conflict(path) }
  }

  static func requireReady(_ tree: WikiFileTree, root: URL) throws {
    for item in tree.items {
      let path = item.path.isEmpty ? tree.path : tree.path + "/" + item.path
      guard try itemPresent(root: root, path: path) else { throw WikiError.changedSource }
    }
  }
}
