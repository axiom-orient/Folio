import FolioNearbyTransport
import Foundation
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One application-owned Acornry session. UI is a projection and never writes
/// its inbox directly. Delivery and wiki import keep separate receipts.
@MainActor @Observable final class FolioNearbyModel {
  private enum Work {
    case preparing(Task<URL, Error>)
    case sending(Task<Void, Never>)
    case request(Task<Void, Never>)

    var canCancel: Bool {
      switch self { case .preparing, .sending: true; case .request: false }
    }

    func cancel() {
      switch self {
      case .preparing(let task): task.cancel()
      case .sending(let task): task.cancel()
      case .request: break
      }
    }

    @MainActor func drain() async {
      switch self {
      case .preparing(let task): _ = await task.result
      case .sending(let task): await task.value
      case .request(let task): await task.value
      }
    }
  }

  private(set) var snapshot: AcornrySnapshot?
  private var files = FolioReceivedFiles()
  var received: [AcornryImportReceipt] { files.visibleActive }
  var archived: [AcornryImportReceipt] { files.archived }
  var pendingImports: [AcornryPendingImport] { files.pendingImports }
  func canRetryStorage(_ id: AcornryTransferID) -> Bool { files.canRetry(id) }
  private var work: Work?
  var isWorking: Bool { work != nil }
  private(set) var isStarting = false
  var message: String?
  private(set) var connectionGuidance: String?
  private var key: FolioConnectionKey?
  private var nearby: AcornryNearby?
  private var configuredFingerprint: String?
  private var observation: Task<Void, Never>?
  private var stopping: Task<Void, Never>?
  private var generation = 0
  private var latestInventoryRequest: UUID?
  private struct InventoryLoad {
    let inventory: FolioReceivedFiles
    let didPublish: Bool
  }
  private let enabled: Bool
  private var accessAllowed = true
  private var admitted: Bool { enabled && accessAllowed }
  private var pendingOutgoingObservation: AcornryTransferID?
  var isRunning: Bool { snapshot?.lifecycle == .running }
  var needsDeliveryReview: Bool { pendingOutgoingObservation != nil || snapshot?.unknownOutgoingOperations.isEmpty == false }
  var canSend: Bool { admitted && stopping == nil && isRunning && !isWorking && !needsDeliveryReview && snapshot?.unknownOutgoingOperations.isEmpty == true }

  /// Deployment capability and temporary protected-data access are independent.
  /// A disabled instance can never regain admission through a lifecycle callback.
  init(enabled: Bool = true) { self.enabled = enabled }

  /// Preparation belongs to app foreground lifetime, not a setup screen.
  func ready() async {
    if let stopping { await stopping.value }
    guard admitted else { return }
    if isRunning, let nearby {
      await refresh(nearby, generation: generation, reloadFiles: true)
      return
    }
    await start()
  }

  private func configuredService(_ key: FolioConnectionKey) throws -> AcornryNearby {
    guard admitted else { throw FolioTransferStorage.failure("기기 전송을 사용할 수 없습니다.") }
    if let nearby {
      guard configuredFingerprint == key.fingerprint else { throw FolioTransferStorage.failure("연결키가 변경되었습니다. 기존 전송 기록을 보존한 채 Folio를 다시 열어 주세요.") }
      return nearby
    }
    let root = try FolioTransferStorage.root; try FolioTransferStorage.directory(root)
    let staging = root.appendingPathComponent("Staging", isDirectory: true)
    let inbox = root.appendingPathComponent("Received", isDirectory: true)
    try FolioTransferStorage.directory(staging); try FolioTransferStorage.directory(inbox)
    #if os(iOS)
    let name = "Folio · " + UIDevice.current.name
    #else
    let name = "Folio · " + (Host.current().localizedName ?? "Mac")
    #endif
    let value = try AcornryNearby(configuration: .init(
      identity: .init(id: .init(rawValue: FolioTransferStorage.peerID()), displayName: String(name.prefix(40))),
      stagingRootURL: staging, destinationRootURL: inbox, incomingPolicy: .requireApproval,
      limits: .init(maxFileCount: 1, maxTotalBytes: Int64(FolioTransferStorage.maximumBytes),
        maxSingleFileBytes: Int64(FolioTransferStorage.maximumBytes)),
      bonjourSecurity: .preSharedKey(.init(data: key.key)), wifiAwareMode: .disabled,
      serviceType: "_folio-send._tcp", maxIncomingConnections: 1))
    nearby = value; configuredFingerprint = key.fingerprint; return value
  }

