import Foundation

/// Observation only. Externally constructed values never authorize dispatch or recovery.
public struct AcornryUnknownOperation: Identifiable, Codable, Equatable, Sendable {
  public var id: AcornryTransferID { transferID }
  public let transferID: AcornryTransferID
  public let manifestDigestSHA256: String
  public let recordedAt: Date
  /// Present on journal-derived observations; nil is permitted only for caller-created projections.
  public let targetPeerID: AcornryPeerID?

  public init(
    transferID: AcornryTransferID, manifestDigestSHA256: String, recordedAt: Date,
    targetPeerID: AcornryPeerID? = nil
  ) {
    self.transferID = transferID
    self.manifestDigestSHA256 = manifestDigestSHA256
    self.recordedAt = recordedAt
    self.targetPeerID = targetPeerID
  }
}

/// Durable authority is intentionally separate from the source-compatible public projection.
package struct AcornryOutgoingRecord: Codable, Equatable, Sendable {
  package enum Phase: String, Codable, Sendable { case bound, awaitingReceipt, settled }
  package let schema: Int
  package let manifest: AcornryTransferManifest
  package let targetPeerID: AcornryPeerID
  package var phase: Phase
  package let recordedAt: Date

  package var transferID: AcornryTransferID { manifest.transferID }

  package init(manifest: AcornryTransferManifest, targetPeerID: AcornryPeerID) {
    self.schema = 1
    self.manifest = manifest
    self.targetPeerID = targetPeerID
    self.phase = .bound
    self.recordedAt = Date()
  }

  private enum CodingKeys: String, CodingKey {
    case schema, manifest, targetPeerID, phase, recordedAt
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schema = try values.decode(Int.self, forKey: .schema)
    guard schema == 1 else {
      throw AcornryError.invalidState(
        "unsupported outgoing record schema; original record retained")
    }
    manifest = try values.decode(AcornryTransferManifest.self, forKey: .manifest)
    targetPeerID = try values.decode(AcornryPeerID.self, forKey: .targetPeerID)
    phase = try values.decode(Phase.self, forKey: .phase)
    recordedAt = try values.decode(Date.self, forKey: .recordedAt)
    guard targetPeerID != manifest.sender.id else {
      throw AcornryError.invalidState("outgoing target cannot be the sender")
    }
  }

  package func observation() throws -> AcornryUnknownOperation {
    .init(
      transferID: transferID, manifestDigestSHA256: try manifest.digestSHA256(),
      recordedAt: recordedAt, targetPeerID: targetPeerID)
  }
}

package actor AcornryOperationJournal {
  private let rootURL: URL

  package init(stagingRootURL: URL) throws {
    self.rootURL = stagingRootURL.appendingPathComponent(".operations", isDirectory: true)
    try AcornryPath.ensureDirectory(rootURL)
  }

  /// Bind once, before publishing the offer. A settled record is retained to prevent ID reuse.
  package func bind(_ manifest: AcornryTransferManifest, to peerID: AcornryPeerID) throws {
    if let existing = try record(manifest.transferID) {
      guard existing.manifest == manifest, existing.targetPeerID == peerID else {
        throw AcornryError.transferConflict(manifest.transferID)
      }
      guard existing.phase != .awaitingReceipt else {
        throw AcornryError.outcomeUnknown(manifest.transferID)
      }
      return
    }
    try write(AcornryOutgoingRecord(manifest: manifest, targetPeerID: peerID))
  }

  package func markAwaitingReceipt(_ id: AcornryTransferID) throws {
    guard var record = try record(id) else {
      throw AcornryError.invalidState("outgoing operation must be bound before dispatch")
    }
    record.phase = .awaitingReceipt
    try write(record)
  }

  /// Only full, manifest-validated terminal evidence may resolve uncertainty.
  package func settle(_ receipt: AcornryTransferReceipt) throws {
    guard var record = try record(receipt.transferID) else {
      throw AcornryError.invalidState("missing outgoing binding")
    }
    try receipt.validate(for: record.manifest)
    record.phase = .settled
    try write(record)
  }

  package func record(_ id: AcornryTransferID) throws -> AcornryOutgoingRecord? {
    try AcornryPath.requireDirectory(rootURL)
    let url = fileURL(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try read(url, expectedID: id)
  }

  package func all() throws -> [AcornryUnknownOperation] {
    try AcornryPath.requireDirectory(rootURL)
    let files = try FileManager.default.contentsOfDirectory(
      at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }
    var unknown: [AcornryUnknownOperation] = []
    for url in files {
      // Decode first so corruption remains a visible decoding error, never an empty snapshot.
      let record = try read(url, expectedID: nil)
      guard url.lastPathComponent == record.transferID.description + ".json" else {
        throw AcornryError.integrityMismatch("outgoing record filename does not match identity")
      }
      if record.phase == .awaitingReceipt { unknown.append(try record.observation()) }
    }
    return unknown.sorted { $0.recordedAt < $1.recordedAt }
  }

  private func read(_ url: URL, expectedID: AcornryTransferID?) throws -> AcornryOutgoingRecord {
    try AcornryPath.requireRegularFile(url)
    let record = try JSONDecoder().decode(AcornryOutgoingRecord.self, from: Data(contentsOf: url))
    if let expectedID, record.transferID != expectedID {
      throw AcornryError.transferConflict(expectedID)
    }
    return record
  }

  private func write(_ record: AcornryOutgoingRecord) throws {
    try AcornryPath.requireDirectory(rootURL)
    let url = fileURL(record.transferID)
    if FileManager.default.fileExists(atPath: url.path) {
      try AcornryPath.requireRegularFile(url)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try AcornryPersistence.write(encoder.encode(record), to: url)
  }

  private func fileURL(_ id: AcornryTransferID) -> URL {
    rootURL.appendingPathComponent(id.description + ".json")
  }
}
