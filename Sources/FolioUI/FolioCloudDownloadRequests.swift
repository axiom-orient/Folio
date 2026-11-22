/// Pending-download history belongs to the current session and pending episode.
/// A later observation that is current or absent re-arms a future download request.
enum FolioCloudDownloadRequests {
  static func reconcile(requested: inout Set<String>, pending: Set<String>, expectedGeneration: Int,
    currentGeneration: Int
  ) -> [String]? {
    guard expectedGeneration == currentGeneration else { return nil }
    requested.formIntersection(pending)
    return pending.subtracting(requested).sorted()
  }
}
