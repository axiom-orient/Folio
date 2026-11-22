import Foundation
import FolioKnowledge

struct WikiTrashRecord: Codable, Sendable {
  enum Phase: String, Codable, Sendable { case prepared, trashed, restoring, restored, purging }
  let id: UUID
  let workspaceID: UUID
  let originalPath: String
  let deletedAt: Date
  let isDirectory: Bool
  let revision: String
  var phase: Phase
  var payloadName: String
  var directory: String { WikiFilePaths.trash + "/" + id.uuidString.lowercased() }
  var recordPath: String { directory + "/record.json" }
  var payloadPath: String { directory + "/" + payloadName }

  static func read(root: URL, id: UUID, workspaceID: UUID) throws -> (Self, Data) {
    let path = WikiFilePaths.trash + "/" + id.uuidString.lowercased() + "/record.json"
    guard try WikiSourceAvailability.materializedItemPresent(root: root, path: path) else { throw WikiError.unavailable("Trash metadata is absent; no local metadata or confirmed cloud placeholder was found.") }
    let bytes = try CoordinatedFiles.read(root: root, path: path, maximumBytes: 65536)
    let record = try JSONDecoder().decode(Self.self, from: bytes)
    guard record.id == id, record.workspaceID == workspaceID,
      ["payload", "purging"].contains(record.payloadName), record.revision.utf8.count == 64,
      record.revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw WikiError.invalidSource("Invalid workspace trash record.")
    }
    _ = try WikiFilePaths.notes(record.originalPath)
    return (record, bytes)
  }
}

enum WikiPreparedFileOperation: Sendable {
  case createFolder(String)
  case move(WikiMovePlan)
  case trash(WikiFileTree, WikiTrashRecord)
  case restore(WikiFileTree, WikiTrashRecord, Data)
  case purge(WikiFileTree?, WikiTrashRecord, Data)
}

extension WikiWorkspace {
  public func libraryEntries() throws -> [WikiLibraryEntry] {
    try requireOpen()
    let tree = try WikiFileTree.snapshot(root: root, path: "notes")
    return try tree.items.filter { !$0.path.isEmpty && !$0.path.split(separator: "/").contains(where: {
      $0.hasPrefix(".") || ["node_modules", "DerivedData"].contains(String($0))
    }) }.map { item in
      let path = "notes/" + item.path
      return WikiLibraryEntry(relativePath: path, isDirectory: item.isDirectory,
        revision: item.isDirectory ? try tree.subtree(path).revision : item.revision ?? "")
    }
  }

