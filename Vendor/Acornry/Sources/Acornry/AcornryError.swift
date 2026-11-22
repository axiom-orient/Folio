import Foundation

public enum AcornryError: Error, Equatable, Sendable {
  case invalidConfiguration(String)
  case invalidIdentity(String)
  case invalidPath(String)
  case invalidManifest(String)
  case invalidState(String)
  case resourceLimitExceeded(String)
  case protocolViolation(String)
  case unsupportedProtocol(UInt16)
  case integrityMismatch(String)
  case sourceChanged(String)
  case destinationConflict(String)
  case discoveryNotFound(AcornryDiscoveryID)
  case peerNotFound(AcornryPeerID)
  case approvalNotPending(AcornryTransferID)
  case transferRejected(AcornryTransferID, String?)
  case transferConflict(AcornryTransferID)
  case transportUnavailable(AcornryTransportKind, String)
  case protocolTimedOut
  case connectionClosed
  case operationCancelled
  case outcomeUnknown(AcornryTransferID)
}

extension AcornryError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let value): "Invalid configuration: \(value)"
    case .invalidIdentity(let value): "Invalid identity: \(value)"
    case .invalidPath(let value): "Invalid relative path: \(value)"
    case .invalidManifest(let value): "Invalid transfer manifest: \(value)"
    case .invalidState(let value): "Invalid state: \(value)"
    case .resourceLimitExceeded(let value): "Resource limit exceeded: \(value)"
    case .protocolViolation(let value): "Protocol violation: \(value)"
    case .unsupportedProtocol(let version): "Unsupported Acornry protocol version: \(version)"
    case .integrityMismatch(let value): "Integrity mismatch: \(value)"
    case .sourceChanged(let value): "Source changed during transfer: \(value)"
    case .destinationConflict(let value): "Destination conflict: \(value)"
    case .discoveryNotFound(let id): "Discovery is no longer available: \(id.rawValue.uuidString)"
    case .peerNotFound(let id): "Peer is not available: \(id.rawValue.uuidString)"
    case .approvalNotPending(let id): "No incoming approval is pending: \(id.rawValue.uuidString)"
    case .transferRejected(let id, let reason):
      "Transfer \(id.rawValue.uuidString) was rejected\(reason.map { ": \($0)" } ?? "")"
    case .transferConflict(let id):
      "Transfer identity conflicts with different content: \(id.rawValue.uuidString)"
    case .transportUnavailable(let kind, let reason):
      "Transport \(kind.rawValue) unavailable: \(reason)"
    case .protocolTimedOut: "Protocol progress deadline exceeded"
    case .connectionClosed: "Peer connection closed"
    case .operationCancelled: "Operation cancelled"
    case .outcomeUnknown(let id): "Transfer outcome is unknown: \(id.rawValue.uuidString)"
    }
  }
}
