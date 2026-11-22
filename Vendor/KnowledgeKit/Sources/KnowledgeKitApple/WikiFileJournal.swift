import Darwin
import Foundation
import FolioKnowledge

struct WikiFileJournal {
  private static let receiptLimit = 2 * 1024 * 1024
  private static let metadataLimit = 4 * 1024 * 1024
  private struct BackupPaths: Encodable { let paths: [String] }
  struct Ownership: Sendable { let intent: BackupOwnership.File; let backups: BackupOwnership? }
  struct BackupOwnership: Sendable {
    struct File: Sendable { let name: String; let device: dev_t; let inode: ino_t; let revision: String }
    let directory: String
    let device: dev_t
    let inode: ino_t
    let files: [File]
  }
  struct Intent: Encodable {
    let operationID: UUID; let workspaceID: UUID; let commandSHA256: String
    let operation: WikiFileOperation; let expectedRevision: String?
  }
  struct Receipt: Codable { let commandSHA256: String; let change: WikiFileChange }
  let root: URL
  let id: UUID
  let digest: String
  let operation: WikiFileOperation
  let expectedRevision: String?
  var intentPath: String { id.uuidString + ".intent.json" }
  var receiptPath: String { id.uuidString + ".json" }

  init(directory: URL, id: UUID, operation: WikiFileOperation, expectedRevision: String?) throws {
    if let expectedRevision {
      guard expectedRevision.utf8.count == 64,
        expectedRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw WikiError.changedSource }
    }
    struct Command: Encodable { let operation: WikiFileOperation; let expectedRevision: String? }
    root = directory.appendingPathComponent("FileManagement", isDirectory: true); self.id = id
    self.operation = operation; self.expectedRevision = expectedRevision
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    digest = SourceDigest.sha256(try encoder.encode(Command(operation: operation, expectedRevision: expectedRevision)))
  }

  func validateChangeSize(_ change: WikiFileChange) throws {
    let data = try JSONEncoder().encode(Receipt(commandSHA256: digest, change: change))
    // Leave room for the small fixed commit/durability/projection diagnostics.
    guard data.count <= Self.receiptLimit - 4096 else { throw WikiError.unavailable("File operation receipt exceeds its 2 MiB recovery limit. Move a smaller selection.") }
  }

  func existing() throws -> WikiFileChange? {
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(receiptPath).path) {
      let receipt = try JSONDecoder().decode(Receipt.self, from: CoordinatedFiles.read(root: root, path: receiptPath, maximumBytes: 2 * 1024 * 1024))
      guard receipt.commandSHA256 == digest, receipt.change.operationID == id else { throw WikiError.conflict("File operation ID was reused for a different command.") }
      return receipt.change
    }
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(intentPath).path) { throw WikiFileOperationError.uncertain(operationID: id) }
    return nil
  }

  @discardableResult func begin(workspaceID: UUID, backups: [WikiMovePlan.Patch]) throws -> Ownership {
    let intent = try JSONEncoder().encode(Intent(operationID: id, workspaceID: workspaceID,
      commandSHA256: digest, operation: operation, expectedRevision: expectedRevision))
    let paths = try JSONEncoder().encode(BackupPaths(paths: backups.map(\.path)))
    guard intent.count <= Self.metadataLimit, paths.count <= Self.metadataLimit else {
      throw WikiError.unavailable("File operation recovery metadata exceeds 4 MiB. Move a smaller selection.")
    }
    try WikiLocalStorage.createDirectory(root)
    var ownership: BackupOwnership?
    if !backups.isEmpty {
      let name = id.uuidString + "-rollback"
      let folder = root.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      var directory = stat()
      guard lstat(folder.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR else { throw WikiError.changedSource }
      for (index, patch) in backups.enumerated() {
        try CoordinatedFiles.write(root: folder, path: "\(index).bin", expectedRevision: nil, bytes: patch.before)
      }
      try CoordinatedFiles.write(root: folder, path: "paths.json", expectedRevision: nil, bytes: paths)
      let names = backups.indices.map { "\($0).bin" } + ["paths.json"]
      let files = try names.map { filename -> BackupOwnership.File in
        var item = stat()
        let bytes = try CoordinatedFiles.read(root: folder, path: filename)
        guard lstat(folder.appendingPathComponent(filename).path, &item) == 0,
          item.st_mode & S_IFMT == S_IFREG else { throw WikiError.changedSource }
        return BackupOwnership.File(name: filename, device: item.st_dev, inode: item.st_ino, revision: SourceDigest.sha256(bytes))
      }
      ownership = BackupOwnership(directory: name, device: directory.st_dev, inode: directory.st_ino, files: files)
    }
    try CoordinatedFiles.write(root: root, path: intentPath, expectedRevision: nil, bytes: intent)
    var info = stat()
    guard lstat(root.appendingPathComponent(intentPath).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw WikiError.changedSource }
    return Ownership(intent: BackupOwnership.File(name: intentPath, device: info.st_dev, inode: info.st_ino,
      revision: SourceDigest.sha256(intent)), backups: ownership)
  }

  func cleanupAfterCommit(_ ownership: Ownership) throws {
    guard try existing() != nil else { throw WikiError.changedSource }
    if let backups = ownership.backups { try cleanupBackups(backups) }
    try CoordinatedFiles.withParent(root: root, path: intentPath) { parent, name in
      var item = stat()
      guard fstatat(parent, name, &item, AT_SYMLINK_NOFOLLOW) == 0,
        item.st_dev == ownership.intent.device, item.st_ino == ownership.intent.inode,
        SourceDigest.sha256(try CoordinatedFiles.read(parent: parent, name: name, maximumBytes: 4 * 1024 * 1024)) == ownership.intent.revision,
        unlinkat(parent, name, 0) == 0 else { throw WikiError.changedSource }
      guard fsync(parent) == 0 else { throw WikiError.unavailable("Operation-intent cleanup durability is unconfirmed.") }
    }
  }

  func cleanupBackups(_ ownership: BackupOwnership) throws {
    let folder = root.appendingPathComponent(ownership.directory)
    guard Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == Set(ownership.files.map(\.name)) else { throw WikiError.changedSource }
    try CoordinatedFiles.withParent(root: root, path: ownership.directory + "/paths.json") { parent, _ in
      var directory = stat()
      guard fstat(parent, &directory) == 0, directory.st_dev == ownership.device, directory.st_ino == ownership.inode else { throw WikiError.changedSource }
      for file in ownership.files {
        var item = stat()
        guard fstatat(parent, file.name, &item, AT_SYMLINK_NOFOLLOW) == 0, item.st_mode & S_IFMT == S_IFREG,
          item.st_dev == file.device, item.st_ino == file.inode,
          SourceDigest.sha256(try CoordinatedFiles.read(parent: parent, name: file.name, maximumBytes: 4 * 1024 * 1024)) == file.revision else { throw WikiError.changedSource }
      }
      for file in ownership.files {
        var item = stat()
        guard fstatat(parent, file.name, &item, AT_SYMLINK_NOFOLLOW) == 0,
          item.st_dev == file.device, item.st_ino == file.inode,
          unlinkat(parent, file.name, 0) == 0 else { throw WikiError.changedSource }
      }
      guard fsync(parent) == 0 else { throw WikiError.unavailable("Rollback backup cleanup durability is unconfirmed.") }
    }
    try CoordinatedFiles.withParent(root: root, path: ownership.directory) { parent, name in
      var directory = stat()
      guard fstatat(parent, name, &directory, AT_SYMLINK_NOFOLLOW) == 0,
        directory.st_dev == ownership.device, directory.st_ino == ownership.inode,
        unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw WikiError.changedSource }
      guard fsync(parent) == 0 else { throw WikiError.unavailable("Rollback directory cleanup durability is unconfirmed.") }
    }
  }

  func save(_ change: WikiFileChange) throws {
    let data = try JSONEncoder().encode(Receipt(commandSHA256: digest, change: change))
    guard data.count <= Self.receiptLimit else { throw WikiError.unavailable("File operation receipt exceeds its recovery read limit.") }
    let url = root.appendingPathComponent(receiptPath)
    let old = FileManager.default.fileExists(atPath: url.path) ? try CoordinatedFiles.read(root: root, path: receiptPath, maximumBytes: 2 * 1024 * 1024) : nil
    try CoordinatedFiles.write(root: root, path: receiptPath, expectedRevision: old.map(SourceDigest.sha256),
      bytes: data)
  }
}
