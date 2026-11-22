import Foundation

public struct AcornryPeerID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible
{
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.rawValue = UUID() }
  public var description: String { rawValue.uuidString.lowercased() }
}

public struct AcornryDiscoveryID: RawRepresentable, Hashable, Codable, Sendable,
  CustomStringConvertible
{
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.rawValue = UUID() }
  public var description: String { rawValue.uuidString.lowercased() }
}

public struct AcornryTransferID: RawRepresentable, Hashable, Codable, Sendable,
  CustomStringConvertible
{
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.rawValue = UUID() }
  public var description: String { rawValue.uuidString.lowercased() }
}

public struct AcornryIdentity: Equatable, Codable, Sendable {
  private enum CodingKeys: String, CodingKey { case id, displayName }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(AcornryPeerID.self, forKey: .id),
      displayName: values.decode(String.self, forKey: .displayName))
  }

  public let id: AcornryPeerID
  public let displayName: String

  public init(id: AcornryPeerID, displayName: String) throws {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard !name.isEmpty, name.utf8.count <= 128,
      !name.unicodeScalars.contains(where: {
        $0.value == 0 || CharacterSet.controlCharacters.contains($0)
      })
    else { throw AcornryError.invalidIdentity(displayName) }
    self.id = id
    self.displayName = name
  }
}

public enum AcornryTransportKind: String, Codable, Equatable, Hashable, Sendable {
  case bonjourPeerToPeer
  case wifiAware
}

public enum AcornryTransportStatus: String, Codable, Equatable, Sendable {
  case stopped
  case starting
  case ready
  /// The transport can use already discovered routes and accept connections, but new discovery observations are paused.
  case readyDiscoveryPaused
  case unavailable
  case failed
}

public struct AcornryTransportCapability: Codable, Equatable, Sendable {
  public let kind: AcornryTransportKind
  public let status: AcornryTransportStatus
  public let security: AcornrySecurityLevel
  public let detail: String?

  public init(
    kind: AcornryTransportKind,
    status: AcornryTransportStatus,
    security: AcornrySecurityLevel,
    detail: String? = nil
  ) {
    self.kind = kind
    self.status = status
    self.security = security
    self.detail = detail
  }
}

public enum AcornrySecurityLevel: String, Codable, Equatable, Sendable {
  /// User approval controls saving, but the Bonjour/AWDL byte stream itself is not encrypted by Acornry.
  case approvalOnly
  /// The Bonjour/AWDL stream is protected by a caller-provisioned TLS pre-shared key.
  case tlsPreSharedKey
  /// Wi-Fi Aware pairing plus Network.framework TLS protects the data path.
  case wifiAwareSystemSecure
}

public struct AcornryDiscovery: Identifiable, Codable, Equatable, Sendable {
  public let id: AcornryDiscoveryID
  public let displayName: String
  public let transport: AcornryTransportKind
  public let firstSeenAt: Date

  public init(
    id: AcornryDiscoveryID,
    displayName: String,
    transport: AcornryTransportKind,
    firstSeenAt: Date
  ) {
    self.id = id
    self.displayName = displayName
    self.transport = transport
    self.firstSeenAt = firstSeenAt
  }
}

public struct AcornryPeer: Identifiable, Codable, Equatable, Sendable {
  public let id: AcornryPeerID
  public let displayName: String
  public let transport: AcornryTransportKind
  public let discoveryID: AcornryDiscoveryID?
  public let lastSeenAt: Date

  public init(
    id: AcornryPeerID,
    displayName: String,
    transport: AcornryTransportKind,
    discoveryID: AcornryDiscoveryID?,
    lastSeenAt: Date
  ) {
    self.id = id
    self.displayName = displayName
    self.transport = transport
    self.discoveryID = discoveryID
    self.lastSeenAt = lastSeenAt
  }
}

public enum AcornryLifecycle: String, Codable, Equatable, Sendable {
  case stopped
  case starting
  case running
  case stopping
}

public enum AcornryTransferDirection: String, Codable, Equatable, Sendable {
  case incoming
  case outgoing
}

public enum AcornryTransferPhase: String, Codable, Equatable, Sendable {
  case preparing
  case awaitingApproval
  case transferring
  case committing
  case completed
  case partial
  case rejected
  case cancelled
  case failed
  case outcomeUnknown
}

public struct AcornryTransferProgress: Identifiable, Codable, Equatable, Sendable {
  public var id: AcornryTransferID { transferID }
  public let transferID: AcornryTransferID
  public let direction: AcornryTransferDirection
  public let peerID: AcornryPeerID?
  public let phase: AcornryTransferPhase
  public let completedBytes: Int64
  public let totalBytes: Int64
  public let completedFiles: Int
  public let totalFiles: Int

  public init(
    transferID: AcornryTransferID,
    direction: AcornryTransferDirection,
    peerID: AcornryPeerID?,
    phase: AcornryTransferPhase,
    completedBytes: Int64,
    totalBytes: Int64,
    completedFiles: Int,
    totalFiles: Int
  ) {
    self.transferID = transferID
    self.direction = direction
    self.peerID = peerID
    self.phase = phase
    self.completedBytes = completedBytes
    self.totalBytes = totalBytes
    self.completedFiles = completedFiles
    self.totalFiles = totalFiles
  }
}
