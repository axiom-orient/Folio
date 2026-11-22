#if os(iOS) && canImport(Network) && canImport(WiFiAware)
  import Foundation
  import Network
  import WiFiAware

  @available(iOS 26.0, *)
  package actor AcornryWiFiAwareTransport: AcornryTransport {
    package nonisolated let kind: AcornryTransportKind = .wifiAware
    private var continuation: AsyncStream<AcornryTransportEvent>.Continuation?

    private let configuration: AcornryConfiguration
    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var endpoints: [AcornryDiscoveryID: WASubscriberBrowser.Endpoint] = [:]
    private var idsByEndpoint: [WASubscriberBrowser.Endpoint: AcornryDiscoveryID] = [:]
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var listenerReady = false
    private var browserReady = false
    private var running = false
    private var generation = UUID()

    package init(configuration: AcornryConfiguration) throws {
      self.configuration = configuration
    }

    package func eventStream() -> AsyncStream<AcornryTransportEvent> {
      continuation?.finish()
      let (stream, continuation) = AsyncStream<AcornryTransportEvent>.makeStream(
        bufferingPolicy: .bufferingNewest(128))
      self.continuation = continuation
      return stream
    }

    package func start() async throws {
      guard !running else { return }
      guard WACapabilities.supportedFeatures.contains(.wifiAware) else {
        throw AcornryError.transportUnavailable(.wifiAware, "device does not support Wi-Fi Aware")
      }
      guard let publishable = WAPublishableService.allServices[configuration.serviceType],
        let subscribable = WASubscribableService.allServices[configuration.serviceType]
      else {
        throw AcornryError.transportUnavailable(
          .wifiAware,
          "service \(configuration.serviceType) must be declared Publishable and Subscribable in WiFiAwareServices"
        )
      }

      try Task.checkCancellation()
      let current = UUID()
      generation = current
      listenerReady = false
      browserReady = false
      emit(
        .status(
          .init(
            kind: kind, status: .starting, security: .wifiAwareSystemSecure)))

      let listener = try NetworkListener(
        for: .wifiAware(.connecting(to: publishable, from: .allPairedDevices)),
        using: .parameters { TLS() }
          .wifiAware { $0.performanceMode = .bulk }
      ).onStateUpdate { [weak self] _, state in
        guard let self else { return }
        Task {
          switch state {
          case .ready:
            await self.markListenerReady(generation: current)
          case .waiting(let error):
            await self.reportStarting(Self.describe(error), generation: current)
          case .failed(let error):
            await self.failStart(error, generation: current)
          case .cancelled:
            await self.failStart(CancellationError(), generation: current)
          case .setup:
            break
          @unknown default:
            break
          }
        }
      }

      let browser = NetworkBrowser(
        for: .wifiAware(.connecting(to: .allPairedDevices, from: subscribable))
      ).onStateUpdate { [weak self] _, state in
        guard let self else { return }
        Task {
          switch state {
          case .ready:
            await self.markBrowserReady(generation: current)
          case .waiting(let error):
            await self.reportStarting(Self.describe(error), generation: current)
          case .failed(let error):
            await self.failStart(error, generation: current)
          case .cancelled:
            await self.failStart(CancellationError(), generation: current)
          case .setup:
            break
          @unknown default:
            break
          }
        }
      }

      running = true
      do {
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (start: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled else {
              start.resume(throwing: CancellationError())
              return
            }
            self.startContinuation = start
            self.listenerTask = Task { [weak self] in
              guard let self else { return }
              do {
                try await listener.run { connection in
                  await self.handleIncoming(connection, generation: current)
                }
              } catch {
                if !Task.isCancelled { await self.failStart(error, generation: current) }
              }
            }
            self.browserTask = Task { [weak self] in
              guard let self else { return }
              do {
                try await browser.run { discoveredEndpoints in
                  await self.update(discoveredEndpoints, generation: current)
                }
              } catch {
                if !Task.isCancelled { await self.failStart(error, generation: current) }
              }
            }
          }
        } onCancel: {
          Task { await self.cancelStart(generation: current) }
        }
      } catch {
        await cancelStart(generation: current)
        throw error
      }
    }

    private func cancelStart(generation: UUID) async {
      guard self.generation == generation else { return }
      await stop()
    }

    private func emit(_ event: AcornryTransportEvent) {
      AcornryTransportEvent.publish(event, to: continuation)
    }

    package func stop() async {
      guard running else { return }
      running = false
      generation = UUID()
      if let start = startContinuation {
        startContinuation = nil
        start.resume(throwing: CancellationError())
      }
      listenerTask?.cancel()
      browserTask?.cancel()
      _ = await listenerTask?.value
      _ = await browserTask?.value
      listenerTask = nil
      browserTask = nil
      listenerReady = false
      browserReady = false
      for id in endpoints.keys { emit(.removed(id)) }
      endpoints.removeAll()
      idsByEndpoint.removeAll()
      emit(
        .status(
          .init(
            kind: kind, status: .stopped, security: .wifiAwareSystemSecure)))
    }

    package func connect(to discoveryID: AcornryDiscoveryID) async throws
      -> any AcornryByteConnection
    {
      guard running else {
        throw AcornryError.transportUnavailable(kind, "Wi-Fi Aware transport is stopped")
      }
      guard let endpoint = endpoints[discoveryID] else {
        throw AcornryError.discoveryNotFound(discoveryID)
      }
      let connection = NetworkConnection(
        to: endpoint,
        using: .parameters { TLS() }
          .wifiAware { $0.performanceMode = .bulk })
      return AcornryWiFiAwareConnection(connection: connection, direction: .outgoing)
    }

    private func handleIncoming(_ connection: NetworkConnection<TLS>, generation: UUID) async {
      guard running, self.generation == generation else { return }
      let channel = AcornryWiFiAwareConnection(connection: connection, direction: .incoming)
      emit(.incoming(channel))
      // NetworkListener owns a child task per connection. Keep that task alive until Core closes
      // the channel instead of returning after spawning an unstructured task (WWDC25/250).
      await channel.waitUntilClosed()
    }

    private func update(_ discovered: [WASubscriberBrowser.Endpoint], generation: UUID) {
      guard running, self.generation == generation else { return }
      let discoveredSet = Set(discovered)
      let removed = idsByEndpoint.keys.filter { !discoveredSet.contains($0) }
      for endpoint in removed {
        if let id = idsByEndpoint.removeValue(forKey: endpoint) {
          endpoints.removeValue(forKey: id)
          emit(.removed(id))
        }
      }
      for endpoint in discovered where idsByEndpoint[endpoint] == nil {
        let id = AcornryDiscoveryID()
        idsByEndpoint[endpoint] = id
        endpoints[id] = endpoint
        emit(
          .discovered(
            .init(
              id: id,
              displayName: String(describing: endpoint),
              transport: kind,
              firstSeenAt: Date())))
      }
    }

    private func markListenerReady(generation: UUID) {
      guard running, self.generation == generation else { return }
      listenerReady = true
      finishStartIfReady()
    }

    private func markBrowserReady(generation: UUID) {
      guard running, self.generation == generation else { return }
      browserReady = true
      finishStartIfReady()
    }

    private func finishStartIfReady() {
      guard running, listenerReady, browserReady else { return }
      if let start = startContinuation {
        startContinuation = nil
        start.resume()
      }
      emit(
        .status(
          .init(
            kind: kind, status: .ready, security: .wifiAwareSystemSecure)))
    }

    private func reportStarting(_ detail: String, generation: UUID) {
      guard running, self.generation == generation else { return }
      emit(
        .status(
          .init(
            kind: kind,
            status: .starting,
            security: .wifiAwareSystemSecure,
            detail: detail)))
    }

    private func failStart(_ error: Error, generation: UUID) {
      guard running, self.generation == generation else { return }
      if let start = startContinuation {
        startContinuation = nil
        start.resume(throwing: error)
      }
      emit(
        .status(
          .init(
            kind: kind,
            status: .failed,
            security: .wifiAwareSystemSecure,
            detail: Self.describe(error))))
    }

    private nonisolated static func describe(_ error: Error) -> String {
      if let nw = error as? NWError, let aware = nw.wifiAware {
        return "\(aware): \(aware.localizedDescription)"
      }
      return error.localizedDescription
    }
  }

  @available(iOS 26.0, *)
  private actor AcornryWiFiAwareConnection: AcornryByteConnection {
    nonisolated let id = UUID()
    nonisolated let transportKind: AcornryTransportKind = .wifiAware
    nonisolated let direction: AcornryConnectionDirection
    private var connection: NetworkConnection<TLS>?
    private var operations: [UUID: Task<Data, Error>] = [:]
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(connection: NetworkConnection<TLS>, direction: AcornryConnectionDirection) {
      self.connection = connection
      self.direction = direction
    }

    func start() async throws {
      guard connection != nil else { throw AcornryError.connectionClosed }
      // Structured Network.framework starts lazily on send/receive.
    }

    func send(_ data: Data) async throws {
      guard let connection else { throw AcornryError.connectionClosed }
      _ = try await run {
        try await connection.send(data)
        return Data()
      }
    }

    func receive(exactly byteCount: Int) async throws -> Data {
      guard byteCount >= 0 else { throw AcornryError.protocolViolation("negative receive length") }
      if byteCount == 0 { return Data() }
      guard let connection else { throw AcornryError.connectionClosed }
      return try await run { try await connection.receive(exactly: byteCount).content }
    }

    private func run(_ operation: @escaping @Sendable () async throws -> Data) async throws -> Data
    {
      try Task.checkCancellation()
      let token = UUID()
      let task = Task { try await operation() }
      operations[token] = task
      defer { operations.removeValue(forKey: token) }
      return try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    }

    func waitUntilClosed() async {
      await withTaskCancellationHandler {
        guard connection != nil, !Task.isCancelled else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
      } onCancel: {
        Task { await self.close() }
      }
    }

    func close() async {
      // Cancel the tasks that retain an active structured connection before releasing it.
      let active = Array(operations.values)
      connection = nil
      for task in active { task.cancel() }
      for task in active { _ = await task.result }
      let waiters = closeWaiters
      closeWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }

  }
#endif
