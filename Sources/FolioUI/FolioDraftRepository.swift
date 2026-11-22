import Foundation
import FolioKnowledge
import FolioKnowledgeApple

/// Synchronous checkpoints are required at the protected-data and termination boundaries.
/// The repository performs I/O; draft transitions never touch the filesystem.
struct FolioDraftRepository {
  let url: URL
  let legacyURL: URL?
  let accountlessURL: URL?
  static let maximumBytes = 16 * 1024 * 1024

  init(url: URL, legacyURL: URL? = nil, accountlessURL: URL? = nil) {
    self.url = url
    self.legacyURL = legacyURL
    self.accountlessURL = accountlessURL
  }

  static func storageDirectory(_ override: URL? = nil) throws -> URL {
    let directory = try override ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).appendingPathComponent("Folio/Drafts", isDirectory: true)
    try WikiLocalStorage.createDirectory(directory)
    return directory
  }

  /// Separate local and cloud copies while preserving external-folder recovery
  /// across bookmark renewal and folder moves.
  static func workspace(_ id: UUID, location: WikiWorkspaceLocation, accountID: UUID? = nil,
    directory override: URL? = nil
  ) throws -> Self {
    struct Scope: Encodable {
      let kind: String
      let workspaceID: UUID
      let container: String?
      let accountID: UUID?
    }
    let scope: Scope
    switch location {
    case .localManaged(let workspaceID):
      guard workspaceID == id else { throw WikiError.changedSource }
      scope = Scope(kind: "local", workspaceID: id, container: nil, accountID: nil)
    case .managedCloud(let container, let workspaceID):
      guard workspaceID == id, accountID != nil else { throw WikiError.changedSource }
      scope = Scope(kind: "cloud", workspaceID: id, container: container, accountID: accountID)
    case .externalMac:
      scope = Scope(kind: "external", workspaceID: id, container: nil, accountID: nil)
    }
    let directory = try storageDirectory(override)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let key = SourceDigest.sha256(try encoder.encode(scope))
    var accountless: URL?
    if case .managedCloud(let container, _) = location {
      let oldScope = Scope(kind: "cloud", workspaceID: id, container: container, accountID: nil)
      accountless = directory.appendingPathComponent("location-" + SourceDigest.sha256(try encoder.encode(oldScope)) + ".json")
    }
    let prefix = scope.accountID.map { "account-" + $0.uuidString.lowercased() + "-" } ?? "location-"
    return Self(url: directory.appendingPathComponent(prefix + key + ".json"),
      legacyURL: directory.appendingPathComponent(id.uuidString.lowercased() + ".json"), accountlessURL: accountless)
  }

  /// Older files contain no location. Read them separately and never write them.
  func loadLegacy() throws -> [String: FolioDraft] {
    do {
      var copies: [String: FolioDraft] = [:]
      for (source, file) in [("workspace", legacyURL), ("accountless", accountlessURL)] {
        guard let file else { continue }
        for (id, draft) in try Self(url: file).load() { copies[source + ":" + id] = draft }
      }
      return copies
    }
    catch {
      throw WikiError.unavailable("이전 편집 복사본을 읽지 못해 자료함의 편집을 중지했습니다. 복사본은 그대로 보존했습니다. " + error.localizedDescription)
    }
  }

  func load() throws -> [String: FolioDraft] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
    guard data.count <= Self.maximumBytes else { throw Self.capacityError }
    return try JSONDecoder().decode([String: FolioDraft].self, from: data)
  }

  func write(_ drafts: [String: FolioDraft]) throws {
    let data = try JSONEncoder().encode(drafts.filter { $0.value.isDirty })
    guard data.count <= Self.maximumBytes else { throw Self.capacityError }
    try data.write(to: url, options: .atomic)
  }

  private static var capacityError: WikiError {
    .unavailable("임시 편집이 16 MiB를 넘었습니다. 문서를 저장하거나 복사본을 공유해 주세요.")
  }
}
