import Foundation
import FolioKnowledge

extension WikiWorkspace {
  /// The actor prepares and executes one synchronous coordinated source segment.
  /// A receipt distinguishes its committed source effect from derived refresh.
  public func performFileOperation(_ operation: WikiFileOperation, expectedRevision: String? = nil,
    operationID: UUID = UUID()) async throws -> WikiFileChange {
    try requireOpen()
    try requireUnconflictedFileManagementIdentity()
    let journal = try WikiFileJournal(directory: receiptDirectory, id: operationID, operation: operation, expectedRevision: expectedRevision)
    if let completed = try journal.existing() { return completed }
    if case .createDocument(let raw, let text) = operation {
      let path = try WikiFilePaths.notes(raw)
      try CoordinatedFiles.requireAbsent(root: root, path: path)
      let bytes = try WikiMarkdownEditor.addingStableID(bytes: Data(text.utf8), id: operationID.uuidString.lowercased())
      guard bytes.count <= 256 * 1024 else { throw WikiError.invalidSource("New Markdown must fit 256 KiB including its ID.") }
      let plan = try await prepareEdit(relativePath: path, expectedRevision: nil, range: nil,
        replacement: String(decoding: bytes, as: UTF8.self), operationID: operationID)
      try journal.validateChangeSize(WikiFileChange(operationID: operationID, beforePath: nil, afterPath: path,
        trashID: nil, documentMoves: [], projectionUpdated: false, diagnostic: nil))
      try requireOpen(); try Task.checkCancellation()
      let ownership = try journal.begin(workspaceID: workspaceID, backups: [])
      try requireUnconflictedFileManagementIdentity()
      let receipt = try await execute(plan)
      let change = WikiFileChange(operationID: operationID, beforePath: nil, afterPath: path, trashID: nil,
        documentMoves: [], projectionUpdated: receipt.projectionUpdated, diagnostic: receipt.diagnostic)
      do { try journal.save(change) }
      catch { return updated(change, projection: receipt.projectionUpdated, diagnostic: "Document committed; file-management receipt durability is unconfirmed.") }
      do { try journal.cleanupAfterCommit(ownership) }
      catch { return updated(change, projection: receipt.projectionUpdated, diagnostic: "Document committed; private operation-intent cleanup is pending.") }
      return change
    }
    let prepared = try prepareFileManagement(operation, expectedRevision: expectedRevision, id: operationID)
    try journal.validateChangeSize(WikiFileEffects.preview(prepared, id: operationID))
    let backups: [WikiMovePlan.Patch]
    if case .move(let plan) = prepared { backups = plan.patches } else { backups = [] }
    try Task.checkCancellation()
    let ownership = try journal.begin(workspaceID: workspaceID, backups: backups)
    var observed: WikiFileEffect?
    do {
      try CoordinatedFiles.workspaceMutation(root: root) { coordinator in
        try requireUnconflictedFileManagementIdentity()
        let identity = try CoordinatedFiles.withParent(root: root, path: "_workspace.md") {
          try CoordinatedFiles.read(parent: $0, name: $1, maximumBytes: 65536)
        }
        guard try WikiMarkdownParser.workspace(bytes: identity).id == workspaceID else { throw WikiError.changedSource }
        observed = try WikiFileEffects.apply(prepared, root: root, id: operationID, coordinator: coordinator)
      }
    } catch {
      guard observed != nil else { throw error }
      observed?.diagnostics.append("Source effect observed; file-coordination completion is unconfirmed.")
    }
    guard var effect = observed else { throw WikiFileOperationError.uncertain(operationID: operationID) }
    effect.diagnostics = Array(Set(effect.diagnostics)).sorted()
    var change = WikiFileChange(operationID: operationID, beforePath: effect.before, afterPath: effect.after,
      trashID: effect.trashID, documentMoves: effect.moves, projectionUpdated: false,
      diagnostic: (effect.diagnostics + ["Source committed; projection refresh is pending."]).joined(separator: " "))
    var recorded = false
    do { try journal.save(change); recorded = true }
    catch { change = updated(change, projection: false, diagnostic: "Source committed; operation receipt durability and projection refresh are unconfirmed.") }
    var cleanupPending = false
    if recorded, effect.diagnostics.isEmpty {
      do { try journal.cleanupAfterCommit(ownership) }
      catch {
        cleanupPending = true
        change = updated(change, projection: false, diagnostic: "Source committed; private operation recovery cleanup and projection refresh are pending.")
      }
    }
    do {
      _ = try await refresh()
      let diagnostics = effect.diagnostics + (cleanupPending ? ["Source committed; private operation recovery cleanup is pending."] : [])
      change = updated(change, projection: true, diagnostic: diagnostics.isEmpty ? nil : diagnostics.joined(separator: " "))
      if !recorded { change = updated(change, projection: true, diagnostic: "Source committed and projection refreshed; operation receipt durability is unconfirmed.") }
      else {
        do { try journal.save(change) }
        catch { change = updated(change, projection: true, diagnostic: "Source committed and projection refreshed; final receipt update is pending.") }
      }
    } catch {}
    return change
  }

  private func updated(_ change: WikiFileChange, projection: Bool, diagnostic: String?) -> WikiFileChange {
    WikiFileChange(operationID: change.operationID, beforePath: change.beforePath, afterPath: change.afterPath,
      trashID: change.trashID, documentMoves: change.documentMoves, projectionUpdated: projection, diagnostic: diagnostic)
  }

  private func requireUnconflictedFileManagementIdentity() throws {
    guard NSFileVersion.unresolvedConflictVersionsOfItem(at: root.appendingPathComponent("_workspace.md"))?.isEmpty != false else {
      throw WikiError.conflict("_workspace.md")
    }
  }
}
