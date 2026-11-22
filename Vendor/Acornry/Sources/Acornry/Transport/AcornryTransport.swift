import Foundation

package enum AcornryTransportEvent: Sendable {
  case status(AcornryTransportCapability)
  case discovered(AcornryDiscovery)
  case removed(AcornryDiscoveryID)
  case incoming(any AcornryByteConnection)

  /// A bounded observation queue must not leak a connection it owns but cannot deliver.
  package static func publish(
    _ event: Self, to continuation: AsyncStream<Self>.Continuation?
  ) {
    guard let continuation else {
      if case .incoming(let channel) = event { Task { await channel.close() } }
      return
    }
    switch continuation.yield(event) {
    case .dropped(let dropped):
      if case .incoming(let channel) = dropped { Task { await channel.close() } }
    case .terminated:
      if case .incoming(let channel) = event { Task { await channel.close() } }
    case .enqueued:
      break
    @unknown default:
      if case .incoming(let channel) = event { Task { await channel.close() } }
    }
  }
}

package protocol AcornryTransport: Actor {
  nonisolated var kind: AcornryTransportKind { get }
  /// A fresh, single-consumer stream for each lifecycle; cancelling an old iterator
  /// must not terminate the next session's event channel.
  func eventStream() -> AsyncStream<AcornryTransportEvent>
  func start() async throws
  func stop() async
  func connect(to discoveryID: AcornryDiscoveryID) async throws -> any AcornryByteConnection
}

package enum AcornryTransportFactory {
  package static func make(configuration: AcornryConfiguration) throws -> [any AcornryTransport] {
    var transports: [any AcornryTransport] = []
    #if canImport(Network)
      transports.append(try AcornryApplePeerTransport(configuration: configuration))
      #if os(iOS) && canImport(WiFiAware)
        if #available(iOS 26.0, *), configuration.wifiAwareMode != .disabled {
          transports.append(try AcornryWiFiAwareTransport(configuration: configuration))
        }
      #endif
    #endif
    return transports
  }
}
