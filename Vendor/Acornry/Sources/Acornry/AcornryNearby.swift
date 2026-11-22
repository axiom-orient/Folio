import Foundation

/// Agent- and UI-friendly façade over Acornry's single nearby-transfer domain.
///
/// UI, automation, and agent adapters call the same typed methods. Network transports
/// discover/connect peers; the Acornry wire protocol and durable file store own transfer semantics.
public actor AcornryNearby {
  public nonisolated let descriptor: AcornryNearbyDescriptor
  /// Single-consumer convenience stream. Use observations() for independent UI/agent subscriptions.
  public nonisolated let events: AsyncStream<AcornryEvent>
  private nonisolated let eventContinuation: AsyncStream<AcornryEvent>.Continuation

  private var observers: [UUID: AsyncStream<AcornryEvent>.Continuation] = [:]
  private var storageObservers: [UUID: AsyncStream<AcornryNearbyObservation>.Continuation] = [:]
  private var receiveRevision = UUID()

  private let configuration: AcornryConfiguration
  private let receiveStore: AcornryReceiveStore
  private let fileStore: AcornryFileStore
  private let journal: AcornryOperationJournal
  private let approvals = AcornryApprovalRegistry()
  private let transports: [any AcornryTransport]

  private var lifecycle: AcornryLifecycle = .stopped
  private var capabilities: [AcornryTransportKind: AcornryTransportCapability] = [:]
  private var discoveries: [AcornryDiscoveryID: AcornryDiscovery] = [:]
  private var discoveryTransport: [AcornryDiscoveryID: AcornryTransportKind] = [:]
  private var peers: [AcornryPeerID: AcornryPeer] = [:]
  private var peerDiscovery: [AcornryPeerID: AcornryDiscoveryID] = [:]
  private var incomingOffers: [AcornryTransferID: AcornryIncomingOffer] = [:]
  private var progress = AcornryProgressLedger()

  private var transportConsumers: [AcornryTransportKind: Task<Void, Never>] = [:]
  private var incomingTasks: [UUID: Task<Void, Never>] = [:]
  private struct OutgoingWork {
    let token: UUID
    let task: Task<AcornryTransferReceipt?, any Error>
  }
  private var outgoingTasks: [AcornryTransferID: OutgoingWork] = [:]
  private var identifyTasks: [UUID: Task<AcornryPeer, any Error>] = [:]
  private struct ImportWork {
    let token: UUID
    let task: Task<AcornryImportReceipt, any Error>
  }
  private var importTasks: [AcornryTransferID: ImportWork] = [:]
  private var incomingChannels: [UUID: any AcornryByteConnection] = [:]
  private var startTask: Task<AcornrySnapshot, any Error>?
  private var stopTask: Task<Void, Never>?
  private var generation = UUID()
  private var activeOutgoingConnections: [AcornryTransferID: AcornryFramedConnection] = [:]
  private var activeIncomingConnections: [AcornryTransferID: any AcornryByteConnection] = [:]

  public init(configuration: AcornryConfiguration) throws {
    try configuration.validateRootSeparation()
    self.configuration = configuration
    self.descriptor = configuration.nearbyDescriptor
    self.receiveStore = try AcornryReceiveStore(rootURL: configuration.stagingRootURL)
    self.fileStore = try AcornryFileStore(rootURL: configuration.destinationRootURL)
    self.journal = try AcornryOperationJournal(stagingRootURL: configuration.stagingRootURL)
    self.transports = try AcornryTransportFactory.make(configuration: configuration)
    (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    for transport in transports {
      capabilities[transport.kind] = .init(
        kind: transport.kind,
        status: .stopped,
        security: transport.kind == .wifiAware
          ? .wifiAwareSystemSecure : configuration.bonjourSecurity.level)
    }
  }

  package init(configuration: AcornryConfiguration, transports: [any AcornryTransport]) throws {
    try configuration.validateRootSeparation()
    self.configuration = configuration
    self.descriptor = configuration.nearbyDescriptor
    self.receiveStore = try AcornryReceiveStore(rootURL: configuration.stagingRootURL)
    self.fileStore = try AcornryFileStore(rootURL: configuration.destinationRootURL)
    self.journal = try AcornryOperationJournal(stagingRootURL: configuration.stagingRootURL)
    self.transports = transports
    (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    for transport in transports {
      capabilities[transport.kind] = .init(
        kind: transport.kind,
        status: .stopped,
        security: transport.kind == .wifiAware
          ? .wifiAwareSystemSecure : configuration.bonjourSecurity.level)
    }
  }

  deinit {
    eventContinuation.finish()
    for observer in observers.values { observer.finish() }
    for observer in storageObservers.values { observer.finish() }
    for task in transportConsumers.values { task.cancel() }
    for task in incomingTasks.values { task.cancel() }
    for work in outgoingTasks.values { work.task.cancel() }
    for task in identifyTasks.values { task.cancel() }
    for work in importTasks.values { work.task.cancel() }
    startTask?.cancel()
  }

  /// Each subscription has independent cancellation and a bounded event buffer.
  /// Events are observation hints, not a durable log. Re-read snapshot() for authoritative state.
  public func observations() -> AsyncStream<AcornryEvent> {
    let token = UUID()
    let (stream, continuation) = AsyncStream<AcornryEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(256))
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(token) }
    }
    observers[token] = continuation
    return stream
  }

  /// One ordered subscription for public events and post-reservation storage hints.
  package func storageObservations() -> AsyncStream<AcornryNearbyObservation> {
    let token = UUID()
    let (stream, continuation) = AsyncStream<AcornryNearbyObservation>.makeStream(
      bufferingPolicy: .bufferingNewest(256))
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(token) }
    }
    storageObservers[token] = continuation
    // Cover the gap between an initial inventory read and subscription.
    continuation.yield(.init(event: nil, receiveRevision: receiveRevision))
    return stream
  }

  private func removeObserver(_ token: UUID) {
    observers.removeValue(forKey: token)
    storageObservers.removeValue(forKey: token)
  }

  private func emit(_ event: AcornryEvent) {
    eventContinuation.yield(event)
    for observer in observers.values { observer.yield(event) }
    for observer in storageObservers.values {
      observer.yield(.init(event: event, receiveRevision: receiveRevision))
    }
  }

  // MARK: - Lifecycle / inspection

  @discardableResult
  public func start() async throws -> AcornrySnapshot {
    guard lifecycle == .stopped, stopTask == nil else {
      throw AcornryError.invalidState("start requires stopped lifecycle")
    }
    try Task.checkCancellation()
    generation = UUID()
    let current = generation
    lifecycle = .starting
    emit(.lifecycle(.starting))
    let task = Task { try await self.startTransports(generation: current) }
    startTask = task
    do {
      let result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      if generation == current { startTask = nil }
      return result
    } catch {
      if generation == current {
        startTask = nil
        await stop()
      }
      throw error
    }
  }

  private func startTransports(generation current: UUID) async throws -> AcornrySnapshot {
    guard transports.contains(where: { $0.kind == .bonjourPeerToPeer }) else {
      throw AcornryError.transportUnavailable(
        .bonjourPeerToPeer, "Network.framework is unavailable in this build/runtime")
    }
    if configuration.wifiAwareMode == .required,
      !transports.contains(where: { $0.kind == .wifiAware })
    {
      throw AcornryError.transportUnavailable(
        .wifiAware,
        "Wi-Fi Aware requires a supported iOS 26+ SDK, device, entitlement, and service declaration"
      )
    }
    for transport in transports {
      let stream = await transport.eventStream()
      try Task.checkCancellation()
      guard generation == current, lifecycle == .starting else {
        throw AcornryError.operationCancelled
      }
      transportConsumers[transport.kind] = Task { [weak self] in
        for await event in stream {
          guard !Task.isCancelled else {
            if case .incoming(let channel) = event { await channel.close() }
            return
          }
          await self?.handleTransportEvent(event, generation: current)
        }
      }
    }
    for transport in transports {
      try Task.checkCancellation()
      do {
        try await AcornryDeadline.run(
          for: configuration.protocolIdleTimeout,
          interrupt: { await transport.stop() }, operation: { try await transport.start() })
      } catch {
        try Task.checkCancellation()
        guard generation == current, lifecycle == .starting else {
          throw AcornryError.operationCancelled
        }
        let capability = AcornryTransportCapability(
          kind: transport.kind, status: .unavailable,
          security: transport.kind == .wifiAware
            ? .wifiAwareSystemSecure : configuration.bonjourSecurity.level,
          detail: String(describing: error))
        capabilities[transport.kind] = capability
        emit(.transport(capability))
        let optional = transport.kind == .wifiAware && configuration.wifiAwareMode == .opportunistic
        if !optional { throw error }
      }
      try Task.checkCancellation()
      guard generation == current, lifecycle == .starting else {
        throw AcornryError.operationCancelled
      }
    }
    lifecycle = .running
    emit(.lifecycle(.running))
    let result = try await snapshot()
    try Task.checkCancellation()
    guard generation == current, lifecycle == .running else {
      throw AcornryError.operationCancelled
    }
    return result
  }

  /// Drains old tasks before publishing stopped. A new start cannot race old result callbacks.
  public func stop() async {
    if let stopTask {
      await stopTask.value
      return
    }
    // Local import/archive requests may run without starting network transports.
    guard lifecycle != .stopped || !importTasks.isEmpty else { return }
    lifecycle = .stopping
    emit(.lifecycle(.stopping))
    let task = Task { await self.drainAndStop() }
    stopTask = task
    await task.value
    stopTask = nil
  }

  private func drainAndStop() async {
    let starting = startTask
    let outgoing = outgoingTasks.values.map(\.task)
    let identifying = Array(identifyTasks.values)
    let importing = importTasks.values.map(\.task)
    let incoming = Array(incomingTasks.values)
    starting?.cancel()
    for task in outgoing { task.cancel() }
    for task in identifying { task.cancel() }
    for task in importing { task.cancel() }
    // Cancel pending approval before closing channels; a close is not a rollback of committed bytes.
    await approvals.cancelAll()
    for task in incoming { task.cancel() }
    for connection in Array(activeOutgoingConnections.values) { await connection.close() }
    for connection in Array(incomingChannels.values) { await connection.close() }
    for transport in transports { await transport.stop() }
    for task in transportConsumers.values { task.cancel() }
    _ = await starting?.result
    for task in outgoing { _ = await task.result }
    for task in identifying { _ = await task.result }
    for task in importing { _ = await task.result }
    for task in incoming { await task.value }
    startTask = nil
    outgoingTasks.removeAll()
    identifyTasks.removeAll()
    importTasks.removeAll()
    activeOutgoingConnections.removeAll()
    activeIncomingConnections.removeAll()
    incomingChannels.removeAll()
    incomingTasks.removeAll()
    transportConsumers.removeAll()
    discoveries.removeAll()
    discoveryTransport.removeAll()
    peers.removeAll()
    peerDiscovery.removeAll()
    incomingOffers.removeAll()
    progress.removeAll()
    for (kind, old) in capabilities {
      capabilities[kind] = .init(kind: kind, status: .stopped, security: old.security)
    }
    lifecycle = .stopped
    emit(.lifecycle(.stopped))
  }

  public func snapshot() async throws -> AcornrySnapshot {
    let unknown = try await journal.all()
    return AcornrySnapshot(
      descriptor: descriptor,
      lifecycle: lifecycle,
      transports: capabilities.values.sorted { $0.kind.rawValue < $1.kind.rawValue },
      discoveries: discoveries.values.sorted { $0.firstSeenAt < $1.firstSeenAt },
      peers: peers.values.sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      },
      incomingOffers: incomingOffers.values.sorted { $0.receivedAt < $1.receivedAt },
      transfers: progress.snapshot,
      unknownOutgoingOperations: unknown)
  }

  public func savedTransfers() async throws -> [AcornryImportReceipt] {
    try await fileStore.savedTransfers()
  }

  public func archivedTransfers() async throws -> [AcornryImportReceipt] {
    try await fileStore.archivedTransfers()
  }

  /// Discover retained receive work without replaying it or claiming that its
  /// destination publication succeeded. Explicit retry revalidates the bytes.
  public func receivedInventory() async throws -> AcornryReceiveInventory {
    let pending = try await receiveStore.pendingImports(limits: configuration.limits)
      .filter { !isTransferActive($0.transferID) }
    let inventory = try await fileStore.receivedInventory(pendingImports: pending)
    return AcornryReceiveInventory(active: inventory.active, archived: inventory.archived,
      pendingImports: inventory.pendingImports.filter { !isTransferActive($0.transferID) })
  }

  @discardableResult public func archiveReceived(_ id: AcornryTransferID) async throws -> AcornryImportReceipt {
    try await moveReceived(id, toArchive: true)
  }

  @discardableResult public func restoreReceived(_ id: AcornryTransferID) async throws -> AcornryImportReceipt {
    try await moveReceived(id, toArchive: false)
  }

  private func moveReceived(_ id: AcornryTransferID, toArchive: Bool) async throws -> AcornryImportReceipt {
    guard lifecycle != .stopping, stopTask == nil, !isTransferActive(id) else { throw AcornryError.transferConflict(id) }
    let token = UUID()
    let task = Task {
      if toArchive { return try await self.fileStore.archive(id) }
      return try await self.fileStore.restore(id)
    }
    importTasks[id] = ImportWork(token: token, task: task)
    defer { if importTasks[id]?.token == token { importTasks.removeValue(forKey: id) } }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  // MARK: - Peer identity

  /// Opens a short-lived connection and resolves the advertised endpoint to Acornry's stable peer identity.
  public func identify(_ discoveryID: AcornryDiscoveryID) async throws -> AcornryPeer {
    guard lifecycle == .running else {
      throw AcornryError.invalidState("identify requires running lifecycle")
    }
    try Task.checkCancellation()
    let id = UUID()
    let task = Task { try await self.performIdentify(discoveryID) }
    identifyTasks[id] = task
    defer { identifyTasks.removeValue(forKey: id) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func performIdentify(_ discoveryID: AcornryDiscoveryID) async throws -> AcornryPeer {
    let transport = try transport(for: discoveryID)
    let channel = try await transport.connect(to: discoveryID)
    let framed = makeFramedConnection(channel)
    do {
      let peer = try await handshake(framed, discoveryID: discoveryID)
      await framed.close()
      return peer
    } catch {
      await framed.close()
      throw error
    }
  }

  // MARK: - Incoming control

  public func accept(_ transferID: AcornryTransferID) async throws {
    guard incomingOffers[transferID] != nil else {
      throw AcornryError.approvalNotPending(transferID)
    }
    try await approvals.decide(transferID, accepted: true, reason: nil)
  }

  public func reject(_ transferID: AcornryTransferID, reason: String? = nil) async throws {
    guard incomingOffers[transferID] != nil else {
      throw AcornryError.approvalNotPending(transferID)
    }
    try await approvals.decide(transferID, accepted: false, reason: reason)
  }

  public func cancel(_ transferID: AcornryTransferID) async throws {
    if let work = outgoingTasks[transferID] {
      // One protocol writer: cancellation closes its I/O rather than racing a second cancel frame writer.
      work.task.cancel()
      if let framed = activeOutgoingConnections[transferID] { await framed.close() }
      return
    }
    if let work = importTasks[transferID] {
      work.task.cancel()
      return
    }
    if incomingOffers[transferID] != nil, configuration.incomingPolicy == .requireApproval {
      do {
        try await approvals.decide(transferID, accepted: false, reason: "cancelled")
        return
      } catch AcornryError.approvalNotPending {
        // A decision may have won while the offer projection was still visible.
        // Continue to cancel the owning connection; do not claim the accepted work stopped.
      }
    }
    if let connection = activeIncomingConnections[transferID] {
      incomingTasks[connection.id]?.cancel()
      await connection.close()
      return
    }
    throw AcornryError.invalidState("no active transfer \(transferID)")
  }

  /// Retries only finalized staging. The reservation excludes receive/reset and competing local retries.
  public func retryImport(_ transferID: AcornryTransferID) async throws -> AcornryImportReceipt {
    guard lifecycle != .stopping, stopTask == nil else {
      throw AcornryError.invalidState("import is unavailable while stopping")
    }
    guard !isTransferActive(transferID) else { throw AcornryError.transferConflict(transferID) }
    try Task.checkCancellation()
    let token = UUID()
    let task = Task { () throws -> AcornryImportReceipt in
      guard let staged = try await self.receiveStore.stagedTransfer(transferID, limits: self.configuration.limits) else {
        throw AcornryError.invalidState("no finalized staging payload exists for \(transferID)")
      }
      try Task.checkCancellation()
      return try await self.fileStore.commit(staged)
    }
    importTasks[transferID] = ImportWork(token: token, task: task)
    defer { if importTasks[transferID]?.token == token { importTasks.removeValue(forKey: transferID) } }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  // MARK: - Send / recovery

  public func send(
    files: [AcornryFileSource], to discoveryID: AcornryDiscoveryID,
    transferID: AcornryTransferID = AcornryTransferID(), displayName: String? = nil
  ) async throws -> AcornryTransferReceipt {
    try await send(
      files: files, to: discoveryID, expectedPeerID: nil, transferID: transferID,
      displayName: displayName)
  }

  public func send(
    files: [AcornryFileSource], to peerID: AcornryPeerID,
    transferID: AcornryTransferID = AcornryTransferID(), displayName: String? = nil
  ) async throws -> AcornryTransferReceipt {
    guard let discoveryID = peerDiscovery[peerID], discoveries[discoveryID] != nil else {
      throw AcornryError.peerNotFound(peerID)
    }
    return try await send(
      files: files, to: discoveryID, expectedPeerID: peerID, transferID: transferID,
      displayName: displayName)
  }

  private func send(
    files: [AcornryFileSource], to discoveryID: AcornryDiscoveryID,
    expectedPeerID: AcornryPeerID?, transferID: AcornryTransferID, displayName: String?
  ) async throws -> AcornryTransferReceipt {
    let value = try await runOutgoing(transferID) { nearby in
      if let record = try await nearby.journal.record(transferID), record.phase == .awaitingReceipt
      {
        throw AcornryError.outcomeUnknown(transferID)
      }
      if try await nearby.fileStore.receipt(for: transferID) != nil {
        throw AcornryError.transferConflict(transferID)
      }
      let identity = nearby.configuration.identity
      let limits = nearby.configuration.limits
      let name = displayName ?? (files.count == 1 ? files[0].relativePath : "\(files.count) files")
      let preparation = Task.detached(priority: .userInitiated) {
        try AcornryPreparedTransfer.prepare(
          id: transferID, sender: identity, displayName: name, sources: files, limits: limits)
      }
      let prepared = try await withTaskCancellationHandler {
        try await preparation.value
      } onCancel: {
        preparation.cancel()
      }
      try Task.checkCancellation()
      if let existing = try await nearby.journal.record(transferID) {
        guard existing.manifest == prepared.manifest,
          expectedPeerID == nil || expectedPeerID == existing.targetPeerID
        else { throw AcornryError.transferConflict(transferID) }
      }
      nearby.updateProgress(
        .init(
          transferID: transferID, direction: .outgoing, peerID: expectedPeerID, phase: .preparing,
          completedBytes: 0, totalBytes: prepared.manifest.totalBytes, completedFiles: 0,
          totalFiles: prepared.manifest.files.count))
      return try await nearby.performSend(prepared, to: discoveryID, expectedPeerID: expectedPeerID)
    }
    guard let value else { throw AcornryError.invalidState("send returned no receipt") }
    return value
  }

  /// No new send is allowed while an unknown record remains. Query only the original handshake peer.
  public func reconcile(
    _ transferID: AcornryTransferID, with discoveryID: AcornryDiscoveryID
  ) async throws -> AcornryTransferReceipt? {
    try await reconcile(transferID, with: discoveryID, expectedPeerID: nil)
  }

  public func reconcile(
    _ transferID: AcornryTransferID, with peerID: AcornryPeerID
  ) async throws -> AcornryTransferReceipt? {
    guard let discoveryID = peerDiscovery[peerID], discoveries[discoveryID] != nil else {
      throw AcornryError.peerNotFound(peerID)
    }
    return try await reconcile(transferID, with: discoveryID, expectedPeerID: peerID)
  }

  private func reconcile(
    _ transferID: AcornryTransferID, with discoveryID: AcornryDiscoveryID,
    expectedPeerID: AcornryPeerID?
  ) async throws -> AcornryTransferReceipt? {
    try await runOutgoing(transferID, reconciling: true) { nearby in
      guard let record = try await nearby.journal.record(transferID),
        record.phase == .awaitingReceipt
      else {
        throw AcornryError.invalidState("no persisted unknown operation for \(transferID)")
      }
      guard expectedPeerID == nil || expectedPeerID == record.targetPeerID else {
        throw AcornryError.transferConflict(transferID)
      }
      let transport = try nearby.transport(for: discoveryID)
      let channel = try await transport.connect(to: discoveryID)
      let framed = nearby.makeFramedConnection(channel)
      nearby.activeOutgoingConnections[transferID] = framed
      let peer: AcornryPeer
      do {
        peer = try await nearby.handshake(framed, discoveryID: discoveryID)
        guard peer.id == record.targetPeerID else {
          throw AcornryError.transferConflict(transferID)
        }
      } catch {
        await framed.close()
        throw error
      }
      return try await nearby.makeOutgoingSession().reconcile(record, with: peer, framed: framed)
    }
  }

  /// The task itself is the reservation: installed before this actor's first suspension.
  private func runOutgoing(
    _ id: AcornryTransferID, reconciling: Bool = false,
    operation: @escaping @Sendable (isolated AcornryNearby) async throws -> AcornryTransferReceipt?
  ) async throws -> AcornryTransferReceipt? {
    guard lifecycle == .running else {
      throw AcornryError.invalidState("outgoing operation requires running lifecycle")
    }
    guard !isTransferActive(id) else { throw AcornryError.transferConflict(id) }
    try Task.checkCancellation()
    let token = UUID()
    let current = generation
    let task = Task { try await operation(self) }
    outgoingTasks[id] = OutgoingWork(token: token, task: task)
    do {
      let receipt = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      if outgoingTasks[id]?.token == token {
        outgoingTasks.removeValue(forKey: id)
        activeOutgoingConnections.removeValue(forKey: id)
        if let receipt, generation == current, lifecycle == .running {
          setTerminalOutgoing(receipt)
          emit(.transferCompleted(receipt))
        }
      }
      return receipt
    } catch {
      let failure: any Error =
        task.isCancelled && !(error is AcornryError) ? AcornryError.operationCancelled : error
      if outgoingTasks[id]?.token == token {
        outgoingTasks.removeValue(forKey: id)
        activeOutgoingConnections.removeValue(forKey: id)
        if generation == current, lifecycle == .running {
          if reconciling || failure as? AcornryError == .outcomeUnknown(id) {
            setProgressPhase(id, .outcomeUnknown)
          } else if task.isCancelled || failure as? AcornryError == .operationCancelled {
            setProgressPhase(id, .cancelled)
          } else if case AcornryError.transferRejected = failure {
            setProgressPhase(id, .rejected)
          } else {
            setProgressPhase(id, .failed)
          }
          emit(.transferFailed(id, String(describing: failure)))
        }
      }
      throw failure
    }
  }

  private func isTransferActive(_ id: AcornryTransferID) -> Bool {
    outgoingTasks[id] != nil || activeIncomingConnections[id] != nil || importTasks[id] != nil
  }

  private func makeFramedConnection(_ channel: any AcornryByteConnection) -> AcornryFramedConnection
  {
    AcornryFramedConnection(
      connection: channel, maxFrameBytes: configuration.limits.maxFrameBytes,
      protocolIdleTimeout: configuration.protocolIdleTimeout)
  }

  // MARK: - Transport events

  private func handleTransportEvent(_ event: AcornryTransportEvent, generation current: UUID) async
  {
    guard generation == current, lifecycle == .starting || lifecycle == .running else {
      if case .incoming(let channel) = event { await channel.close() }
      return
    }
    switch event {
    case .status(let capability):
      capabilities[capability.kind] = capability
      emit(.transport(capability))
    case .discovered(let discovery):
      discoveries[discovery.id] = discovery
      discoveryTransport[discovery.id] = discovery.transport
      emit(.discoveryAdded(discovery))
    case .removed(let id):
      discoveries.removeValue(forKey: id)
      discoveryTransport.removeValue(forKey: id)
      let affectedPeers = peerDiscovery.filter { $0.value == id }.map(\.key)
      for peerID in affectedPeers {
        peerDiscovery.removeValue(forKey: peerID)
        peers.removeValue(forKey: peerID)
      }
      emit(.discoveryRemoved(id))
    case .incoming(let connection):
      guard incomingTasks.count < configuration.maxIncomingConnections,
        incomingTasks[connection.id] == nil
      else {
        await connection.close()
        emit(.transferFailed(nil, "incoming connection budget exhausted"))
        return
      }
      let connectionID = connection.id
      incomingChannels[connectionID] = connection
      incomingTasks[connectionID] = Task { [weak self] in
        await self?.handleIncomingConnection(connection)
      }
    }
  }

  private func handleIncomingConnection(_ channel: any AcornryByteConnection) async {
    let connectionID = channel.id
    let framed = makeFramedConnection(channel)
    var transferID: AcornryTransferID?
    do {
      let peer = try await handshake(framed, discoveryID: nil)
      let first = try await framed.receive()
      switch first.kind {
      case .offer:
        let offer = try AcornryWire.decodeJSON(AcornryOffer.self, from: first.payload)
        transferID = offer.manifest.transferID
        try await receive(offer: offer, from: peer, over: channel, framed: framed)
      case .receiptQuery:
        try await makeIncomingSession().answerReceiptQuery(first, from: peer, framed: framed)
      default:
        try? await framed.send(
          .protocolError,
          AcornryProtocolErrorPayload(
            code: "unexpected_first_frame",
            detail: "Expected offer or receipt query"))
        throw AcornryError.protocolViolation("unexpected first frame \(first.kind)")
      }
    } catch {
      emit(.transferFailed(transferID, String(describing: error)))
    }
    await framed.close()
    incomingTasks.removeValue(forKey: connectionID)
    incomingChannels.removeValue(forKey: connectionID)
  }

  // MARK: - Protocol execution

  private func handshake(
    _ framed: AcornryFramedConnection,
    discoveryID: AcornryDiscoveryID?
  ) async throws -> AcornryPeer {
    try await framed.start()
    try await framed.send(
      .hello,
      AcornryHello(
        peer: configuration.identity,
        protocolVersion: AcornryWire.protocolVersion))
    let frame = try await framed.receive()
    guard frame.kind == .hello else { throw AcornryError.protocolViolation("hello required") }
    let hello = try AcornryWire.decodeJSON(AcornryHello.self, from: frame.payload)
    guard hello.protocolVersion == AcornryWire.protocolVersion else {
      throw AcornryError.unsupportedProtocol(hello.protocolVersion)
    }
    guard hello.peer.id != configuration.identity.id else {
      throw AcornryError.protocolViolation("refusing self connection")
    }
    try Task.checkCancellation()
    guard lifecycle == .starting || lifecycle == .running else {
      throw AcornryError.operationCancelled
    }
    let peer = AcornryPeer(
      id: hello.peer.id,
      displayName: hello.peer.displayName,
      transport: await framed.transportKind,
      discoveryID: discoveryID,
      lastSeenAt: Date())
    peers[peer.id] = peer
    if let discoveryID { peerDiscovery[peer.id] = discoveryID }
    emit(.peerIdentified(peer))
    return peer
  }

  private func performSend(
    _ prepared: AcornryPreparedTransfer,
    to discoveryID: AcornryDiscoveryID,
    expectedPeerID: AcornryPeerID?
  ) async throws -> AcornryTransferReceipt {
    let transferID = prepared.manifest.transferID
    try Task.checkCancellation()
    let transport = try transport(for: discoveryID)
    let channel = try await transport.connect(to: discoveryID)
    let framed = makeFramedConnection(channel)
    activeOutgoingConnections[transferID] = framed
    let peer: AcornryPeer
    do {
      peer = try await handshake(framed, discoveryID: discoveryID)
      try Task.checkCancellation()
      guard expectedPeerID == nil || expectedPeerID == peer.id else {
        throw AcornryError.transferConflict(transferID)
      }
    } catch {
      await framed.close()
      if Task.isCancelled || error is CancellationError { throw AcornryError.operationCancelled }
      throw error
    }
    // Session errors already distinguish pre-dispatch cancellation from unknown outcome.
    return try await makeOutgoingSession().run(prepared, to: peer, framed: framed)
  }

  private func receive(
    offer: AcornryOffer, from peer: AcornryPeer,
    over channel: any AcornryByteConnection, framed: AcornryFramedConnection
  ) async throws {
    let manifest = offer.manifest
    let transferID = manifest.transferID
    guard manifest.sender.id == peer.id, manifest.sender.displayName == peer.displayName else {
      throw AcornryError.protocolViolation("offer sender does not match handshake identity")
    }
    try manifest.validate(against: configuration.limits)
    // Reserve before the first store await, including idempotent readback and approval.
    guard !isTransferActive(transferID) else {
      try await framed.send(
        .protocolError,
        AcornryProtocolErrorPayload(
          code: "transfer_conflict", detail: "transfer id is already active"))
      throw AcornryError.transferConflict(transferID)
    }
    activeIncomingConnections[transferID] = channel
    defer {
      activeIncomingConnections.removeValue(forKey: transferID)
      removeIncomingOffer(transferID)
      // A terminal receipt can be observed while its connection still owns this
      // ID. Refresh only after removing that reservation, including error paths.
      receiveRevision = UUID()
      for observer in storageObservers.values {
        observer.yield(.init(event: nil, receiveRevision: receiveRevision))
      }
    }
    try await makeIncomingSession().run(manifest: manifest, from: peer, over: channel, framed: framed)
  }

  private func makeOutgoingSession() -> AcornryOutgoingTransferSession {
    AcornryOutgoingTransferSession(configuration: configuration, journal: journal) { [self] event in
      await applySessionEvent(event)
    }
  }

  private func makeIncomingSession() -> AcornryIncomingTransferSession {
    AcornryIncomingTransferSession(
      configuration: configuration, receiveStore: receiveStore, fileStore: fileStore,
      journal: journal, approvals: approvals
    ) { [self] event in
      await applySessionEvent(event)
    }
  }

  /// Sessions report effects; only this actor mutates the authoritative observation state.
  private func applySessionEvent(_ event: AcornryTransferSessionEvent) {
    switch event {
    case .progress(let value): updateProgress(value)
    case .phase(let id, let phase): setProgressPhase(id, phase)
    case .outgoingStarted(let id, let peerID):
      setProgressPeer(id, peerID)
      setProgressPhase(id, .awaitingApproval)
    case .offer(let offer, let initialProgress):
      incomingOffers[offer.id] = offer
      updateProgress(initialProgress)
      emit(.incomingOffer(offer))
    case .removeOffer(let id): removeIncomingOffer(id)
    case .received(let receipt, let peerID, let totalBytes):
      setIncomingTerminal(receipt, peerID: peerID, totalBytes: totalBytes)
      emit(.transferCompleted(receipt))
    case .receiptDeliveryFailed(let id, let detail): emit(.receiptDeliveryFailed(id, detail))
    case .failed(let id, let detail): emit(.transferFailed(id, detail))
    }
  }

  private func removeIncomingOffer(_ id: AcornryTransferID) {
    if incomingOffers.removeValue(forKey: id) != nil { emit(.incomingOfferRemoved(id)) }
  }

  // MARK: - State helpers

  private func transport(for discoveryID: AcornryDiscoveryID) throws -> any AcornryTransport {
    guard let kind = discoveryTransport[discoveryID], discoveries[discoveryID] != nil else {
      throw AcornryError.discoveryNotFound(discoveryID)
    }
    guard let transport = transports.first(where: { $0.kind == kind }) else {
      throw AcornryError.transportUnavailable(kind, "transport adapter is not running")
    }
    return transport
  }

  private func updateProgress(_ value: AcornryTransferProgress) {
    emit(.transferProgress(progress.update(value)))
  }

  private func setProgressPhase(_ id: AcornryTransferID, _ phase: AcornryTransferPhase) {
    if let value = progress.setPhase(id, phase) { emit(.transferProgress(value)) }
  }

  private func setProgressPeer(_ id: AcornryTransferID, _ peerID: AcornryPeerID) {
    if let value = progress.setPeer(id, peerID) { emit(.transferProgress(value)) }
  }

  private func setTerminalOutgoing(_ receipt: AcornryTransferReceipt) {
    if let value = progress.completeOutgoing(receipt) { emit(.transferProgress(value)) }
  }

  private func setIncomingTerminal(_ receipt: AcornryTransferReceipt, peerID: AcornryPeerID, totalBytes: Int64) {
    emit(.transferProgress(progress.completeIncoming(receipt, peerID: peerID, totalBytes: totalBytes)))
  }
}
