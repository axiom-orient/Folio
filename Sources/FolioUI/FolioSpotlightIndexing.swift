import Foundation
import FolioKnowledgeApple

/// Bounded indexing slices share one cancellable session job. A full slice
/// yields before continuing; failures still return to the session owner.
enum FolioSpotlightIndexing {
  @concurrent static func applyPending(_ service: WikiSearchService, maximumBatches: Int? = nil) async throws {
    var marker: URL?
    var token: Data?
    if let groupID = Bundle.main.object(forInfoDictionaryKey: "FolioAppGroupID") as? String,
      let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
      marker = group.appendingPathComponent("SpotlightRecoveryNeeded")
      if let marker { token = try? Data(contentsOf: marker) }
      if token != nil { try await service.workspace.projection.requestReindex(adapter: "spotlight") }
    }
    #if os(iOS)
    let batchBudget = 10
    #else
    let batchBudget = 10000
    #endif
    let sliceBudget = max(1, maximumBatches ?? batchBudget)
    while true {
      try Task.checkCancellation()
      try await service.spotlight.applyPendingJobs(maximumBatches: sliceBudget)
      let pending = try await service.workspace.projection.pendingJobs(adapter: "spotlight", limit: 1)
      try Task.checkCancellation()
      guard !pending.isEmpty else { break }
      await Task.yield()
    }
    if let marker, let token,
      try await service.workspace.projection.pendingJobs(adapter: "spotlight", limit: 1).isEmpty,
      (try? Data(contentsOf: marker)) == token {
      try FileManager.default.removeItem(at: marker)
    }
  }
}
