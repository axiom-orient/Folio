import Foundation

/// Canonical progress values and their synchronous transitions; Nearby owns event delivery.
struct AcornryProgressLedger: Sendable {
  private var values: [AcornryTransferID: AcornryTransferProgress] = [:]

  var snapshot: [AcornryTransferProgress] {
    values.values.sorted { $0.transferID.description < $1.transferID.description }
  }

  mutating func removeAll() { values.removeAll() }

  mutating func update(_ value: AcornryTransferProgress) -> AcornryTransferProgress {
    values[value.transferID] = value
    return value
  }

  mutating func setPhase(_ id: AcornryTransferID, _ phase: AcornryTransferPhase) -> AcornryTransferProgress? {
    guard let old = values[id] else { return nil }
    return update(
      .init(
        transferID: old.transferID,
        direction: old.direction,
        peerID: old.peerID,
        phase: phase,
        completedBytes: old.completedBytes,
        totalBytes: old.totalBytes,
        completedFiles: old.completedFiles,
        totalFiles: old.totalFiles))
  }

  mutating func setPeer(_ id: AcornryTransferID, _ peerID: AcornryPeerID) -> AcornryTransferProgress? {
    guard let old = values[id] else { return nil }
    return update(
      .init(
        transferID: old.transferID,
        direction: old.direction,
        peerID: peerID,
        phase: old.phase,
        completedBytes: old.completedBytes,
        totalBytes: old.totalBytes,
        completedFiles: old.completedFiles,
        totalFiles: old.totalFiles))
  }

  mutating func completeOutgoing(_ receipt: AcornryTransferReceipt) -> AcornryTransferProgress? {
    guard let old = values[receipt.transferID] else { return nil }
    return update(
      .init(
        transferID: old.transferID,
        direction: .outgoing,
        peerID: old.peerID,
        phase: receipt.state == .completed ? .completed : .partial,
        completedBytes: old.totalBytes,
        totalBytes: old.totalBytes,
        completedFiles: old.totalFiles,
        totalFiles: old.totalFiles))
  }

  mutating func completeIncoming(
    _ receipt: AcornryTransferReceipt,
    peerID: AcornryPeerID,
    totalBytes: Int64
  ) -> AcornryTransferProgress {
    return update(
      .init(
        transferID: receipt.transferID,
        direction: .incoming,
        peerID: peerID,
        phase: receipt.state == .completed ? .completed : .partial,
        completedBytes: totalBytes,
        totalBytes: totalBytes,
        completedFiles: receipt.files.count,
        totalFiles: receipt.files.count))
  }
}
