import Foundation
import FolioKnowledge
import FolioKnowledgeApple

/// Owns the temporary edit's lifetime; WikiWorkspace remains the only source writer.
struct CorpusEditCheck {
  struct Outcome: Sendable {
    let original: Data
    let prepareHadNoEffect: Bool
    let editCommittedAndRestored: Bool
    let restoreReceipt: WikiWriteReceipt
  }

  private struct RecoveryRecord: Encodable, Sendable {
    let schema = 1
    let workspaceID: UUID
    let workspaceRoot: URL
    let relativePath: String
    let originalBytes: Data
    let originalRevision: String
    let editedRevision: String
    let editOperationID: UUID
    let restoreOperationID: UUID
    let recoveryOperationID: UUID
  }

  private struct Failure: LocalizedError, CustomStringConvertible {
    let cause: String
    let recovery: String
    let recordURL: URL
    var description: String {
      "Corpus edit check failed: \(cause)\n\(recovery)\nRecovery record retained: \(recordURL.path)"
    }
    var errorDescription: String? { description }
  }

  static func run(workspace: WikiWorkspace, document: WikiDocument, stateDirectory: URL) async throws -> Outcome {
    let original = try await workspace.source(relativePath: document.relativePath)
    guard let text = String(data: original, encoding: .utf8), Data(text.utf8) == original else {
      throw WikiError.invalidSource("Corpus edit check requires exact UTF-8 round-trip restoration.")
    }
    let plan = try await workspace.prepareRawSave(relativePath: document.relativePath,
      expectedRevision: document.revision,
      replacement: text + "\n<!-- Folio corpus usage check 2026-10-10 -->\n", operationID: UUID())
    let prepareHadNoEffect = try await workspace.source(relativePath: document.relativePath) == original
    guard prepareHadNoEffect, plan.expectedRevision == SourceDigest.sha256(original) else {
      throw WikiError.invalidSource("Prepare changed source bytes or its revision no longer matches.")
    }
    let record = RecoveryRecord(workspaceID: plan.workspaceID, workspaceRoot: workspace.root,
      relativePath: plan.relativePath, originalBytes: original, originalRevision: SourceDigest.sha256(original),
      editedRevision: plan.resultRevision, editOperationID: plan.operationID,
      restoreOperationID: UUID(), recoveryOperationID: UUID())
    // Preserve exact bytes and operation identities before any source publication.
    let recordURL = try persist(record, stateDirectory: stateDirectory)
    let outcome: Outcome
    do {
      let saved = try await workspace.execute(plan)
      let edited = try await workspace.source(relativePath: plan.relativePath) == plan.replacementBytes
      let restored = try await workspace.prepareRawSave(relativePath: plan.relativePath,
        expectedRevision: saved.sourceRevision, replacement: text, operationID: record.restoreOperationID)
      let receipt = try await workspace.execute(restored)
      let restoredExactly = try await workspace.source(relativePath: plan.relativePath) == original
      outcome = Outcome(original: original, prepareHadNoEffect: prepareHadNoEffect,
        editCommittedAndRestored: restoredExactly && edited && receipt.projectionUpdated,
        restoreReceipt: receipt)
      guard restoredExactly else { throw WikiError.changedSource }
    } catch {
      let cause = String(describing: error)
      // This owned, awaited task is intentionally independent of caller cancellation:
      // cancellation after publication must not prevent the compensating CAS.
      let recovery = Task { try await restoreAfterFailure(workspace: workspace, plan: plan, record: record) }
      let detail: String
      do { detail = try await recovery.value }
      catch { detail = "Recovery failed or remains unconfirmed; no recovery retry was issued: \(error)" }
      // Keep the original failure and recovery evidence even if current bytes are restored.
      throw Failure(cause: cause, recovery: detail, recordURL: recordURL)
    }
    // A cleanup failure cannot cause the already restored edit to execute again.
    do { try FileManager.default.removeItem(at: recordURL) }
    catch {
      throw Failure(cause: "Recovery-record cleanup failed: \(error)",
        recovery: "Original source bytes were restored.", recordURL: recordURL)
    }
    return outcome
  }

  private static func restoreAfterFailure(workspace: WikiWorkspace, plan: WikiPreparedEdit,
    record: RecoveryRecord
  ) async throws -> String {
    let current = try await workspace.source(relativePath: record.relativePath)
    if current == record.originalBytes { return "Original source bytes are present; no recovery write was needed." }
    guard current == plan.replacementBytes else { throw WikiError.changedSource }
    let status = try await workspace.operationStatus(record.editOperationID)
    switch status.state {
    case .notObserved: throw WikiError.unavailable("No recorded dispatch was observed; changed source was preserved.")
    case .uncertain: break // Inspect bytes; never replay the original edit or settle its uncertain record.
    case .committed:
      guard let receipt = status.receipt, receipt.relativePath == record.relativePath,
        receipt.previousRevision == record.originalRevision, receipt.sourceRevision == record.editedRevision else {
        throw WikiError.changedSource
      }
    }
    let restoration = try await workspace.prepareRawSave(relativePath: record.relativePath,
      expectedRevision: record.editedRevision,
      replacement: String(decoding: record.originalBytes, as: UTF8.self), operationID: record.recoveryOperationID)
    let receipt: WikiWriteReceipt
    do { receipt = try await workspace.execute(restoration) }
    catch {
      // A write can publish before its receipt/durability reporting fails. Observe once;
      // retain the uncertainty and evidence rather than issuing another operation.
      if let observed = try? await workspace.source(relativePath: record.relativePath), observed == record.originalBytes {
        return "Original source bytes are present after recovery, but the write outcome remains unconfirmed: \(error)"
      }
      throw error
    }
    guard receipt.sourceRevision == record.originalRevision,
      try await workspace.source(relativePath: record.relativePath) == record.originalBytes else {
      throw WikiError.changedSource
    }
    return receipt.projectionUpdated
      ? "Original source bytes restored with CAS."
      : "Original source bytes restored with CAS; projection refresh remains pending."
  }

  private static func persist(_ record: RecoveryRecord, stateDirectory: URL) throws -> URL {
    let directory = stateDirectory.standardizedFileURL.resolvingSymlinksInPath()
      .appendingPathComponent("CorpusReviewRecovery", isDirectory: true)
    let source = record.workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
    let resolved = directory.resolvingSymlinksInPath()
    guard resolved != source, !resolved.path.hasPrefix(source.path + "/") else {
      throw WikiError.invalidPath("Corpus recovery records must remain outside the source workspace.")
    }
    try WikiLocalStorage.createDirectory(directory)
    let url = directory.appendingPathComponent(record.editOperationID.uuidString + ".json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(record).write(to: url, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
    return url
  }
}
