import Foundation

/// Observation of retained staging, never authority to commit or discard it.
/// An explicit retry re-reads the metadata and verifies every payload file.
public struct AcornryPendingImport: Identifiable, Equatable, Sendable {
  /// Actual destination occupancy, not proof that the bytes match the manifest
  /// or that destination publication completed.
  public struct DestinationUsage: Equatable, Sendable {
    public let isArchived: Bool
    public let byteCount: Int64
    public let hasFiles: Bool

    public init(isArchived: Bool, byteCount: Int64, hasFiles: Bool) {
      self.isArchived = isArchived
      self.byteCount = byteCount
      self.hasFiles = hasFiles
    }
  }

  public enum State: Equatable, Sendable {
    case ready(AcornryTransferManifest)
    case needsReview(String)
  }

  public let transferID: AcornryTransferID
  public let state: State
  public let destinationUsage: DestinationUsage?
  public var id: AcornryTransferID { transferID }

  public init(transferID: AcornryTransferID, state: State,
    destinationUsage: DestinationUsage? = nil
  ) {
    self.transferID = transferID
    self.state = state
    self.destinationUsage = destinationUsage
  }
}
