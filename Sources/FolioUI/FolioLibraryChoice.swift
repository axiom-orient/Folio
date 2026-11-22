import FolioKnowledgeApple
import Foundation

/// A retained local source and its cloud copy share a workspace ID, but they
/// are distinct selectable locations in the same collection.
enum FolioLibraryIdentity: Hashable, Codable {
  case local(UUID)
  case cloud(String?, UUID)
  case external(UUID)

  init(location: WikiWorkspaceLocation, workspaceID: UUID) {
    switch location {
    case .localManaged(let id): self = .local(id)
    case .managedCloud(let container, let id): self = .cloud(container, id)
    case .externalMac: self = .external(workspaceID)
    }
  }

  /// A location and workspace together identify a row even when names match.
  var accessibilityIdentifier: String {
    switch self {
    case .local(let id): return "folio-library.local." + id.uuidString.lowercased()
    case .external(let id): return "folio-library.external." + id.uuidString.lowercased()
    case .cloud(let container, let id):
      let containerPart = container.map { "container." + Data($0.utf8).base64EncodedString() } ?? "default"
      return "folio-library.cloud." + containerPart + "." + id.uuidString.lowercased()
    }
  }
}

/// A selectable source location; local and cloud copies retain distinct identities.
struct FolioLibraryChoice: Identifiable {
  let id: FolioLibraryIdentity
  let name: String
  var storage: Storage {
    switch id { case .local: .local; case .cloud: .cloud; case .external: .external }
  }
  var notice: Notice? = nil

  enum Storage: CaseIterable, Hashable {
    case local, cloud, external
    var title: String {
      switch self { case .local: "이 기기"; case .cloud: "iCloud"; case .external: "원문 폴더" }
    }
  }

  struct Notice {
    let text: String
    let symbol: String
  }
}

extension FolioLibraryChoice.Notice {
  init?(cloudStatus status: WikiCloudStatus) {
    if status.failures > 0 { self.init(text: "동기화를 확인해 주세요", symbol: "exclamationmark.circle") }
    else if status.conflicts > 0 { self.init(text: "문서 버전을 확인해 주세요", symbol: "exclamationmark.triangle") }
    else { return nil }
  }
}
