import Foundation

public enum AcornryOperationState: String, Codable, Equatable, Sendable {
  case completed
  case partial
  case rejected
  case cancelled
}

public struct AcornrySavedFile: Equatable, Sendable {
  public let relativePath: String
  public let fileURL: URL
  public let byteCount: Int64
  public let checksumSHA256: String

  public init(relativePath: String, fileURL: URL, byteCount: Int64, checksumSHA256: String) {
    self.relativePath = relativePath
    self.fileURL = fileURL
    self.byteCount = byteCount
    self.checksumSHA256 = checksumSHA256
  }
}

public struct AcornryFileResult: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case saved(AcornrySavedFile, alreadyPresent: Bool)
    case failed(String)
    case notAttempted
  }

  public let relativePath: String
  public let outcome: Outcome

  public init(relativePath: String, outcome: Outcome) {
    self.relativePath = relativePath
    self.outcome = outcome
  }

  public var savedFile: AcornrySavedFile? {
    guard case .saved(let file, _) = outcome else { return nil }
    return file
  }
}

/// A receipt derived from actual destination bytes. Counts are computed, never stored independently.
public struct AcornryImportReceipt: Equatable, Sendable {
  public let transferID: AcornryTransferID
  public let displayName: String
  public let state: AcornryOperationState
  public let files: [AcornryFileResult]
  public let stagingRemoved: Bool
  public let cleanupError: String?

  public init(
    transferID: AcornryTransferID,
    displayName: String,
    state: AcornryOperationState,
    files: [AcornryFileResult],
    stagingRemoved: Bool,
    cleanupError: String?
  ) {
    self.transferID = transferID
    self.displayName = displayName
    self.state = state
    self.files = files
    self.stagingRemoved = stagingRemoved
    self.cleanupError = cleanupError
  }

  public var savedFiles: [AcornrySavedFile] { files.compactMap(\.savedFile) }
  public var importedFileCount: Int { savedFiles.count }
  public var failedFileCount: Int {
    files.count(where: { if case .failed = $0.outcome { true } else { false } })
  }
  public var notAttemptedFileCount: Int {
    files.count(where: { $0.outcome == .notAttempted })
  }
}

public enum AcornryRemoteFileStatus: String, Codable, Equatable, Sendable {
  case saved
  case failed
}

public struct AcornryRemoteFileResult: Codable, Equatable, Sendable {
  public let relativePath: String
  public let status: AcornryRemoteFileStatus
  public let checksumSHA256: String
  public let detail: String?

  public init(
    relativePath: String,
    status: AcornryRemoteFileStatus,
    checksumSHA256: String,
    detail: String? = nil
  ) {
    self.relativePath = relativePath
    self.status = status
    self.checksumSHA256 = checksumSHA256
    self.detail = detail
  }
}

/// Sender-visible evidence from the receiving Acornry instance.
public struct AcornryTransferReceipt: Codable, Equatable, Sendable {
  public let transferID: AcornryTransferID
  public let manifestDigestSHA256: String
  public let state: AcornryOperationState
  public let files: [AcornryRemoteFileResult]

  public init(
    transferID: AcornryTransferID,
    manifestDigestSHA256: String,
    state: AcornryOperationState,
    files: [AcornryRemoteFileResult]
  ) {
    self.transferID = transferID
    self.manifestDigestSHA256 = manifestDigestSHA256
    self.state = state
    self.files = files
  }

  package init(local: AcornryImportReceipt, manifest: AcornryTransferManifest) throws {
    self.transferID = local.transferID
    self.manifestDigestSHA256 = try manifest.digestSHA256()
    self.state = local.state
    guard local.transferID == manifest.transferID, local.files.count == manifest.files.count else {
      throw AcornryError.integrityMismatch("local receipt does not match manifest")
    }
    self.files = try zip(local.files, manifest.files).map { result, entry in
      guard result.relativePath == entry.relativePath else {
        throw AcornryError.integrityMismatch("local receipt file order does not match manifest")
      }
      switch result.outcome {
      case .saved:
        return .init(
          relativePath: result.relativePath, status: .saved, checksumSHA256: entry.checksumSHA256)
      case .failed(let detail):
        return .init(
          relativePath: result.relativePath, status: .failed, checksumSHA256: entry.checksumSHA256,
          detail: detail)
      case .notAttempted:
        return .init(
          relativePath: result.relativePath, status: .failed, checksumSHA256: entry.checksumSHA256,
          detail: "not_attempted")
      }
    }
    try validate(for: manifest)
  }
}

extension AcornryTransferReceipt {
  package func validate(
    for manifest: AcornryTransferManifest
  ) throws {
    guard self.transferID == manifest.transferID,
      self.manifestDigestSHA256 == (try manifest.digestSHA256()),
      self.files.count == manifest.files.count,
      self.state == .completed || self.state == .partial
    else { throw AcornryError.integrityMismatch("receipt does not match sent manifest") }
    let failedCount = self.files.filter { $0.status == .failed }.count
    guard
      (self.state == .completed && failedCount == 0)
        || (self.state == .partial && failedCount > 0)
    else { throw AcornryError.integrityMismatch("receipt state contradicts file evidence") }
    for (remote, local) in zip(self.files, manifest.files) {
      guard remote.relativePath == local.relativePath,
        remote.checksumSHA256 == local.checksumSHA256
      else { throw AcornryError.integrityMismatch("receipt file evidence mismatch") }
    }
  }

}
