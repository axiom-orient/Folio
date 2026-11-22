import Foundation

package enum AcornryConnectionDirection: Sendable { case incoming, outgoing }

package protocol AcornryByteConnection: Sendable {
  var id: UUID { get }
  var transportKind: AcornryTransportKind { get }
  var direction: AcornryConnectionDirection { get }
  func start() async throws
  func send(_ data: Data) async throws
  func receive(exactly byteCount: Int) async throws -> Data
  /// Must terminate outstanding reads/start/send, or honor cancellation of those tasks.
  func close() async
}

package actor AcornryFramedConnection {
  private let connection: any AcornryByteConnection
  private let maxFrameBytes: Int
  private let protocolIdleTimeout: Duration
  private var closed = false
  private var receiving = false
  private var sending = false

  package init(
    connection: any AcornryByteConnection, maxFrameBytes: Int,
    protocolIdleTimeout: Duration = .seconds(30)
  ) {
    self.connection = connection
    self.maxFrameBytes = maxFrameBytes
    self.protocolIdleTimeout = protocolIdleTimeout
  }

  package var transportKind: AcornryTransportKind { connection.transportKind }

  package func start() async throws {
    guard !closed else { throw AcornryError.connectionClosed }
    try await AcornryDeadline.run(
      for: protocolIdleTimeout, interrupt: { [connection] in await connection.close() },
      operation: { [connection] in try await connection.start() })
  }

  package func close() async {
    guard !closed else { return }
    closed = true
    await connection.close()
  }

  package func send<T: Encodable>(_ kind: AcornryFrameKind, _ value: T) async throws {
    try await send(kind, payload: AcornryWire.encodeJSON(value))
  }

  package func send(_ kind: AcornryFrameKind, payload: Data) async throws {
    guard !closed else { throw AcornryError.connectionClosed }
    guard !sending else { throw AcornryError.invalidState("concurrent frame writers") }
    sending = true
    defer { sending = false }
    let bytes = try AcornryWire.encode(
      .init(kind: kind, payload: payload), maxFrameBytes: maxFrameBytes)
    try await AcornryDeadline.run(
      for: protocolIdleTimeout, interrupt: { [connection] in await connection.close() },
      operation: { [connection] in try await connection.send(bytes) })
  }

  package func receive(timeout: Duration? = nil) async throws -> AcornryFrame {
    guard !closed else { throw AcornryError.connectionClosed }
    guard !receiving else { throw AcornryError.invalidState("concurrent frame readers") }
    receiving = true
    defer { receiving = false }
    return try await AcornryDeadline.run(
      for: timeout ?? protocolIdleTimeout, interrupt: { [connection] in await connection.close() },
      operation: { [connection, maxFrameBytes] in
        let header = try await connection.receive(exactly: AcornryWire.headerByteCount)
        let (kind, count) = try AcornryWire.decodeHeader(header, maxFrameBytes: maxFrameBytes)
        let payload = count == 0 ? Data() : try await connection.receive(exactly: count)
        guard payload.count == count else {
          throw AcornryError.protocolViolation("short frame payload")
        }
        return AcornryFrame(kind: kind, payload: payload)
      })
  }
}
