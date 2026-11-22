import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

package struct AcornryStagedTransfer: Sendable {
  package let manifest: AcornryTransferManifest
  package let rootURL: URL
  package let payloadRootURL: URL
}

package actor AcornryReceiveStore {
  private static let maximumInventoryEntries = 4096
  private static let maximumManifestBytes = 16 * 1024 * 1024
  private static let maximumCompletionBytes = 64 * 1024
  private static let maximumInventoryMetadataBytes = 64 * 1024 * 1024
  private struct MetadataBudgetExceeded: Error {}

  private struct Completion: Codable {
    let transferID: AcornryTransferID
    let manifestDigestSHA256: String
  }
  package nonisolated let rootURL: URL
  private let lease: AcornryRootLease

  private struct ActiveFile {
    let tempURL: URL
    let handle: FileHandle
    var hasher: AcornrySHA256
    var received: Int64
  }

  private struct Context {
    let manifest: AcornryTransferManifest
    var activeFiles: [Int: ActiveFile]
    var completedFiles: Set<Int>
  }

  private var contexts: [AcornryTransferID: Context] = [:]

  package init(rootURL: URL) throws {
    self.rootURL = rootURL.standardizedFileURL
    self.lease = try AcornryRootLease(root: self.rootURL)
  }

  package func begin(_ manifest: AcornryTransferManifest, limits: AcornryResourceLimits) throws {
    try manifest.validate(against: limits)
    let id = manifest.transferID
    if let existing = contexts[id] {
      guard existing.manifest == manifest else { throw AcornryError.transferConflict(id) }
      throw AcornryError.invalidState("transfer is already receiving")
    }

    let root = transferRoot(id)
    try AcornryPath.ensureDirectory(root)
    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path)
    else {
      throw AcornryError.invalidState("finalized staging is retained; use retryImport")
    }
    let manifestURL = root.appendingPathComponent("manifest.json")
    let canonical = try manifest.canonicalData()
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      try AcornryPath.requireRegularFile(manifestURL)
      guard try Data(contentsOf: manifestURL) == canonical else {
        throw AcornryError.transferConflict(id)
      }
    } else {
      try AcornryPersistence.write(canonical, to: manifestURL)
    }

    let payload = root.appendingPathComponent("payload", isDirectory: true)
    let incoming = root.appendingPathComponent(".incoming", isDirectory: true)
    try resetDirectory(payload)
    try resetDirectory(incoming)
    contexts[id] = Context(manifest: manifest, activeFiles: [:], completedFiles: [])
  }

  package func appendChunk(
    transferID: AcornryTransferID,
    fileIndex: Int,
    offset: Int64,
    bytes: Data
  ) throws {
    guard var context = contexts[transferID] else {
      throw AcornryError.invalidState("unknown receiving transfer")
    }
    guard context.manifest.files.indices.contains(fileIndex) else {
      throw AcornryError.protocolViolation("file index out of range")
    }
    guard !context.completedFiles.contains(fileIndex) else {
      throw AcornryError.protocolViolation("chunk received after file completion")
    }
    let expected = context.manifest.files[fileIndex]
    guard offset >= 0, offset <= expected.byteCount else {
      throw AcornryError.protocolViolation("invalid chunk offset")
    }
    guard Int64(bytes.count) <= expected.byteCount - offset else {
      throw AcornryError.protocolViolation("chunk exceeds declared file size")
    }

    var active: ActiveFile
    if let current = context.activeFiles[fileIndex] {
      active = current
    } else {
      guard offset == 0 else {
        throw AcornryError.protocolViolation("first chunk offset must be zero")
      }
      let incoming = transferRoot(transferID).appendingPathComponent(".incoming", isDirectory: true)
      try AcornryPath.requireDirectory(incoming)
      let tempURL = incoming.appendingPathComponent("\(fileIndex).part")
      if FileManager.default.fileExists(atPath: tempURL.path) {
        try AcornryPath.removeIfPresent(tempURL)
      }
      guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
        throw AcornryError.invalidState("unable to create incoming file")
      }
      active = ActiveFile(
        tempURL: tempURL,
        handle: try FileHandle(forWritingTo: tempURL),
        hasher: AcornrySHA256(),
        received: 0
      )
    }

    guard offset == active.received else {
      throw AcornryError.protocolViolation(
        "non-contiguous chunk offset for \(expected.relativePath)")
    }
    // Register the handle before the write so abort owns cleanup even when the first write fails.
    context.activeFiles[fileIndex] = active
    contexts[transferID] = context
    try active.handle.write(contentsOf: bytes)
    active.hasher.update(bytes)
    active.received += Int64(bytes.count)
    context.activeFiles[fileIndex] = active
    contexts[transferID] = context
  }

  package func finishFile(_ end: AcornryFileEnd) throws {
    guard var context = contexts[end.transferID] else {
      throw AcornryError.invalidState("unknown receiving transfer")
    }
    guard context.manifest.files.indices.contains(end.fileIndex) else {
      throw AcornryError.protocolViolation("file end index out of range")
    }
    guard !context.completedFiles.contains(end.fileIndex) else {
      throw AcornryError.protocolViolation("duplicate file end")
    }
    let expected = context.manifest.files[end.fileIndex]
    guard end.byteCount == expected.byteCount,
      end.checksumSHA256.lowercased() == expected.checksumSHA256
    else { throw AcornryError.protocolViolation("file end does not match manifest") }

    var active: ActiveFile
    if let current = context.activeFiles.removeValue(forKey: end.fileIndex) {
      active = current
    } else {
      guard expected.byteCount == 0 else {
        throw AcornryError.protocolViolation("file ended without bytes")
      }
      let incoming = transferRoot(end.transferID).appendingPathComponent(
        ".incoming", isDirectory: true)
      let tempURL = incoming.appendingPathComponent("\(end.fileIndex).part")
      guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
        throw AcornryError.invalidState("unable to create empty incoming file")
      }
      active = ActiveFile(
        tempURL: tempURL, handle: try FileHandle(forWritingTo: tempURL),
        hasher: AcornrySHA256(), received: 0)
    }

    contexts[end.transferID] = context
    try AcornryPersistence.synchronizeAndClose(active.handle)
    guard active.received == expected.byteCount,
      active.hasher.finalizeHex() == expected.checksumSHA256
    else { throw AcornryError.integrityMismatch(expected.relativePath) }
    try AcornryPath.verifyFile(active.tempURL, expected: expected, under: rootURL)

    let payload = transferRoot(end.transferID).appendingPathComponent("payload", isDirectory: true)
    let target = try AcornryPath.safeDescendant(expected.relativePath, under: payload)
    try AcornryPath.createSafeParentDirectories(for: target, under: payload)
    guard !FileManager.default.fileExists(atPath: target.path) else {
      throw AcornryError.destinationConflict(expected.relativePath)
    }
    try FileManager.default.moveItem(at: active.tempURL, to: target)
    try AcornryPath.verifyFile(target, expected: expected, under: rootURL)
    context.completedFiles.insert(end.fileIndex)
    contexts[end.transferID] = context
  }

  package func finalize(_ transferID: AcornryTransferID) throws -> AcornryStagedTransfer {
    guard let context = contexts[transferID] else {
      throw AcornryError.invalidState("unknown receiving transfer")
    }
    guard context.activeFiles.isEmpty,
      context.completedFiles.count == context.manifest.files.count
    else { throw AcornryError.invalidState("transfer is incomplete") }
    let root = transferRoot(transferID)
    let payload = root.appendingPathComponent("payload", isDirectory: true)
    for entry in context.manifest.files {
      try AcornryPath.verifyFile(
        try AcornryPath.safeDescendant(entry.relativePath, under: payload), expected: entry, under: rootURL)
    }
    let completion = Completion(
      transferID: transferID, manifestDigestSHA256: try context.manifest.digestSHA256())
    try AcornryPersistence.write(
      JSONEncoder().encode(completion), to: root.appendingPathComponent("ready.json"))
    contexts.removeValue(forKey: transferID)
    return AcornryStagedTransfer(manifest: context.manifest, rootURL: root, payloadRootURL: payload)
  }

  /// Discover finalized staging without hashing payloads or changing any files.
  /// Invalid entries remain visible; only an explicit retry can authorize a commit.
  package func pendingImports(limits: AcornryResourceLimits) throws -> [AcornryPendingImport] {
    try AcornryPath.requireDirectory(rootURL)
    var enumerationError: (any Error)?
    guard let entries = FileManager.default.enumerator(
      at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
      errorHandler: { _, error in enumerationError = error; return false }
    ) else { throw AcornryError.invalidState("unable to enumerate retained staging") }
    var count = 0
    var metadataBudget = Self.maximumInventoryMetadataBytes
    var states: [AcornryTransferID: AcornryPendingImport.State] = [:]
    for case let directory as URL in entries {
      try Task.checkCancellation()
      count += 1
      guard count <= Self.maximumInventoryEntries else {
        throw AcornryError.resourceLimitExceeded("retained staging exceeds 4,096 entries")
      }
      guard let uuid = UUID(uuidString: directory.lastPathComponent) else { continue }
      let id = AcornryTransferID(rawValue: uuid)
      guard contexts[id] == nil else { continue }
      let state: AcornryPendingImport.State
      do {
        try AcornryPath.verifyNoSymlinks(from: rootURL, to: directory)
        try AcornryPath.requireDirectory(directory)
        guard try itemExists(directory.appendingPathComponent("ready.json")) else { continue }
        guard directory.lastPathComponent == id.description else {
          throw AcornryError.integrityMismatch("staging directory spelling does not match transfer identity")
        }
        guard let manifest = try finalizedManifest(id, limits: limits, metadataBudget: &metadataBudget) else {
          throw AcornryError.invalidState("finalized staging changed while reading its inventory")
        }
        state = .ready(manifest)
      } catch is CancellationError {
        throw CancellationError()
      } catch is MetadataBudgetExceeded {
        throw AcornryError.resourceLimitExceeded("retained staging metadata exceeds 64 MiB")
      } catch {
        state = .needsReview(error.localizedDescription)
      }
      if states[id] != nil {
        states[id] = .needsReview("Multiple staging entries share a transfer identity; originals were retained.")
      } else { states[id] = state }
    }
    if let enumerationError { throw enumerationError }
    return states.sorted { $0.key.description < $1.key.description }.map {
      AcornryPendingImport(transferID: $0.key, state: $0.value)
    }
  }

  package func stagedTransfer(_ transferID: AcornryTransferID,
    limits: AcornryResourceLimits = .default
  ) throws -> AcornryStagedTransfer? {
    var metadataBudget = Self.maximumInventoryMetadataBytes
    guard let manifest = try finalizedManifest(transferID, limits: limits, metadataBudget: &metadataBudget) else { return nil }
    let root = transferRoot(transferID)
    let payload = root.appendingPathComponent("payload", isDirectory: true)
    try AcornryPath.requireDirectory(payload)
    for entry in manifest.files {
      try AcornryPath.verifyFile(
        try AcornryPath.safeDescendant(entry.relativePath, under: payload), expected: entry, under: rootURL)
    }
    return AcornryStagedTransfer(manifest: manifest, rootURL: root, payloadRootURL: payload)
  }

  private func finalizedManifest(_ transferID: AcornryTransferID, limits: AcornryResourceLimits,
    metadataBudget: inout Int
  ) throws -> AcornryTransferManifest? {
    try Task.checkCancellation()
    guard contexts[transferID] == nil else { throw AcornryError.transferConflict(transferID) }
    let root = transferRoot(transferID)
    guard FileManager.default.fileExists(atPath: root.path) else { return nil }
    try AcornryPath.requireDirectory(root)
    let manifestURL = root.appendingPathComponent("manifest.json")
    let manifest = try JSONDecoder().decode(
      AcornryTransferManifest.self,
      from: readMetadata(manifestURL, maximumBytes: Self.maximumManifestBytes, budget: &metadataBudget))
    guard manifest.transferID == transferID else { throw AcornryError.transferConflict(transferID) }
    try manifest.validate(against: limits)
    let completionURL = root.appendingPathComponent("ready.json")
    guard try itemExists(completionURL) else { return nil }
    let completion = try JSONDecoder().decode(
      Completion.self,
      from: readMetadata(completionURL, maximumBytes: Self.maximumCompletionBytes, budget: &metadataBudget))
    guard completion.transferID == transferID,
      completion.manifestDigestSHA256 == (try manifest.digestSHA256())
    else {
      throw AcornryError.integrityMismatch("staging completion evidence does not match manifest")
    }
    return manifest
  }

  private func readMetadata(_ url: URL, maximumBytes: Int, budget: inout Int) throws -> Data {
    try AcornryPath.verifyNoSymlinks(from: rootURL, to: url)
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
      throw AcornryError.invalidState("staging metadata must be a regular file")
    }
    guard info.st_size <= maximumBytes else {
      throw AcornryError.resourceLimitExceeded("staging metadata exceeds its file limit")
    }
    guard info.st_size <= budget else { throw MetadataBudgetExceeded() }
    let data = try handle.read(upToCount: min(maximumBytes, budget) + 1) ?? Data()
    budget -= data.count
    guard budget >= 0 else { throw MetadataBudgetExceeded() }
    guard data.count <= maximumBytes else {
      throw AcornryError.resourceLimitExceeded("staging metadata grew beyond its file limit")
    }
    return data
  }

  private func itemExists(_ url: URL) throws -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return true }
    guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return false
  }

  package func abort(_ transferID: AcornryTransferID, removeStaging: Bool) throws {
    var failures: [String] = []
    if let context = contexts.removeValue(forKey: transferID) {
      for file in context.activeFiles.values {
        do { try file.handle.close() } catch { failures.append("close: \(error)") }
      }
    }
    if removeStaging {
      do { try AcornryPath.removeIfPresent(transferRoot(transferID)) } catch {
        failures.append("remove: \(error)")
      }
    }
    guard failures.isEmpty else {
      throw AcornryError.invalidState(failures.joined(separator: "; "))
    }
  }

  package func removeStaging(_ transferID: AcornryTransferID) throws {
    guard contexts[transferID] == nil else {
      throw AcornryError.invalidState("cannot remove active transfer")
    }
    try AcornryPath.removeIfPresent(transferRoot(transferID))
  }

  private func transferRoot(_ id: AcornryTransferID) -> URL {
    rootURL.appendingPathComponent(id.description, isDirectory: true)
  }

  private func resetDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try AcornryPath.requireDirectory(url)
      let children = try FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
      for child in children {
        let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw AcornryError.invalidPath(child.path) }
        try FileManager.default.removeItem(at: child)
      }
    } else {
      try AcornryPath.ensureDirectory(url)
    }
  }
}
