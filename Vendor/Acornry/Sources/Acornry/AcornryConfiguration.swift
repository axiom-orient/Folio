import Foundation

public enum AcornryIncomingPolicy: String, Codable, Equatable, Sendable {
  case requireApproval
  case automatic
}

public enum AcornryWiFiAwareMode: String, Codable, Equatable, Sendable {
  case disabled
  case opportunistic
  case required
}

/// A trusted host-provided secret. It is intentionally absent from snapshots and event payloads.
public struct AcornrySharedSecret: Equatable, Sendable {
  package let data: Data

  public init(data: Data) throws {
    guard data.count >= 32 else {
      throw AcornryError.invalidConfiguration("TLS pre-shared key must contain at least 32 bytes")
    }
    self.data = data
  }
}

public enum AcornryBonjourSecurity: Equatable, Sendable {
  case approvalOnly
  case preSharedKey(AcornrySharedSecret)

  public var level: AcornrySecurityLevel {
    switch self {
    case .approvalOnly: .approvalOnly
    case .preSharedKey: .tlsPreSharedKey
    }
  }
}

public struct AcornryResourceLimits: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case maxFileCount, maxTotalBytes, maxSingleFileBytes, maxFrameBytes, chunkBytes
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maxFileCount: values.decode(Int.self, forKey: .maxFileCount),
      maxTotalBytes: values.decode(Int64.self, forKey: .maxTotalBytes),
      maxSingleFileBytes: values.decode(Int64.self, forKey: .maxSingleFileBytes),
      maxFrameBytes: values.decode(Int.self, forKey: .maxFrameBytes),
      chunkBytes: values.decode(Int.self, forKey: .chunkBytes))
  }

  public let maxFileCount: Int
  public let maxTotalBytes: Int64
  public let maxSingleFileBytes: Int64
  public let maxFrameBytes: Int
  public let chunkBytes: Int

  public init(
    maxFileCount: Int = AcornryResourceLimits.default.maxFileCount,
    maxTotalBytes: Int64 = AcornryResourceLimits.default.maxTotalBytes,
    maxSingleFileBytes: Int64 = AcornryResourceLimits.default.maxSingleFileBytes,
    maxFrameBytes: Int = AcornryResourceLimits.default.maxFrameBytes,
    chunkBytes: Int = AcornryResourceLimits.default.chunkBytes
  ) throws {
    guard maxFileCount > 0 else {
      throw AcornryError.invalidConfiguration("maxFileCount must be positive")
    }
    guard maxTotalBytes >= 0 else {
      throw AcornryError.invalidConfiguration("maxTotalBytes must be nonnegative")
    }
    guard maxSingleFileBytes >= 0, maxSingleFileBytes <= maxTotalBytes else {
      throw AcornryError.invalidConfiguration("maxSingleFileBytes must be within maxTotalBytes")
    }
    guard maxFrameBytes >= 4_096, maxFrameBytes <= 16 * 1_024 * 1_024 else {
      throw AcornryError.invalidConfiguration("maxFrameBytes must be between 4 KiB and 16 MiB")
    }
    guard chunkBytes > 0, chunkBytes <= maxFrameBytes - AcornryWire.chunkPrefixByteCount else {
      throw AcornryError.invalidConfiguration("chunkBytes must fit in maxFrameBytes")
    }
    self.maxFileCount = maxFileCount
    self.maxTotalBytes = maxTotalBytes
    self.maxSingleFileBytes = maxSingleFileBytes
    self.maxFrameBytes = maxFrameBytes
    self.chunkBytes = chunkBytes
  }

  private init(
    validatedMaxFileCount: Int,
    maxTotalBytes: Int64,
    maxSingleFileBytes: Int64,
    maxFrameBytes: Int,
    chunkBytes: Int
  ) {
    self.maxFileCount = validatedMaxFileCount
    self.maxTotalBytes = maxTotalBytes
    self.maxSingleFileBytes = maxSingleFileBytes
    self.maxFrameBytes = maxFrameBytes
    self.chunkBytes = chunkBytes
  }

  public static let `default` = AcornryResourceLimits(
    validatedMaxFileCount: 1_000,
    maxTotalBytes: 512 * 1_024 * 1_024,
    maxSingleFileBytes: 64 * 1_024 * 1_024,
    maxFrameBytes: 1 * 1_024 * 1_024,
    chunkBytes: 256 * 1_024)
}

