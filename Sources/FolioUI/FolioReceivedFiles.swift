import FolioNearbyTransport
import Foundation

/// One inventory of transport receipts, separate from connection/job lifetime.
/// Acornry retains ownership of the saved bytes and receipt persistence.
struct FolioReceivedFiles {
  private static let maximumActiveTransfers = 64
  private static let maximumActiveBytes: Int64 = 1024 * 1024 * 1024

  let active: [AcornryImportReceipt]
  let archived: [AcornryImportReceipt]
  private let retainedImports: [AcornryPendingImport]
  var visibleActive: [AcornryImportReceipt] { Array(active.suffix(Self.maximumActiveTransfers)) }
  var pendingImports: [AcornryPendingImport] {
    let published = Set((active + archived).map(\.transferID))
    return retainedImports.filter {
      if case .needsReview = $0.state { return true }
      return !published.contains($0.transferID)
    }
  }

  init(active: [AcornryImportReceipt] = [], archived: [AcornryImportReceipt] = [],
    pendingImports: [AcornryPendingImport] = []
  ) {
    self.active = active
    self.archived = archived
    retainedImports = pendingImports
  }

  @MainActor
  static func read(from nearby: AcornryNearby) async throws -> Self {
    let inventory = try await nearby.receivedInventory()
    return Self(active: inventory.active, archived: inventory.archived, pendingImports: inventory.pendingImports)
  }

  func requireCapacity(for offer: AcornryIncomingOffer, freeBytes: Int64) throws {
    try requireSlot(bytes: offer.manifest.totalBytes)
    try Self.requireFreeSpace(offer.manifest.totalBytes, freeBytes: freeBytes)
  }

  func requireRestoration(of id: AcornryTransferID) throws {
    guard let restoring = archived.first(where: { $0.transferID == id }) else {
      throw FolioTransferStorage.failure("받은 파일 한도가 찼습니다. 다른 완료 파일을 보관함으로 옮긴 뒤 복원하세요.")
    }
    try requireSlot(bytes: Self.storedBytes(in: [restoring]))
  }

  /// Reserve the missing bytes without counting a partial destination twice.
  /// Observation is not write authority: retryImport revalidates the staging.
  func requireRetry(of id: AcornryTransferID, freeBytes: Int64) throws {
    guard let pending = retainedImports.first(where: { $0.transferID == id }),
      case .ready(let manifest) = pending.state else {
      throw FolioTransferStorage.failure("수신 원본을 확인할 수 없습니다. 기존 파일과 복구 자료는 보존했습니다.")
    }
    let current = (active + archived).first { $0.transferID == id }
    if !archived.contains(where: { $0.transferID == id }), pending.destinationUsage?.isArchived != true {
      try requireSlot(bytes: manifest.totalBytes, excluding: id)
    }
    let saved = current.map { Self.storedBytes(in: [$0]) } ?? pending.destinationUsage?.byteCount ?? 0
    try Self.requireFreeSpace(max(0, manifest.totalBytes - saved), freeBytes: freeBytes)
  }

  func canRetry(_ id: AcornryTransferID) -> Bool {
    retainedImports.contains { item in
      if item.transferID == id, case .ready = item.state { return true }
      return false
    }
  }

  func file(_ file: AcornrySavedFile, transferID: AcornryTransferID) -> URL? {
    (active + archived).first(where: { $0.transferID == transferID })?.savedFiles.first(where: { $0 == file })?.fileURL
  }

  private static func storedBytes(in receipts: [AcornryImportReceipt]) -> Int64 {
    receipts.flatMap(\.savedFiles).reduce(Int64(0)) { $0 + $1.byteCount }
  }

  private func requireSlot(bytes: Int64, excluding id: AcornryTransferID? = nil) throws {
    let others = active.filter { $0.transferID != id }
    var count = others.count
    var reservedBytes = Self.storedBytes(in: others)
    let published = Set(active.map(\.transferID))
    for pending in retainedImports where pending.transferID != id && !published.contains(pending.transferID) {
      guard let usage = pending.destinationUsage, !usage.isArchived, usage.hasFiles else { continue }
      count += 1
      let (total, overflow) = reservedBytes.addingReportingOverflow(usage.byteCount)
      guard !overflow else { throw Self.capacityError }
      reservedBytes = total
    }
    let (total, overflow) = reservedBytes.addingReportingOverflow(bytes)
    guard count < Self.maximumActiveTransfers, !overflow, total <= Self.maximumActiveBytes else {
      throw Self.capacityError
    }
  }

  private static func requireFreeSpace(_ bytes: Int64, freeBytes: Int64) throws {
    let margin: Int64 = 16 * 1024 * 1024
    guard freeBytes > margin, bytes < freeBytes - margin else { throw capacityError }
  }

  private static var capacityError: NSError {
    FolioTransferStorage.failure("받은 파일 보관 한도 또는 저장 공간이 부족합니다. 기존 파일과 수신 복구 자료는 보존했습니다.")
  }
}
