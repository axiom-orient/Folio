#if canImport(Network)
  @preconcurrency import Network
  import Foundation

  package actor AcornryApplePeerTransport: AcornryTransport {
    package nonisolated let kind: AcornryTransportKind = .bonjourPeerToPeer
    private var continuation: AsyncStream<AcornryTransportEvent>.Continuation?

    private let configuration: AcornryConfiguration
    private let queue = DispatchQueue(label: "io.acornry.nearby.network", qos: .userInitiated)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [AcornryDiscoveryID: NWEndpoint] = [:]
    private var idsByEndpoint: [NWEndpoint: AcornryDiscoveryID] = [:]
    private var ownServices: Set<NWEndpoint> = []
    private var latestBrowseResults: Set<NWBrowser.Result> = []
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var listenerReady = false
    private var browserReady = false
    private var didStart = false
    private var activeConnectionCount = 0
    private var browserGeneration: UInt64 = 0
    private var lifecycleGeneration = UUID()

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
      guard !didStart else { return }
      try Task.checkCancellation()
      let listener = try NWListener(using: Self.parameters(configuration.bonjourSecurity))
      let generation = UUID()
      lifecycleGeneration = generation
      didStart = true
      listenerReady = false
      browserReady = false
      emit(
        .status(
          .init(
            kind: kind, status: .starting, security: configuration.bonjourSecurity.level)))

      listener.service = NWListener.Service(
        name: configuration.identity.displayName,
        type: configuration.serviceType,
        domain: nil,
        txtRecord: nil)
      listener.serviceRegistrationUpdateHandler = { [weak self] change in
        guard let self else { return }
        Task { await self.handleServiceRegistration(change, generation: generation) }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else {
          connection.cancel()
          return
        }
        Task { await self.handleIncoming(connection, generation: generation) }
      }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        Task { await self.handleListenerState(state, generation: generation) }
      }
      self.listener = listener

      let browser = makeBrowser()

      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          guard !Task.isCancelled else {
            cont.resume(throwing: CancellationError())
            return
          }
          self.startContinuation = cont
          listener.start(queue: queue)
          browser.start(queue: queue)
        }
      } onCancel: {
        Task { await self.cancelStart(generation: generation) }
      }
    }

    private func cancelStart(generation: UUID) async {
      guard lifecycleGeneration == generation else { return }
      await stop()
    }

    private func emit(_ event: AcornryTransportEvent) {
      AcornryTransportEvent.publish(event, to: continuation)
    }

    package func stop() async {
      guard didStart else { return }
      didStart = false
      lifecycleGeneration = UUID()
      startContinuation?.resume(throwing: CancellationError())
      startContinuation = nil
      listener?.cancel()
      browserGeneration &+= 1
      browser?.cancel()
      listener = nil
      browser = nil
      listenerReady = false
      browserReady = false
      activeConnectionCount = 0
      clearDiscoveries()
      ownServices.removeAll(); latestBrowseResults.removeAll()
      emit(
        .status(
          .init(
            kind: kind, status: .stopped, security: configuration.bonjourSecurity.level)))
    }

    package func connect(to discoveryID: AcornryDiscoveryID) async throws
      -> any AcornryByteConnection
    {
      guard didStart else {
        throw AcornryError.transportUnavailable(kind, "peer transport is stopped")
      }
      guard let endpoint = endpoints[discoveryID] else {
        throw AcornryError.discoveryNotFound(discoveryID)
      }
      let generation = lifecycleGeneration
      beginActiveConnection()
      let connection = NWConnection(
        to: endpoint, using: Self.parameters(configuration.bonjourSecurity))
      return AcornryNWConnection(
        connection: connection,
        direction: .outgoing,
        kind: kind,
        queue: queue,
        onClosed: { [weak self] in
          guard let self else { return }
          Task { await self.endActiveConnection(generation: generation) }
        })
    }

    private func handleIncoming(_ connection: NWConnection, generation: UUID) {
      guard didStart, lifecycleGeneration == generation else {
        connection.cancel()
        return
      }
      beginActiveConnection()
      let channel = AcornryNWConnection(
        connection: connection,
        direction: .incoming,
        kind: kind,
        queue: queue,
        onClosed: { [weak self] in
          guard let self else { return }
          Task { await self.endActiveConnection(generation: generation) }
        })
      emit(.incoming(channel))
    }

    private func handleListenerState(_ state: NWListener.State, generation: UUID) {
      guard didStart, lifecycleGeneration == generation else { return }
      switch state {
      case .ready:
        listenerReady = true
        finishStartIfReady()
      case .failed(let error):
        if let cont = startContinuation {
          startContinuation = nil
          cont.resume(throwing: error)
        }
        emit(
          .status(
            .init(
              kind: kind, status: .failed, security: configuration.bonjourSecurity.level,
              detail: error.localizedDescription)))
      case .waiting(let error):
        emit(
          .status(
            .init(
              kind: kind, status: .starting, security: configuration.bonjourSecurity.level,
              detail: error.localizedDescription)))
      case .cancelled:
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
      default:
        break
      }
    }

    private func handleBrowserState(_ state: NWBrowser.State, generation: UInt64) {
      guard generation == browserGeneration, browser != nil else { return }
      switch state {
      case .ready:
        browserReady = true
        finishStartIfReady()
        if activeConnectionCount > 0 { suspendBrowsingForActiveConnections() }
      case .failed(let error):
        if let cont = startContinuation {
          startContinuation = nil
          cont.resume(throwing: error)
        }
        emit(
          .status(
            .init(
              kind: kind, status: .failed, security: configuration.bonjourSecurity.level,
              detail: "browser: \(error.localizedDescription)")))
      case .waiting(let error):
        emit(
          .status(
            .init(
              kind: kind, status: .starting, security: configuration.bonjourSecurity.level,
              detail: "browser: \(error.localizedDescription)")))
      default:
        break
      }
    }

    private func finishStartIfReady() {
      guard listenerReady, browserReady else { return }
      if let cont = startContinuation {
        startContinuation = nil
        cont.resume()
      }
      emit(
        .status(
          .init(
            kind: kind, status: .ready, security: configuration.bonjourSecurity.level)))
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>, generation: UInt64) {
      guard generation == browserGeneration, browser != nil else { return }
      latestBrowseResults = results
      let remoteResults = results.filter { !ownServices.contains($0.endpoint) }
      let currentEndpoints = Set(remoteResults.map(\.endpoint))
      let removed = idsByEndpoint.keys.filter { !currentEndpoints.contains($0) }
      for endpoint in removed {
        if let id = idsByEndpoint.removeValue(forKey: endpoint) {
          endpoints.removeValue(forKey: id)
          emit(.removed(id))
        }
      }

      for result in remoteResults where idsByEndpoint[result.endpoint] == nil {
        let id = AcornryDiscoveryID()
        idsByEndpoint[result.endpoint] = id
        endpoints[id] = result.endpoint
        let name: String
        if case .service(let serviceName, _, _, _) = result.endpoint {
          name = serviceName
        } else {
          name = result.endpoint.debugDescription
        }
        emit(
          .discovered(
            .init(
              id: id,
              displayName: name,
              transport: kind,
              firstSeenAt: Date())))
      }
    }

    private func handleServiceRegistration(_ change: NWListener.ServiceRegistrationChange, generation: UUID) {
      guard didStart, lifecycleGeneration == generation else { return }
      switch change {
      case .add(let endpoint): ownServices.insert(endpoint)
      case .remove(let endpoint): ownServices.remove(endpoint)
      @unknown default: return
      }
      // Registration may arrive after browser results. Reconcile the exact
      // registered endpoints; equal display names are not peer identity.
      if browser != nil { handleBrowseResults(latestBrowseResults, generation: browserGeneration) }
    }

    private func makeBrowser() -> NWBrowser {
      browserGeneration &+= 1
      let generation = browserGeneration
      let browser = NWBrowser(
        for: .bonjour(type: configuration.serviceType, domain: nil),
        using: Self.parameters(configuration.bonjourSecurity))
      browser.browseResultsChangedHandler = { [weak self] results, _ in
        guard let self else { return }
        Task { await self.handleBrowseResults(results, generation: generation) }
      }
      browser.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        Task { await self.handleBrowserState(state, generation: generation) }
      }
      self.browser = browser
      return browser
    }

    private func beginActiveConnection() {
      activeConnectionCount += 1
      guard activeConnectionCount == 1, browserReady else { return }
      suspendBrowsingForActiveConnections()
    }

    private func suspendBrowsingForActiveConnections() {
      guard activeConnectionCount > 0, browser != nil else { return }

      // TN3213 recommends stopping peer-to-peer Bonjour browsing once a peer is
      // selected because continued browsing can interfere with the active P2P
      // connection. Keep the listener alive for inbound transfers, but suspend
      // discovery until every active connection has closed.
      browserGeneration &+= 1
      browser?.cancel()
      browser = nil
      browserReady = false
      emit(
        .status(
          .init(
            kind: kind, status: .readyDiscoveryPaused,
            security: configuration.bonjourSecurity.level,
            detail: "discovery paused while a peer transfer is active")))
    }

    private func endActiveConnection(generation: UUID) {
      guard didStart, lifecycleGeneration == generation, activeConnectionCount > 0 else { return }
      activeConnectionCount -= 1
      guard activeConnectionCount == 0, didStart, browser == nil else { return }

      browserReady = false
      emit(
        .status(
          .init(
            kind: kind, status: .starting, security: configuration.bonjourSecurity.level,
            detail: "resuming peer discovery")))
      let browser = makeBrowser()
      browser.start(queue: queue)
    }

    private func clearDiscoveries() {
      for id in endpoints.keys { emit(.removed(id)) }
      endpoints.removeAll()
      idsByEndpoint.removeAll()
    }

    private nonisolated static func parameters(_ security: AcornryBonjourSecurity) -> NWParameters {
      let tcp = NWProtocolTCP.Options()
      tcp.enableKeepalive = true
      tcp.keepaliveIdle = 10
      let parameters: NWParameters
      switch security {
      case .approvalOnly:
        parameters = NWParameters(tls: nil, tcp: tcp)
      case .preSharedKey(let secret):
        parameters = NWParameters(tls: pskTLS(secret), tcp: tcp)
      }
      parameters.includePeerToPeer = true
      return parameters
    }

    private nonisolated static func pskTLS(_ secret: AcornrySharedSecret) -> NWProtocolTLS.Options {
      let options = NWProtocolTLS.Options()
      let key = secret.data.withUnsafeBytes { DispatchData(bytes: $0) }
      let identityData = Data("acornry-nearby-v1".utf8)
      let identity = identityData.withUnsafeBytes { DispatchData(bytes: $0) }
      sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
      sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
      sec_protocol_options_add_pre_shared_key(
        options.securityProtocolOptions,
        key as __DispatchData,
        identity as __DispatchData)
      let raw = UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)
      if let suite = tls_ciphersuite_t(rawValue: raw) {
        sec_protocol_options_append_tls_ciphersuite(options.securityProtocolOptions, suite)
      }
      return options
    }
  }

  private actor AcornryNWConnection: AcornryByteConnection {
    nonisolated let id = UUID()
    nonisolated let transportKind: AcornryTransportKind
    nonisolated let direction: AcornryConnectionDirection

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onClosed: @Sendable () -> Void
    private var started = false
    private var ready = false
    private var terminalError: Error?
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private var didNotifyClosed = false

    init(
      connection: NWConnection,
      direction: AcornryConnectionDirection,
      kind: AcornryTransportKind,
      queue: DispatchQueue,
      onClosed: @escaping @Sendable () -> Void
    ) {
      self.connection = connection
      self.direction = direction
      self.transportKind = kind
      self.queue = queue
      self.onClosed = onClosed
      connection.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        Task { await self.handle(state) }
      }
    }

    func start() async throws {
      try Task.checkCancellation()
      if ready { return }
      if let terminalError { throw terminalError }
      if !started {
        started = true
        connection.start(queue: queue)
      }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          if ready {
            cont.resume()
            return
          }
          if let terminalError {
            cont.resume(throwing: terminalError)
            return
          }
          startWaiters.append(cont)
        }
      } onCancel: {
        Task { await self.close() }
      }
    }

    func send(_ data: Data) async throws {
      try Task.checkCancellation()
      if !ready { try await start() }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          connection.send(
            content: data,
            completion: .contentProcessed { error in
              if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
      } onCancel: {
        Task { await self.close() }
      }
    }

    func receive(exactly byteCount: Int) async throws -> Data {
      guard byteCount >= 0 else { throw AcornryError.protocolViolation("negative receive length") }
      if byteCount == 0 { return Data() }
      if !ready { try await start() }
      var result = Data()
      result.reserveCapacity(byteCount)
      while result.count < byteCount {
        try Task.checkCancellation()
        let remaining = byteCount - result.count
        let part: Data = try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
              data, _, _, error in
              if let error {
                cont.resume(throwing: error)
                return
              }
              if let data, !data.isEmpty {
                cont.resume(returning: data)
                return
              }
              cont.resume(throwing: AcornryError.connectionClosed)
            }
          }
        } onCancel: {
          connection.cancel()
        }
        result.append(part)
      }
      return result
    }

    func close() async {
      fail(AcornryError.connectionClosed)
      connection.cancel()
      notifyClosedIfNeeded()
    }

    private func handle(_ state: NWConnection.State) {
      switch state {
      case .ready:
        guard terminalError == nil, !didNotifyClosed else { return }
        ready = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
      case .failed(let error):
        fail(error)
        notifyClosedIfNeeded()
      case .cancelled:
        fail(AcornryError.connectionClosed)
        notifyClosedIfNeeded()
      default:
        break
      }
    }

    private func fail(_ error: Error) {
      ready = false
      if terminalError == nil { terminalError = error }
      let waiters = startWaiters
      startWaiters.removeAll()
      for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func notifyClosedIfNeeded() {
      guard !didNotifyClosed else { return }
      didNotifyClosed = true
      onClosed()
    }
  }
#endif
