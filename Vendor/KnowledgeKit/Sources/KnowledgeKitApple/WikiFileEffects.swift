import Darwin
import Foundation
import FolioKnowledge

struct WikiFileEffect {
  let before: String?
  let after: String?
  let trashID: UUID?
  let moves: [WikiDocumentMove]
  var diagnostics: [String]
}

enum WikiFileEffects {
  static func preview(_ prepared: WikiPreparedFileOperation, id: UUID) throws -> WikiFileChange {
    let before: String?; let after: String?; let trashID: UUID?; let moves: [WikiDocumentMove]
    switch prepared {
    case .createFolder(let path): before = nil; after = path; trashID = nil; moves = []
    case .move(let plan): before = plan.from; after = plan.to; trashID = nil; moves = plan.documentMoves
    case .trash(let tree, let record): before = tree.path; after = nil; trashID = record.id; moves = []
    case .restore(let tree, let record, _):
      before = nil; after = record.originalPath; trashID = record.id
      moves = try restoredDocuments(tree, originalPath: record.originalPath)
    case .purge(_, let record, _): before = nil; after = nil; trashID = record.id; moves = []
    }
    return WikiFileChange(operationID: id, beforePath: before, afterPath: after, trashID: trashID,
      documentMoves: moves, projectionUpdated: false, diagnostic: nil)
  }

  static func apply(_ prepared: WikiPreparedFileOperation, root: URL, id: UUID, coordinator: NSFileCoordinator) throws -> WikiFileEffect {
    switch prepared {
    case .createFolder(let path):
      try CoordinatedFiles.requireAbsent(root: root, path: path)
      let durable = try CoordinatedFiles.ensureDirectory(root: root, path: path, exclusive: true)
      return WikiFileEffect(before: nil, after: path, trashID: nil, moves: [], diagnostics: durability(durable))
    case .move(let plan): return try move(plan, root: root, id: id, coordinator: coordinator)
    case .trash(let tree, var record):
      try tree.verify(root: root, coordinated: false)
      try CoordinatedFiles.ensureDirectory(root: root, path: WikiFilePaths.trash)
      try CoordinatedFiles.ensureDirectory(root: root, path: record.directory, exclusive: true)
      let initial = try JSONEncoder().encode(record)
      _ = try CoordinatedFiles.publish(root: root, path: record.recordPath, expectedRevision: nil, bytes: initial)
      try tree.verify(root: root, coordinated: false)
      let durable = try CoordinatedFiles.moveExclusive(root: root, from: tree.path, to: record.payloadPath, coordinator: coordinator)
      var diagnostics = durability(durable)
      record.phase = .trashed
      do { _ = try CoordinatedFiles.publish(root: root, path: record.recordPath, expectedRevision: SourceDigest.sha256(initial), bytes: JSONEncoder().encode(record)) }
      catch { diagnostics.append("Source moved to trash; trash metadata finalization is pending.") }
      return WikiFileEffect(before: tree.path, after: nil, trashID: record.id, moves: [], diagnostics: diagnostics)
    case .restore(let tree, var record, let bytes):
      try verifyRecord(record, bytes: bytes, root: root)
      try WikiSourceAvailability.requireReady(tree, root: root)
      try tree.verify(root: root, coordinated: false)
      let moves = try restoredDocuments(tree, originalPath: record.originalPath)
      let durable = try CoordinatedFiles.moveExclusive(root: root, from: tree.path, to: record.originalPath, coordinator: coordinator)
      var diagnostics = durability(durable)
      record.phase = .restored
      do {
        let updated = try JSONEncoder().encode(record)
        _ = try CoordinatedFiles.publish(root: root, path: record.recordPath, expectedRevision: SourceDigest.sha256(bytes), bytes: updated)
        try cleanup(record, bytes: updated, root: root)
      } catch { diagnostics.append("Source restored; trash metadata cleanup is pending.") }
      return WikiFileEffect(before: nil, after: record.originalPath, trashID: record.id, moves: moves, diagnostics: diagnostics)
    case .purge(let tree, var record, let bytes):
      try verifyRecord(record, bytes: bytes, root: root)
      if let tree {
        try WikiSourceAvailability.requireReady(tree, root: root)
        try tree.verify(root: root, coordinated: false)
      } else {
        guard record.phase == .purging, try !WikiSourceAvailability.itemPresent(root: root, path: record.payloadPath) else { throw WikiError.changedSource }
      }
      record.phase = .purging
      let updated = try JSONEncoder().encode(record)
      _ = try CoordinatedFiles.publish(root: root, path: record.recordPath, expectedRevision: SourceDigest.sha256(bytes), bytes: updated)
      var diagnostics: [String] = []
      do {
        if let tree { diagnostics += durability(try removeVerified(tree, root: root)) }
        try cleanup(record, bytes: updated, root: root)
      } catch { throw WikiFileOperationError.uncertain(operationID: id) }
      return WikiFileEffect(before: nil, after: nil, trashID: record.id, moves: [], diagnostics: diagnostics)
    }
  }

