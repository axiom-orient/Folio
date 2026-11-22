import Foundation

/// Filters notifications from existing system metadata queries to the admitted
/// workspace's text sources. This does not create a query, writer or index.
enum FolioCloudSourceChange {
  static func affectsText(paths: [String], root: URL) -> Bool {
    let prefix = root.standardizedFileURL.path + "/"
    return paths.contains { path in
      let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
      guard normalized.hasPrefix(prefix) else { return false }
      let relative = String(normalized.dropFirst(prefix.count))
      return relative == "_workspace.md" || relative == "_ontology.md" || relative == "notes"
        || relative.hasPrefix("notes/") || relative == ".folio-trash" || relative.hasPrefix(".folio-trash/")
    }
  }
}
