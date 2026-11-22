import Foundation

public struct AcornryIncomingOffer: Identifiable, Codable, Equatable, Sendable {
  public var id: AcornryTransferID { manifest.transferID }
  public let manifest: AcornryTransferManifest
  public let transport: AcornryTransportKind
  public let receivedAt: Date
  public let expiresAt: Date

  public init(
    manifest: AcornryTransferManifest,
    transport: AcornryTransportKind,
    receivedAt: Date,
    expiresAt: Date
  ) {
    self.manifest = manifest
    self.transport = transport
    self.receivedAt = receivedAt
    self.expiresAt = expiresAt
  }
}

public struct AcornryNearbyDescriptor: Codable, Equatable, Sendable {
  public let localIdentity: AcornryIdentity
  public let serviceType: String
  public let protocolVersion: UInt16
  public let limits: AcornryResourceLimits
  public let incomingPolicy: AcornryIncomingPolicy
  public let wifiAwareMode: AcornryWiFiAwareMode
  public let bonjourSecurity: AcornrySecurityLevel

  public init(
    localIdentity: AcornryIdentity,
    serviceType: String,
    protocolVersion: UInt16,
    limits: AcornryResourceLimits,
    incomingPolicy: AcornryIncomingPolicy,
    wifiAwareMode: AcornryWiFiAwareMode,
    bonjourSecurity: AcornrySecurityLevel
  ) {
    self.localIdentity = localIdentity
    self.serviceType = serviceType
    self.protocolVersion = protocolVersion
    self.limits = limits
    self.incomingPolicy = incomingPolicy
    self.wifiAwareMode = wifiAwareMode
    self.bonjourSecurity = bonjourSecurity
  }
}

public struct AcornrySnapshot: Codable, Equatable, Sendable {
  public let descriptor: AcornryNearbyDescriptor
  public let lifecycle: AcornryLifecycle
  public let transports: [AcornryTransportCapability]
  public let discoveries: [AcornryDiscovery]
  public let peers: [AcornryPeer]
  public let incomingOffers: [AcornryIncomingOffer]
  public let transfers: [AcornryTransferProgress]
  public let unknownOutgoingOperations: [AcornryUnknownOperation]

  public init(
    descriptor: AcornryNearbyDescriptor,
    lifecycle: AcornryLifecycle,
    transports: [AcornryTransportCapability],
    discoveries: [AcornryDiscovery],
    peers: [AcornryPeer],
    incomingOffers: [AcornryIncomingOffer],
    transfers: [AcornryTransferProgress],
    unknownOutgoingOperations: [AcornryUnknownOperation]
  ) {
    self.descriptor = descriptor
    self.lifecycle = lifecycle
    self.transports = transports
    self.discoveries = discoveries
    self.peers = peers
    self.incomingOffers = incomingOffers
    self.transfers = transfers
    self.unknownOutgoingOperations = unknownOutgoingOperations
  }
}

public enum AcornryEvent: Sendable, Equatable {
  case lifecycle(AcornryLifecycle)
  case transport(AcornryTransportCapability)
  case discoveryAdded(AcornryDiscovery)
  case discoveryRemoved(AcornryDiscoveryID)
  case peerIdentified(AcornryPeer)
  case incomingOffer(AcornryIncomingOffer)
  case incomingOfferRemoved(AcornryTransferID)
  case transferProgress(AcornryTransferProgress)
  case transferCompleted(AcornryTransferReceipt)
  case transferFailed(AcornryTransferID?, String)
  /// Destination evidence is retained; only delivery of that evidence failed.
  case receiptDeliveryFailed(AcornryTransferID, String)
}
