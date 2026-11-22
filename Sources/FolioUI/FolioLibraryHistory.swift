import Foundation
import Observation

/// Owns persisted library organization and the current workspace's recent documents.
@MainActor @Observable
final class FolioLibraryHistory {
  private(set) var recentDocumentIDs: [String] = []
  private(set) var archivedLibraryIDs: Set<FolioLibraryIdentity> = []
  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func restoreArchived() throws {
    guard let data = defaults.data(forKey: "Folio.archivedLibraryLocations") else { return }
    archivedLibraryIDs = try JSONDecoder().decode(Set<FolioLibraryIdentity>.self, from: data)
  }

  func restoreRecent(workspaceID: UUID) {
    recentDocumentIDs = defaults.stringArray(forKey: "Folio.recent." + workspaceID.uuidString) ?? []
  }

  func recordOpened(documentID: String, workspaceID: UUID?) {
    recentDocumentIDs = [documentID] + recentDocumentIDs.filter { $0 != documentID }.prefix(19)
    persistRecent(workspaceID: workspaceID)
  }

  func reconcileRecent(replacements: [String: String], removedIDs: Set<String>,
    availableIDs: Set<String>, workspaceID: UUID?
  ) {
    recentDocumentIDs = recentDocumentIDs.filter { !removedIDs.contains($0) }
      .map { replacements[$0] ?? $0 }.filter { availableIDs.contains($0) }
    persistRecent(workspaceID: workspaceID)
  }

  func setArchived(id: FolioLibraryIdentity, archived: Bool) throws {
    var updated = archivedLibraryIDs
    if archived { updated.insert(id) } else { updated.remove(id) }
    let data = try JSONEncoder().encode(updated)
    defaults.set(data, forKey: "Folio.archivedLibraryLocations")
    archivedLibraryIDs = updated
  }

  private func persistRecent(workspaceID: UUID?) {
    guard let workspaceID else { return }
    defaults.set(recentDocumentIDs, forKey: "Folio.recent." + workspaceID.uuidString)
  }
}