  func loadConnection() {
    guard admitted else { return }
    do {
      key = try FolioConnectionKeychain.read()
      connectionGuidance = nil
    }
    catch { key = nil; connectionGuidance = error.localizedDescription }
  }
  func start() async {
    guard admitted, stopping == nil, !isStarting, !isRunning else { return }
    loadConnection()
    #if os(macOS)
    if key == nil {
      do {
        let generated = FolioConnectionKey.generate()
        try FolioConnectionKeychain.install(generated)
        loadConnection()
      } catch { connectionGuidance = error.localizedDescription; return }
    }
    #endif
    guard let key else {
      if connectionGuidance == nil {
        connectionGuidance = "Mac에서 Folio를 한 번 열어 주세요. 같은 Apple 계정의 iCloud 키체인으로 연결합니다."
      }
      return
    }
    isStarting = true; generation += 1; let current = generation
    defer { if generation == current { isStarting = false } }
    do {
      let nearby = try configuredService(key)
      // Saved files remain usable even if local-network access is unavailable.
      await refresh(nearby, generation: current, reloadFiles: true)
      guard admitted, current == generation else { return }
      let stream = await nearby.storageObservations()
      guard admitted, current == generation else { await nearby.stop(); return }
      observation?.cancel()
      observation = Task { [weak self] in
        var observedReceiveRevision: UUID?
        for await update in stream {
          guard !Task.isCancelled, let self, self.admitted, self.generation == current else { break }
          var reloadFiles = observedReceiveRevision != update.receiveRevision
          if let event = update.event {
            switch event {
            // Identity-only handshakes close before an offer and have no transfer
            // ID. Do not present that normal close as a failed file delivery.
            // Errors after an offer retain their ID and remain visible.
            case .transferFailed(nil, "connectionClosed"): break
            case .transferFailed(_, let detail): self.message = "전송을 완료하지 못했습니다. " + detail
            case .receiptDeliveryFailed: self.message = "파일은 이 기기에 저장됐지만 상대가 결과를 받지 못했습니다. 상대에서 결과 확인을 사용하세요."
            default: break
            }
            switch event {
            case .transferCompleted: reloadFiles = true
            case .transferFailed(let id, _): reloadFiles = reloadFiles || id != nil
            default: break
            }
          }
          if await self.refresh(nearby, generation: current, reloadFiles: reloadFiles), reloadFiles {
            // A failed or superseded read must not consume the release revision.
            observedReceiveRevision = update.receiveRevision
          }
        }
      }
      _ = try await nearby.start()
      guard admitted, current == generation else { await nearby.stop(); return }
      await refresh(nearby, generation: current)
    } catch {
      guard generation == current else { return }
      message = "전송을 시작하지 못했습니다. 로컬 네트워크 접근을 확인해 주세요. " + error.localizedDescription
      observation?.cancel(); observation = nil
    }
  }

  func stop() async {
    guard enabled else { return }
    if let stopping { await stopping.value; return }
    generation += 1; isStarting = false
    let old = nearby; let watching = observation; let activeWork = work
    watching?.cancel(); observation = nil; activeWork?.cancel()
    let task = Task {
      defer { stopping = nil }
      await old?.stop()
      await watching?.value
      await activeWork?.drain()
      if admitted, let old {
        do { snapshot = try await old.snapshot() }
        catch { snapshot = nil; message = "전송은 중지했지만 결과 기록을 읽지 못했습니다. " + error.localizedDescription }
      } else { snapshot = nil }
      nearby = nil; configuredFingerprint = nil; key = nil; work = nil
    }
    stopping = task
    await task.value
  }
  func restrict() {
    accessAllowed = false; generation += 1; key = nil
    observation?.cancel(); work?.cancel()
  }
  func allowAccess() {
    guard enabled else { return }
    accessAllowed = true
    loadConnection()
  }

  func prepareFile(_ url: URL) async throws -> URL {
    guard admitted, stopping == nil, !isWorking else { throw FolioTransferStorage.failure("진행 중인 전송이 끝나면 다시 보내 주세요.") }
    let current = generation
    defer { finishWork(generation: current) }
    let job = Task { try await FolioTransferStorage.copyForSending(url) }
    work = .preparing(job)
    let copy = try await job.value
    guard admitted, current == generation, !Task.isCancelled else {
      try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
      throw CancellationError()
    }
    message = nil
    return copy
  }

