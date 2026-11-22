import Foundation
import CoreSpotlight
import OSLog
import FolioKnowledge

/// Recovery entry point for a Core Spotlight index extension. It opens the
/// App Group projection read-only and redonates eligible items; no source, job, or model access.
public enum WikiSpotlightRecovery {
  public static func reindex(appGroupID: String, identifiers: Set<String>? = nil,
    acknowledgement: @escaping () -> Void
  ) {
    let completion = SpotlightAcknowledgement(acknowledgement)
    Task {
      defer { completion.call() }
      do {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
          throw WikiError.unavailable("Spotlight recovery cannot access the configured App Group.")
        }
        let indexes = group.appendingPathComponent("Indexes", isDirectory: true)
        guard FileManager.default.fileExists(atPath: indexes.path) else { return }
        // The host repairs any late extension donation on its next refresh. The
        // extension never claims jobs, changes source, or migrates a projection.
        try Data(UUID().uuidString.utf8).write(to: group.appendingPathComponent("SpotlightRecoveryNeeded"), options: .atomic)
        for directory in try FileManager.default.contentsOfDirectory(at: indexes, includingPropertiesForKeys: nil) {
          guard UUID(uuidString: directory.lastPathComponent) != nil,
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("knowledge.sqlite").path) else { continue }
          let projection = try WikiProjection(databaseURL: directory.appendingPathComponent("knowledge.sqlite"), readOnly: true)
          guard let snapshot = try await projection.snapshot() else { continue }
          let domain = snapshot.workspace.id.uuidString.lowercased()
          let index = WikiSpotlight.makeIndex(name: "Folio." + domain)
          if let identifiers {
            let ownIDs = identifiers.filter { $0.hasPrefix(domain + "/") }
            try await index.deleteSearchableItems(withIdentifiers: Array(ownIDs))
            let items = snapshot.indexedItems().filter { ownIDs.contains($0.id) }.map(WikiSpotlight.searchableItem)
            try await index.indexSearchableItems(items)
          } else {
            try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            try await index.indexSearchableItems(snapshot.indexedItems().map(WikiSpotlight.searchableItem))
          }
        }
      } catch {
        Logger(subsystem: "com.axient.Folio", category: "SpotlightRecovery")
          .error("Reindex recovery needs the host: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