  private static func move(_ plan: WikiMovePlan, root: URL, id: UUID, coordinator: NSFileCoordinator) throws -> WikiFileEffect {
    try plan.inventory.verify(root: root, coordinated: false)
    try CoordinatedFiles.requireMoveDestination(root: root, from: plan.from, to: plan.to)
    var applied: [WikiMovePlan.Patch] = []; var diagnostics: [String] = []
    do {
      for patch in plan.patches {
        let durable = try CoordinatedFiles.publish(root: root, path: patch.path, expectedRevision: SourceDigest.sha256(patch.before), bytes: patch.after)
        applied.append(patch); diagnostics += durability(durable)
      }
      let replacements = Dictionary(uniqueKeysWithValues: plan.patches.map { ($0.path, $0.after) })
      try plan.inventory.replacing(replacements).verify(root: root, coordinated: false)
      diagnostics += durability(try CoordinatedFiles.moveExclusive(root: root, from: plan.from, to: plan.to, coordinator: coordinator))
      return WikiFileEffect(before: plan.from, after: plan.to, trashID: nil, moves: plan.documentMoves, diagnostics: diagnostics)
    } catch {
      let failure = error
      var restored = true
      for patch in applied.reversed() {
        do {
          let durable = try CoordinatedFiles.publish(root: root, path: patch.path, expectedRevision: SourceDigest.sha256(patch.after), bytes: patch.before)
          if !durable { restored = false }
        } catch { restored = false }
      }
      guard restored else { throw WikiFileOperationError.uncertain(operationID: id) }
      throw failure
    }
  }

  private static func verifyRecord(_ record: WikiTrashRecord, bytes: Data, root: URL) throws {
    guard try WikiSourceAvailability.itemPresent(root: root, path: record.recordPath) else { throw WikiError.changedSource }
    let current = try CoordinatedFiles.withParent(root: root, path: record.recordPath) {
      try CoordinatedFiles.read(parent: $0, name: $1, maximumBytes: 65536)
    }
    guard SourceDigest.sha256(current) == SourceDigest.sha256(bytes) else { throw WikiError.changedSource }
  }

  private static func cleanup(_ record: WikiTrashRecord, bytes: Data, root: URL) throws {
    try verifyRecord(record, bytes: bytes, root: root)
    guard try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(record.directory).path) == ["record.json"] else {
      throw WikiError.changedSource
    }
    try CoordinatedFiles.withParent(root: root, path: record.recordPath) { parent, name in
      guard unlinkat(parent, name, 0) == 0 else { throw CoordinatedFiles.managementPOSIX() }
      _ = fsync(parent)
    }
    try CoordinatedFiles.withParent(root: root, path: record.directory) { parent, name in
      guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw CoordinatedFiles.managementPOSIX() }
      _ = fsync(parent)
    }
  }

  private static func removeVerified(_ tree: WikiFileTree, root: URL) throws -> Bool {
    var durable = true
    for item in tree.items.sorted(by: { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) {
      let path = item.path.isEmpty ? tree.path : tree.path + "/" + item.path
      try CoordinatedFiles.withParent(root: root, path: path) { parent, name in
        if !item.isDirectory {
          guard SourceDigest.sha256(try CoordinatedFiles.read(parent: parent, name: name, maximumBytes: 50 * 1024 * 1024)) == item.revision else { throw WikiError.changedSource }
        }
        guard unlinkat(parent, name, item.isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw CoordinatedFiles.managementPOSIX() }
        if fsync(parent) != 0 { durable = false }
      }
    }
    return durable
  }

  private static func restoredDocuments(_ tree: WikiFileTree, originalPath: String) throws -> [WikiDocumentMove] {
    tree.bytes.compactMap { relative, bytes in
      let path = relative.isEmpty ? originalPath : originalPath + "/" + relative
      guard ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
        let document = try? WikiMarkdownParser.document(relativePath: path, bytes: bytes) else { return nil }
      return WikiDocumentMove(oldPath: path, newPath: path, oldID: document.id, newID: document.id)
    }.sorted { $0.newPath < $1.newPath }
  }
  private static func durability(_ confirmed: Bool) -> [String] { confirmed ? [] : ["Source effect observed; directory durability is unconfirmed."] }
}