  @discardableResult func send(file: URL, title: String, to discovery: AcornryDiscovery) -> Bool {
    guard admitted, canSend, let nearby else { return false }
    let current = generation
    // Selecting the destination is the send action. Identification and transport
    // preparation do not require a second confirmation or create a second ID.
    work = .sending(Task { [weak self] in
      defer {
        self?.finishWork(generation: current)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
      }
      do {
        let peer = try await nearby.identify(discovery.id)
        guard let self, self.admitted, self.generation == current, !Task.isCancelled else { return }
        let receipt = try await nearby.send(files: [.init(fileURL: file)], to: peer.id,
          transferID: AcornryTransferID(), displayName: title)
        guard self.admitted, self.generation == current else { return }
        self.message = receipt.state == .completed ? "보냈습니다. 상대 기기에 저장되었습니다." : "일부 파일만 저장되었습니다."
      } catch AcornryError.outcomeUnknown(let id) {
        guard let self, self.generation == current else { return }
        self.pendingOutgoingObservation = id
        self.message = "상대 기기의 저장 결과를 확인해야 합니다. 받은 파일에서 전송 확인을 사용하세요."
      } catch {
        guard let self, self.generation == current else { return }
        self.message = "보내기를 완료하지 못했습니다. " + error.localizedDescription
      }
      guard let self, self.generation == current else { return }
      await self.refresh(nearby, generation: current)
    })
    return true
  }
  var activeTransfers: [AcornryTransferProgress] {
    (snapshot?.transfers ?? []).filter { [.preparing, .awaitingApproval, .transferring, .committing].contains($0.phase) }
  }
  func cancelPreparation() {
    guard enabled else { return }
    work?.cancel()
  }
  var canCancelPreparation: Bool { work?.canCancel == true }

  private func finishWork(generation current: Int) {
    if current == generation { work = nil }
  }

