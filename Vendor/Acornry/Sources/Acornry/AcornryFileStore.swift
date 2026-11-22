import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The sole authority for durable received files. It never overwrites an unrelated destination.
public actor AcornryFileStore {
  public nonisolated let rootURL: URL
  private let lease: AcornryRootLease

  public init(rootURL: URL) throws {
    guard rootURL.isFileURL, rootURL.standardizedFileURL.path != "/" else {
      throw AcornryError.invalidConfiguration("a dedicated destination root is required")
    }
    self.rootURL = rootURL.standardizedFileURL
    self.lease = try AcornryRootLease(root: self.rootURL)
  }

  package func completedReceipt(for manifest: AcornryTransferManifest) throws
    -> AcornryImportReceipt?
  {
    guard
      let receipt = try receipt(
        for: manifest.transferID, expectedManifestDigest: manifest.digestSHA256())
    else { return nil }
    return receipt.state == .completed ? receipt : nil
  }

  package func receipt(
    for transferID: AcornryTransferID,
    expectedManifestDigest: String? = nil
  ) throws -> AcornryImportReceipt? {
    let batch = try batchRoot(transferID)
    guard FileManager.default.fileExists(atPath: batch.path) else { return nil }
    try AcornryPath.requireDirectory(batch)
    let manifest = try readManifest(batch)
    guard manifest.transferID == transferID else { throw AcornryError.transferConflict(transferID) }
    if let expectedManifestDigest, try manifest.digestSHA256() != expectedManifestDigest {
      throw AcornryError.transferConflict(transferID)
    }
    return try buildReceipt(
      manifest: manifest, batch: batch, stagingRemoved: false, cleanupError: nil)
  }

  package func transferReceipt(
    for transferID: AcornryTransferID,
    expectedManifestDigest: String,
    requestingPeerID: AcornryPeerID
  ) throws -> AcornryTransferReceipt? {
    let batch = try batchRoot(transferID)
    guard FileManager.default.fileExists(atPath: batch.path) else { return nil }
    try AcornryPath.requireDirectory(batch)
    let manifest = try readManifest(batch)
    guard manifest.transferID == transferID, manifest.sender.id == requestingPeerID,
      try manifest.digestSHA256() == expectedManifestDigest
    else {
      throw AcornryError.transferConflict(transferID)
    }
    let local = try buildReceipt(
      manifest: manifest, batch: batch, stagingRemoved: false, cleanupError: nil)
    return try AcornryTransferReceipt(local: local, manifest: manifest)
  }

  package func commit(_ staged: AcornryStagedTransfer) throws -> AcornryImportReceipt {
    try Task.checkCancellation()
    let manifest = staged.manifest
    let batch = try batchRoot(manifest.transferID)
    try AcornryPath.ensureDirectory(batch)
    try prepareManifest(manifest, in: batch)
    let incoming = batch.appendingPathComponent(".incoming", isDirectory: true)
    try AcornryPath.ensureDirectory(incoming)
    try clearInternalIncoming(incoming)

    var results: [AcornryFileResult] = []
    results.reserveCapacity(manifest.files.count)
    for entry in manifest.files {
      do {
        results.append(try save(entry, staged: staged, batch: batch, incoming: incoming))
      } catch {
        results.append(
          .init(relativePath: entry.relativePath, outcome: .failed(String(describing: error))))
      }
    }

    let state: AcornryOperationState =
      results.allSatisfy { $0.savedFile != nil } ? .completed : .partial
    var stagingRemoved = false
    var cleanupError: String?
    if state == .completed {
      do {
        try FileManager.default.removeItem(at: staged.rootURL)
        stagingRemoved = true
      } catch {
        cleanupError = String(describing: error)
      }
    }
    return .init(
      transferID: manifest.transferID,
      displayName: manifest.displayName,
      state: state,
      files: results,
      stagingRemoved: stagingRemoved,
      cleanupError: cleanupError)
  }

  /// Reconstructed receipts prove destination bytes, not whether another root was cleaned.
  public func savedTransfers() throws -> [AcornryImportReceipt] {
    try inspect(batches(in: rootURL), isArchived: false).receipts
  }

  /// Reversible retention. Archived bytes still prove receipts for the original
  /// sender, so freeing the active inbox does not turn delivery into "not saved".
  public func archivedTransfers() throws -> [AcornryImportReceipt] {
    let folder = archiveRoot
    guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
    try AcornryPath.requireDirectory(folder)
    return try inspect(batches(in: folder), isArchived: true).receipts
  }

  /// A missing destination manifest is observable as pending only when retained
  /// staging identifies it. Actual payload occupancy remains separate from a receipt.
  package func receivedInventory(pendingImports: [AcornryPendingImport]) throws -> AcornryReceiveInventory {
    var recovering: [AcornryTransferID: AcornryTransferManifest] = [:]
    var observed = Set<AcornryTransferID>()
    for pending in pendingImports {
      guard observed.insert(pending.transferID).inserted else { throw AcornryError.transferConflict(pending.transferID) }
      if case .ready(let manifest) = pending.state {
        guard manifest.transferID == pending.transferID else { throw AcornryError.transferConflict(pending.transferID) }
        recovering[pending.transferID] = manifest
      }
    }
    let activeBatches = try batches(in: rootURL)
    let archivedBatches: [URL]
    if FileManager.default.fileExists(atPath: archiveRoot.path) {
      try AcornryPath.requireDirectory(archiveRoot)
      archivedBatches = try batches(in: archiveRoot)
    } else { archivedBatches = [] }
    let duplicates = transferIDs(in: activeBatches).intersection(transferIDs(in: archivedBatches))
    if let duplicate = duplicates.sorted(by: { $0.description < $1.description }).first {
      throw AcornryError.transferConflict(duplicate)
    }
    let active = try inspect(activeBatches, isArchived: false, recovering: recovering)
    let archived = try inspect(archivedBatches, isArchived: true, recovering: recovering)
    let pending = pendingImports.map { observation in
      AcornryPendingImport(transferID: observation.transferID, state: observation.state,
        destinationUsage: active.unpublished[observation.transferID] ?? archived.unpublished[observation.transferID])
    }
    return AcornryReceiveInventory(active: active.receipts, archived: archived.receipts, pendingImports: pending)
  }

  @discardableResult public func archive(_ transferID: AcornryTransferID) throws -> AcornryImportReceipt {
    try moveBatch(transferID, toArchive: true)
  }

  @discardableResult public func restore(_ transferID: AcornryTransferID) throws -> AcornryImportReceipt {
    try moveBatch(transferID, toArchive: false)
  }

  private var archiveRoot: URL { rootURL.appendingPathComponent(".archived", isDirectory: true) }

  private func moveBatch(_ id: AcornryTransferID, toArchive: Bool) throws -> AcornryImportReceipt {
    try Task.checkCancellation()
    let active = rootURL.appendingPathComponent(id.description, isDirectory: true)
    let archived = archiveRoot.appendingPathComponent(id.description, isDirectory: true)
    let source = toArchive ? active : archived
    let target = toArchive ? archived : active
    try AcornryPath.verifyNoSymlinks(from: rootURL, to: source)
    try AcornryPath.requireDirectory(source)
    let manifest = try readManifest(source)
    guard manifest.transferID == id else { throw AcornryError.transferConflict(id) }
    let original = try buildReceipt(manifest: manifest, batch: source, stagingRemoved: false, cleanupError: nil)
    guard original.state == .completed else {
      throw AcornryError.invalidState("only fully saved transfers can move to or from archive")
    }
    guard !FileManager.default.fileExists(atPath: target.path) else { throw AcornryError.transferConflict(id) }
    if toArchive { try AcornryPath.ensureDirectory(archiveRoot) }
    try FileManager.default.moveItem(at: source, to: target)
    return try buildReceipt(manifest: manifest, batch: target, stagingRemoved: false, cleanupError: nil)
  }

  private struct DestinationInventory {
    let receipts: [AcornryImportReceipt]
    let unpublished: [AcornryTransferID: AcornryPendingImport.DestinationUsage]
  }

  private func batches(in folder: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func transferIDs(in batches: [URL]) -> Set<AcornryTransferID> {
    Set(batches.compactMap { batch in
      UUID(uuidString: batch.lastPathComponent).map { AcornryTransferID(rawValue: $0) }
    })
  }

  private func inspect(_ batches: [URL], isArchived: Bool,
    recovering: [AcornryTransferID: AcornryTransferManifest] = [:]
  ) throws -> DestinationInventory {
    var receipts: [AcornryImportReceipt] = []
    var unpublished: [AcornryTransferID: AcornryPendingImport.DestinationUsage] = [:]
    for batch in batches {
      try AcornryPath.requireDirectory(batch)
      // A failed manifest publication is still a pending import, not a
      // committed receipt. Only verified staging can identify that case.
      if let uuid = UUID(uuidString: batch.lastPathComponent) {
        let id = AcornryTransferID(rawValue: uuid)
        if batch.lastPathComponent == id.description, let manifest = recovering[id], try manifestIsAbsent(in: batch) {
          unpublished[id] = try destinationUsage(for: manifest, in: batch, isArchived: isArchived)
          continue
        }
      }
      let manifest = try readManifest(batch)
      guard batch.lastPathComponent == manifest.transferID.description else {
        throw AcornryError.integrityMismatch(batch.path)
      }
      receipts.append(
        try buildReceipt(manifest: manifest, batch: batch, stagingRemoved: false, cleanupError: nil)
      )
    }
    return DestinationInventory(receipts: receipts, unpublished: unpublished)
  }

  private func manifestIsAbsent(in batch: URL) throws -> Bool {
    var info = stat()
    if lstat(batch.appendingPathComponent("manifest.json").path, &info) == 0 { return false }
    guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return true
  }

  private func destinationUsage(for manifest: AcornryTransferManifest, in batch: URL,
    isArchived: Bool
  ) throws -> AcornryPendingImport.DestinationUsage {
    var byteCount: Int64 = 0
    var hasFiles = false
    for entry in manifest.files {
      try Task.checkCancellation()
      guard let size = try payloadFileSize(entry.relativePath, in: batch) else { continue }
      hasFiles = true
      let (total, overflow) = byteCount.addingReportingOverflow(size)
      guard !overflow else { throw AcornryError.resourceLimitExceeded("unpublished destination byte count overflow") }
      byteCount = total
    }
    return .init(isArchived: isArchived, byteCount: byteCount, hasFiles: hasFiles)
  }

  private func payloadFileSize(_ relativePath: String, in batch: URL) throws -> Int64? {
    let path = try AcornryPath.validate("payload/" + relativePath)
    let components = path.split(separator: "/").map(String.init)
    var descriptor = open(batch.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    for component in components.dropLast() {
      let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      if next < 0, errno == ENOENT { return nil }
      guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      close(descriptor)
      descriptor = next
    }
    var info = stat()
    guard let name = components.last else { throw AcornryError.invalidPath(relativePath) }
    if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      return nil
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
      throw AcornryError.invalidPath("unpublished destination payload must be a regular file")
    }
    return Int64(info.st_size)
  }

  private func save(
    _ entry: AcornryManifestFile,
    staged: AcornryStagedTransfer,
    batch: URL,
    incoming: URL
  ) throws -> AcornryFileResult {
    let payloadRoot = batch.appendingPathComponent("payload", isDirectory: true)
    try AcornryPath.ensureDirectory(payloadRoot)
    let destination = try AcornryPath.safeDescendant(entry.relativePath, under: payloadRoot)
    try AcornryPath.createSafeParentDirectories(for: destination, under: payloadRoot)

    if FileManager.default.fileExists(atPath: destination.path) {
      try AcornryPath.verifyFile(destination, expected: entry, under: batch)
      return savedResult(entry, at: destination, alreadyPresent: true)
    }

    let source = try AcornryPath.safeDescendant(entry.relativePath, under: staged.payloadRootURL)
    try AcornryPath.verifyFile(source, expected: entry, under: staged.rootURL)
    let temporary = incoming.appendingPathComponent(UUID().uuidString)
    do {
      try FileManager.default.copyItem(at: source, to: temporary)
      try AcornryPath.verifyFile(temporary, expected: entry, under: batch)
      let handle = try FileHandle(forWritingTo: temporary)
      try AcornryPersistence.synchronizeAndClose(handle)
      try FileManager.default.linkItem(at: temporary, to: destination)
      try FileManager.default.removeItem(at: temporary)
      try AcornryPath.verifyFile(destination, expected: entry, under: batch)
      return savedResult(entry, at: destination, alreadyPresent: false)
    } catch {
      do { try AcornryPath.removeIfPresent(temporary) } catch let cleanup {
        throw AcornryError.destinationConflict("save failed: \(error); cleanup failed: \(cleanup)")
      }
      throw error
    }
  }

  private func savedResult(_ entry: AcornryManifestFile, at url: URL, alreadyPresent: Bool)
    -> AcornryFileResult
  {
    .init(
      relativePath: entry.relativePath,
      outcome: .saved(
        .init(
          relativePath: entry.relativePath, fileURL: url, byteCount: entry.byteCount,
          checksumSHA256: entry.checksumSHA256),
        alreadyPresent: alreadyPresent))
  }

  private func buildReceipt(
    manifest: AcornryTransferManifest,
    batch: URL,
    stagingRemoved: Bool,
    cleanupError: String?
  ) throws -> AcornryImportReceipt {
    let payloadRoot = batch.appendingPathComponent("payload", isDirectory: true)
    let results = manifest.files.map { entry -> AcornryFileResult in
      do {
        let url = try AcornryPath.safeDescendant(entry.relativePath, under: payloadRoot)
        try AcornryPath.verifyFile(url, expected: entry, under: batch)
        return savedResult(entry, at: url, alreadyPresent: true)
      } catch {
        return .init(relativePath: entry.relativePath, outcome: .failed(String(describing: error)))
      }
    }
    return .init(
      transferID: manifest.transferID,
      displayName: manifest.displayName,
      state: results.allSatisfy { $0.savedFile != nil } ? .completed : .partial,
      files: results,
      stagingRemoved: stagingRemoved,
      cleanupError: cleanupError)
  }

  private func prepareManifest(_ manifest: AcornryTransferManifest, in batch: URL) throws {
    let url = batch.appendingPathComponent("manifest.json")
    let data = try manifest.canonicalData()
    if FileManager.default.fileExists(atPath: url.path) {
      try AcornryPath.requireRegularFile(url)
      guard try Data(contentsOf: url) == data else {
        throw AcornryError.transferConflict(manifest.transferID)
      }
      return
    }
    try AcornryPersistence.write(data, to: url)
  }

  private func readManifest(_ batch: URL) throws -> AcornryTransferManifest {
    let url = batch.appendingPathComponent("manifest.json")
    try AcornryPath.requireRegularFile(url)
    return try JSONDecoder().decode(AcornryTransferManifest.self, from: Data(contentsOf: url))
  }

  private func clearInternalIncoming(_ incoming: URL) throws {
    for child in try FileManager.default.contentsOfDirectory(
      at: incoming, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
    {
      let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw AcornryError.invalidPath(child.path) }
      try FileManager.default.removeItem(at: child)
    }
  }

  private func batchRoot(_ id: AcornryTransferID) throws -> URL {
    let active = rootURL.appendingPathComponent(id.description, isDirectory: true)
    let archived = archiveRoot.appendingPathComponent(id.description, isDirectory: true)
    if FileManager.default.fileExists(atPath: archived.path) {
      guard !FileManager.default.fileExists(atPath: active.path) else { throw AcornryError.transferConflict(id) }
      try AcornryPath.verifyNoSymlinks(from: rootURL, to: archived)
      return archived
    }
    return active
  }
}
