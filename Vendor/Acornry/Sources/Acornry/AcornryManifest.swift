import Foundation

public struct AcornryManifestFile: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey { case relativePath, byteCount, checksumSHA256 }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      relativePath: values.decode(String.self, forKey: .relativePath),
      byteCount: values.decode(Int64.self, forKey: .byteCount),
      checksumSHA256: values.decode(String.self, forKey: .checksumSHA256))
  }

  public let relativePath: String
  public let byteCount: Int64
  public let checksumSHA256: String

  public init(relativePath: String, byteCount: Int64, checksumSHA256: String) throws {
    guard byteCount >= 0 else { throw AcornryError.invalidManifest("negative byte count") }
    let digest = checksumSHA256.lowercased()
    guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
      throw AcornryError.invalidManifest("invalid SHA-256 for \(relativePath)")
    }
    self.relativePath = try AcornryPath.validate(relativePath)
    self.byteCount = byteCount
    self.checksumSHA256 = digest
  }
}

public struct AcornryTransferManifest: Codable, Equatable, Sendable {
  public static let schemaVersion = 1
  private enum CodingKeys: String, CodingKey {
    case schema, transferID, sender, displayName, files
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let schema = try values.decode(Int.self, forKey: .schema)
    guard schema == Self.schemaVersion else {
      throw AcornryError.invalidManifest("unsupported manifest schema \(schema)")
    }
    try self.init(
      transferID: values.decode(AcornryTransferID.self, forKey: .transferID),
      sender: values.decode(AcornryIdentity.self, forKey: .sender),
      displayName: values.decode(String.self, forKey: .displayName),
      files: values.decode([AcornryManifestFile].self, forKey: .files))
  }

  public let schema: Int
  public let transferID: AcornryTransferID
  public let sender: AcornryIdentity
  public let displayName: String
  public let files: [AcornryManifestFile]

  public var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }

  public init(
    transferID: AcornryTransferID,
    sender: AcornryIdentity,
    displayName: String,
    files: [AcornryManifestFile]
  ) throws {
    let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard !displayName.isEmpty, displayName.utf8.count <= 256,
      !displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw AcornryError.invalidManifest("invalid display name")
    }
    guard !files.isEmpty else {
      throw AcornryError.invalidManifest("at least one file is required")
    }
    let paths = Set(files.map(\.relativePath))
    guard paths.count == files.count else {
      throw AcornryError.invalidManifest("duplicate relative path")
    }
    var total: Int64 = 0
    for file in files {
      let (next, overflow) = total.addingReportingOverflow(file.byteCount)
      guard !overflow else { throw AcornryError.invalidManifest("total byte count overflow") }
      total = next
      var parent = file.relativePath.split(separator: "/")
      while parent.count > 1 {
        parent.removeLast()
        guard !paths.contains(parent.joined(separator: "/")) else {
          throw AcornryError.invalidManifest("a file cannot also be a parent directory")
        }
      }
    }
    self.schema = Self.schemaVersion
    self.transferID = transferID
    self.sender = sender
    self.displayName = displayName
    self.files = files
  }

  public func validate(against limits: AcornryResourceLimits) throws {
    guard schema == Self.schemaVersion else {
      throw AcornryError.invalidManifest("unsupported manifest schema \(schema)")
    }
    guard !files.isEmpty, files.count <= limits.maxFileCount else {
      throw AcornryError.resourceLimitExceeded(
        "file count \(files.count) exceeds \(limits.maxFileCount)")
    }
    var total: Int64 = 0
    for file in files {
      guard file.byteCount <= limits.maxSingleFileBytes else {
        throw AcornryError.resourceLimitExceeded("\(file.relativePath) exceeds per-file limit")
      }
      let (next, overflow) = total.addingReportingOverflow(file.byteCount)
      guard !overflow else { throw AcornryError.resourceLimitExceeded("total byte count overflow") }
      total = next
    }
    guard total <= limits.maxTotalBytes else {
      throw AcornryError.resourceLimitExceeded(
        "total bytes \(total) exceeds \(limits.maxTotalBytes)")
    }
  }

  public func canonicalData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  public func digestSHA256() throws -> String { AcornrySHA256.hexDigest(of: try canonicalData()) }
}

public struct AcornryFileSource: Equatable, Sendable {
  public let fileURL: URL
  public let relativePath: String

  public init(fileURL: URL, relativePath: String? = nil) throws {
    guard fileURL.isFileURL else { throw AcornryError.invalidPath(fileURL.absoluteString) }
    self.fileURL = fileURL.standardizedFileURL
    self.relativePath = try AcornryPath.validate(relativePath ?? fileURL.lastPathComponent)
  }
}

package struct AcornryPreparedTransfer: Sendable {
  package let manifest: AcornryTransferManifest
  package let sources: [AcornryFileSource]

  package static func prepare(
    id: AcornryTransferID,
    sender: AcornryIdentity,
    displayName: String,
    sources: [AcornryFileSource],
    limits: AcornryResourceLimits
  ) throws -> Self {
    try Task.checkCancellation()
    guard !sources.isEmpty else {
      throw AcornryError.invalidManifest("at least one file is required")
    }
    guard sources.count <= limits.maxFileCount else {
      throw AcornryError.resourceLimitExceeded("source file count exceeds limit")
    }
    guard Set(sources.map(\.relativePath)).count == sources.count else {
      throw AcornryError.invalidManifest("duplicate source relative path")
    }
    var files: [AcornryManifestFile] = []
    files.reserveCapacity(sources.count)
    var total: Int64 = 0
    for source in sources {
      try Task.checkCancellation()
      try AcornryPath.requireRegularFile(source.fileURL)
      let values = try source.fileURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw AcornryError.invalidPath(source.fileURL.path)
      }
      guard let fileSize = values.fileSize, fileSize >= 0 else {
        throw AcornryError.invalidManifest("source file size is unavailable")
      }
      let count = Int64(fileSize)
      let (next, overflow) = total.addingReportingOverflow(count)
      guard count <= limits.maxSingleFileBytes, !overflow, next <= limits.maxTotalBytes else {
        throw AcornryError.resourceLimitExceeded("source bytes exceed configured limits")
      }
      total = next
      let digest = try AcornrySHA256.hexDigest(ofFileAt: source.fileURL)
      files.append(
        try .init(relativePath: source.relativePath, byteCount: count, checksumSHA256: digest))
    }
    let manifest = try AcornryTransferManifest(
      transferID: id, sender: sender, displayName: displayName, files: files)
    try manifest.validate(against: limits)
    return Self(manifest: manifest, sources: sources)
  }
}
