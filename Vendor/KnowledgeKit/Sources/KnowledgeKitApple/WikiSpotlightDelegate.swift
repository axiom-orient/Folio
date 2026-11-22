import CoreSpotlight
import Foundation
import OSLog
import FolioKnowledge

/// Retain this alongside the app's CSSearchableIndex, or use it from an index extension.
/// Reindex acknowledgement follows persistence of the new desired job generation.
public final class WikiSpotlightDelegate: NSObject, CSSearchableIndexDelegate, Sendable {
  private let projection: WikiProjection
  public init(projection: WikiProjection) { self.projection = projection }

  public func searchableIndex(_ searchableIndex: CSSearchableIndex,
    reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void
  ) {
    let acknowledgement = SpotlightAcknowledgement(acknowledgementHandler)
    Task {
      defer { acknowledgement.call() }
      do {
        try await projection.requestReindex(adapter: "spotlight"); acknowledgement.call()
        try await replay()
      }
      catch { Logger(subsystem: "com.axient.Folio", category: "Spotlight").error("Reindex failed: \(error.localizedDescription, privacy: .public)") }
    }
  }

  public func searchableIndex(_ searchableIndex: CSSearchableIndex,
    reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void
  ) {
    let acknowledgement = SpotlightAcknowledgement(acknowledgementHandler)
    Task {
      defer { acknowledgement.call() }
      do {
        try await projection.requestReindex(adapter: "spotlight", subjects: Set(identifiers)); acknowledgement.call()
        try await replay()
      }
      catch { Logger(subsystem: "com.axient.Folio", category: "Spotlight").error("Reindex failed: \(error.localizedDescription, privacy: .public)") }
    }
  }

  public func searchableItems(forIdentifiers identifiers: [String]) async -> [CSSearchableItem] {
    guard let snapshot = try? await projection.snapshot() else { return [] }
    let requested = Set(identifiers)
    return snapshot.indexedItems().filter { requested.contains($0.id) }.map(WikiSpotlight.searchableItem)
  }

  private func replay() async throws {
    guard let snapshot = try await projection.snapshot() else { return }
    let recovery = WikiSpotlight(projection: projection, workspaceID: snapshot.workspace.id)
    try await recovery.applyPendingJobs(maximumBatches: 10000)
  }
}