  /// Keep the caller's whole request registered, including receipt handling and
  /// inventory refresh after the transport's own operation has finished.
  private func performRequest(_ operation: @escaping @MainActor (Int) async -> Void) async {
    guard admitted, !isWorking, stopping == nil else { return }
    let current = generation
    let task = Task {
      guard !Task.isCancelled, admitted, current == generation, stopping == nil else { return }
      await operation(current)
    }
    work = .request(task)
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    finishWork(generation: current)
  }
  func accept(_ offer: AcornryIncomingOffer) async {
    guard admitted, isRunning, !isWorking, let nearby else { return }
    let current = generation
    do {
      let inventory = try await FolioReceivedFiles.read(from: nearby)
      let free = (try FileManager.default.attributesOfFileSystem(forPath: FolioTransferStorage.root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
      try inventory.requireCapacity(for: offer, freeBytes: free)
      guard admitted, current == generation, !isWorking else { return }
      try await nearby.accept(offer.id)
    } catch { if current == generation { message = error.localizedDescription } }
  }
  func reject(_ id: AcornryTransferID) async {
    guard enabled else { return }
    do { try await nearby?.reject(id, reason: "사용자가 수신을 거절했습니다.") }
    catch { message = error.localizedDescription }
  }
  func cancel(_ id: AcornryTransferID) async {
    guard enabled else { return }
    do { try await nearby?.cancel(id) }
    catch { message = error.localizedDescription }
  }
  func retryStorage(_ id: AcornryTransferID) async {
    guard admitted, !isWorking, stopping == nil else { return }
    loadConnection(); guard let key else { return }
    await performRequest { [self] current in
      do {
        let nearby = try configuredService(key)
        try await requireIdleReceive(nearby)
        guard let loaded = await reloadInventory(nearby, generation: current),
          admitted, current == generation else { return }
        let inventory = loaded.inventory
        let free = (try FileManager.default.attributesOfFileSystem(forPath: FolioTransferStorage.root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        try inventory.requireRetry(of: id, freeBytes: free)
        do { _ = try await nearby.retryImport(id) }
        catch { if current == generation { message = error.localizedDescription } }
        guard admitted, current == generation else { return }
        await refresh(nearby, generation: current, reloadFiles: true)
      } catch { if current == generation { message = error.localizedDescription } }
    }
  }
  func moveReceived(_ id: AcornryTransferID, toArchive: Bool) async {
    guard admitted, !isWorking, stopping == nil else { return }
    loadConnection()
    guard let key else { return }
    await performRequest { [self] current in
      do {
        let nearby = try configuredService(key)
        if toArchive { _ = try await nearby.archiveReceived(id) }
        else {
          try await requireIdleReceive(nearby)
          let inventory = try await FolioReceivedFiles.read(from: nearby)
          try inventory.requireRestoration(of: id)
          guard admitted, current == generation else { return }
          _ = try await nearby.restoreReceived(id)
        }
        guard admitted, current == generation else { return }
        await refresh(nearby, generation: current, reloadFiles: true)
      } catch { if current == generation { message = error.localizedDescription } }
    }
  }

  /// The registered local request blocks new approval while this fresh source
  /// observation excludes an already accepted receive from the quota window.
  private func requireIdleReceive(_ nearby: AcornryNearby) async throws {
    let state = try await nearby.snapshot()
    guard !state.transfers.contains(where: {
      $0.direction == .incoming && [.awaitingApproval, .transferring, .committing].contains($0.phase)
    }) else { throw FolioTransferStorage.failure("파일 수신이 끝난 뒤 저장 재시도·복원을 실행해 주세요.") }
  }
  func reconcile(_ operation: AcornryUnknownOperation, through discovery: AcornryDiscovery) async {
    guard admitted, stopping == nil, isRunning, !isWorking, let nearby, let expected = operation.targetPeerID else { return }
    await performRequest { [self] current in
      do {
        let peer = try await nearby.identify(discovery.id)
        guard admitted, current == generation, peer.id == expected else { throw FolioTransferStorage.failure("원래 수신 기기를 선택해 주세요.") }
        let receipt = try await nearby.reconcile(operation.id, with: peer.id)
        guard admitted, current == generation else { return }
        if let receipt {
          message = receipt.state == .completed ? "상대 기기의 파일 저장 완료를 확인했습니다." : "상대 기기에서 일부 파일만 저장했습니다. 완료로 처리하지 않습니다."
          if pendingOutgoingObservation == operation.id { pendingOutgoingObservation = nil }
        } else { message = "상대에서 저장 결과를 확인하지 못했습니다. 불명 상태를 유지합니다." }
        await refresh(nearby, generation: current)
      } catch { if current == generation { message = error.localizedDescription } }
    }
  }
  func validatedFile(_ file: AcornrySavedFile, transferID: AcornryTransferID) async throws -> URL {
    guard admitted, stopping == nil else { throw FolioTransferStorage.failure("잠금을 해제하고 Folio를 다시 열어 주세요.") }
    loadConnection()
    guard let key else { throw FolioTransferStorage.failure("연결키를 읽지 못했습니다. 받은 파일은 보존됩니다.") }
    let nearby = try configuredService(key)
    let current = generation
    let inventory = try await FolioReceivedFiles.read(from: nearby)
    guard admitted, current == generation,
      let url = inventory.file(file, transferID: transferID) else {
      throw FolioTransferStorage.failure("받은 파일의 저장 결과가 변경되었습니다.")
    }
    return url
  }
  /// Both observation refresh and retry admission publish through this lane.
  /// Superseded data can still serve the registered request's quota check, but
  /// cannot replace a newer UI inventory, even if that request subsequently fails.
  private func reloadInventory(_ nearby: AcornryNearby, generation current: Int) async -> InventoryLoad? {
    guard admitted, current == generation else { return nil }
    let request = UUID()
    latestInventoryRequest = request
    do {
      let inventory = try await FolioReceivedFiles.read(from: nearby)
      guard admitted, current == generation else { return nil }
      let didPublish = request == latestInventoryRequest
      if didPublish { files = inventory }
      return InventoryLoad(inventory: inventory, didPublish: didPublish)
    } catch {
      if admitted, current == generation, request == latestInventoryRequest { reportRefreshFailure(error) }
      return nil
    }
  }

  @discardableResult
  private func refresh(_ nearby: AcornryNearby, generation current: Int, reloadFiles: Bool = false) async -> Bool {
    guard admitted, current == generation else { return false }
    do {
      let state = try await nearby.snapshot()
      if reloadFiles {
        guard let loaded = await reloadInventory(nearby, generation: current), loaded.didPublish else { return false }
      }
      guard admitted, current == generation else { return false }
      snapshot = state
      // A snapshot may have started before the send returned unknown. Only the
      // original operation's explicit reconciliation receipt releases admission.
      return true
    } catch {
      if admitted, current == generation { reportRefreshFailure(error) }
      return false
    }
  }

  private func reportRefreshFailure(_ error: any Error) {
    message = pendingOutgoingObservation != nil
      ? "전송 결과를 읽지 못했습니다. 새 전송은 보류하고 받은 파일에서 원래 전송을 확인해 주세요."
      : error.localizedDescription
  }
}