public struct AcornryConfiguration: Sendable {
  public let identity: AcornryIdentity
  public let stagingRootURL: URL
  public let destinationRootURL: URL
  public let incomingPolicy: AcornryIncomingPolicy
  public let limits: AcornryResourceLimits
  public let bonjourSecurity: AcornryBonjourSecurity
  public let wifiAwareMode: AcornryWiFiAwareMode
  public let approvalTimeout: Duration
  /// Maximum wait for transport startup or one protocol frame. Human approval has its own budget.
  public let protocolIdleTimeout: Duration
  /// Includes connections that have not sent a hello or offer yet.
  public let maxIncomingConnections: Int
  public let serviceType: String
  package let approvalExchangeTimeout: Duration

  public init(
    identity: AcornryIdentity,
    stagingRootURL: URL,
    destinationRootURL: URL,
    incomingPolicy: AcornryIncomingPolicy = .requireApproval,
    limits: AcornryResourceLimits = .default,
    bonjourSecurity: AcornryBonjourSecurity = .approvalOnly,
    wifiAwareMode: AcornryWiFiAwareMode = .opportunistic,
    approvalTimeout: Duration = .seconds(120),
    serviceType: String = "_acornry._tcp",
    protocolIdleTimeout: Duration = .seconds(30),
    maxIncomingConnections: Int = 8
  ) throws {
    guard stagingRootURL.isFileURL, destinationRootURL.isFileURL else {
      throw AcornryError.invalidConfiguration("staging and destination roots must be file URLs")
    }
    let staging = stagingRootURL.standardizedFileURL
    let destination = destinationRootURL.standardizedFileURL
    guard staging.path != "/", destination.path != "/", staging != destination else {
      throw AcornryError.invalidConfiguration("dedicated, distinct roots are required")
    }
    guard Self.isValidServiceType(serviceType) else {
      throw AcornryError.invalidConfiguration(
        "invalid Bonjour/Wi-Fi Aware service type: \(serviceType)")
    }
    guard approvalTimeout > .zero else {
      throw AcornryError.invalidConfiguration("approvalTimeout must be positive")
    }
    guard protocolIdleTimeout > .zero, maxIncomingConnections > 0 else {
      throw AcornryError.invalidConfiguration(
        "protocol timeout and incoming budget must be positive")
    }
    let (seconds, overflow) = approvalTimeout.components.seconds.addingReportingOverflow(
      protocolIdleTimeout.components.seconds)
    guard !overflow, seconds < Int64.max else {
      throw AcornryError.invalidConfiguration(
        "combined approval/protocol timeout is not representable")
    }
    self.approvalExchangeTimeout = approvalTimeout + protocolIdleTimeout
    self.protocolIdleTimeout = protocolIdleTimeout
    self.maxIncomingConnections = maxIncomingConnections
    self.identity = identity
    self.stagingRootURL = staging
    self.destinationRootURL = destination
    self.incomingPolicy = incomingPolicy
    self.limits = limits
    self.bonjourSecurity = bonjourSecurity
    self.wifiAwareMode = wifiAwareMode
    self.approvalTimeout = approvalTimeout
    self.serviceType = serviceType
  }

  private static func isValidServiceType(_ value: String) -> Bool {
    guard value.hasPrefix("_"), value.hasSuffix("._tcp") else { return false }
    let start = value.index(after: value.startIndex)
    guard let dot = value[start...].firstIndex(of: ".") else { return false }
    let name = String(value[start..<dot])
    guard (1...15).contains(name.count), name.first != "-", name.last != "-" else { return false }
    let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    let allowed = letters.union(CharacterSet(charactersIn: "0123456789-"))
    return name.unicodeScalars.contains(where: letters.contains)
      && name.unicodeScalars.allSatisfy(allowed.contains)
  }
}

// Derived facade values and root admission share the same configuration authority.
extension AcornryConfiguration {
  var nearbyDescriptor: AcornryNearbyDescriptor {
    AcornryNearbyDescriptor(
      localIdentity: identity,
      serviceType: serviceType,
      protocolVersion: AcornryWire.protocolVersion,
      limits: limits,
      incomingPolicy: incomingPolicy,
      wifiAwareMode: wifiAwareMode,
      bonjourSecurity: bonjourSecurity.level)
  }

  func validateRootSeparation() throws {
    let staging = stagingRootURL.resolvingSymlinksInPath().standardizedFileURL.path
    let destination = destinationRootURL.resolvingSymlinksInPath().standardizedFileURL
      .path
    let s = staging.hasSuffix("/") ? staging : staging + "/"
    let d = destination.hasSuffix("/") ? destination : destination + "/"
    guard !s.hasPrefix(d), !d.hasPrefix(s) else {
      throw AcornryError.invalidConfiguration(
        "staging and destination roots must not contain each other")
    }
  }

  var approvalExpirationInterval: TimeInterval {
    let parts = approvalTimeout.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
  }
}