  public func trashEntries() throws -> [WikiTrashEntry] {
    try requireOpen()
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(WikiFilePaths.trash).path) else { return [] }
    try CoordinatedFiles.withParent(root: root, path: WikiFilePaths.trash + "/probe") { _, _ in }
    let slots = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(WikiFilePaths.trash), includingPropertiesForKeys: nil)
    guard slots.count <= 4096 else { throw WikiError.unavailable("Trash has more than 4,096 entries. Review its contents before continuing.") }
    let observedIDs = Set(slots.compactMap { UUID(uuidString: $0.lastPathComponent) })
    trashDownloadRequests = trashDownloadRequests.filter { path, _ in
      path.split(separator: "/").dropFirst().first.flatMap { UUID(uuidString: String($0)) }.map(observedIDs.contains) == true
    }
    return slots.compactMap { url -> WikiTrashEntry? in
      if url.lastPathComponent.hasPrefix(".") { return nil }
      guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
      var metadata: WikiTrashRecord?
      do {
        let (record, _) = try WikiTrashRecord.read(root: root, id: id, workspaceID: workspaceID)
        metadata = record
        trashDownloadRequests.removeValue(forKey: record.recordPath)
        if record.phase == .restored {
          return WikiTrashEntry(id: id, originalPath: record.originalPath, deletedAt: record.deletedAt,
            isDirectory: record.isDirectory, revision: "", isAvailable: false,
            diagnostic: "Source was restored; retained trash bookkeeping needs inspection.")
        }
        let pending = try pendingTrashPayloadDownloads(record)
        if !pending.isEmpty { return pendingTrashEntry(id: id, metadata: record, pending: pending) }
        let exists = try WikiSourceAvailability.materializedItemPresent(root: root, path: record.payloadPath)
        let revision: String
        if exists, record.phase == .purging {
          let tree = try WikiFileTree.snapshot(root: root, path: record.payloadPath)
          try WikiSourceAvailability.requireReady(tree, root: root); revision = tree.revision
        } else { revision = exists || record.phase == .purging ? record.revision : "" }
        let available = exists && [WikiTrashRecord.Phase.prepared, .trashed].contains(record.phase)
        return WikiTrashEntry(id: id, originalPath: record.originalPath, deletedAt: record.deletedAt,
          isDirectory: record.isDirectory, revision: revision, isAvailable: available,
          diagnostic: available ? nil : "This trash operation needs inspection; no automatic replay will occur.")
      } catch let pending as WikiSourceAvailability.DownloadPending {
        return pendingTrashEntry(id: id, metadata: metadata, pending: [pending])
      } catch {
        let detail = trashFailureDetail(error, stage: metadata == nil ? "record" : "payload", id: id)
        return WikiTrashEntry(id: id, originalPath: metadata?.originalPath ?? "", deletedAt: metadata?.deletedAt ?? .distantPast,
          isDirectory: metadata?.isDirectory ?? false, revision: "", state: .needsReview,
          metadataAvailable: metadata != nil, diagnostic: detail)
      }
    }.sorted { $0.deletedAt > $1.deletedAt }
  }

  func prepareFileManagement(_ operation: WikiFileOperation, expectedRevision: String?, id: UUID) throws -> WikiPreparedFileOperation {
    try requireOpen()
    switch operation {
    case .createFolder(let raw):
      let path = try WikiFilePaths.notes(raw)
      try CoordinatedFiles.requireAbsent(root: root, path: path)
      return .createFolder(path)
    case .move(let path, let to):
      let plan = try WikiMovePlan(root: root, from: path, to: to)
      if let expectedRevision, expectedRevision != plan.source.revision { throw WikiError.changedSource }
      return .move(plan)
    case .trash(let raw):
      let path = try WikiFilePaths.notes(raw)
      let tree = try WikiFileTree.snapshot(root: root, path: path)
      if let expectedRevision, expectedRevision != tree.revision { throw WikiError.changedSource }
      let record = WikiTrashRecord(id: id, workspaceID: workspaceID, originalPath: path, deletedAt: Date(),
        isDirectory: tree.isDirectory, revision: tree.revision, phase: .prepared, payloadName: "payload")
      return .trash(tree, record)
    case .restore(let id), .purge(let id):
      let (record, bytes) = try WikiTrashRecord.read(root: root, id: id, workspaceID: workspaceID)
      let exists = try WikiSourceAvailability.itemPresent(root: root, path: record.payloadPath)
      if case .purge = operation, !exists {
        guard record.phase == .purging else { throw WikiError.unavailable("Trash payload is missing or still arriving. Its recovery record was preserved.") }
        if let expectedRevision, expectedRevision != record.revision { throw WikiError.changedSource }
        return .purge(nil, record, bytes)
      }
      guard exists else { throw WikiError.unavailable("Trash payload is not available. Wait for its download before restoring.") }
      let tree = try WikiFileTree.snapshot(root: root, path: record.payloadPath)
      try WikiSourceAvailability.requireReady(tree, root: root)
      if let expectedRevision, expectedRevision != tree.revision { throw WikiError.changedSource }
      if case .restore = operation {
        guard [.prepared, .trashed].contains(record.phase), tree.revision == record.revision,
          tree.isDirectory == record.isDirectory else { throw WikiError.changedSource }
        try CoordinatedFiles.requireAbsent(root: root, path: record.originalPath)
        return .restore(tree, record, bytes)
      }
      guard record.phase == .purging || tree.revision == record.revision else { throw WikiError.changedSource }
      return .purge(tree, record, bytes)
    case .createDocument: throw WikiError.invalidSource("Document creation uses the existing validated edit lane.")
    }
  }
}
