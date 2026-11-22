import Darwin
import Foundation
import FolioKnowledge
import FolioKnowledgeApple

struct SDKPendingSave: Codable, Equatable {
  let operationID: UUID
  let text: String
  let resultRevision: String
}

struct SDKDraft: Codable, Equatable {
  let id: String
  var title: String
  let path: String
  var text: String
  var original: String
  var revision: String
  var pending: SDKPendingSave?
  var isDirty: Bool { text != original }
  var document: FolioDocument { .init(id: id, title: title, relativePath: path, revision: revision) }
}

/// One process/session owns each recovery file. A failed checkpoint never replaces
/// the in-memory edit. Atomic replacement precedes publication to the session. No legacy paths are inspected.
final class FolioRecoveryStore {
  private struct File: Codable {
    let version: Int
    let scope: String
    let drafts: [String: SDKDraft]
  }
  private let lock: Int32
  private let url: URL
  private let scope: String
  private static let limit = 16 * 1024 * 1024

  init(directory: URL, scope: String) throws {
    try WikiLocalStorage.createDirectory(directory)
    self.scope = scope
    url = directory.appendingPathComponent("drafts-v1.json")
    let descriptor = Darwin.open(directory.appendingPathComponent(".session.lock").path,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard descriptor >= 0 else { throw FolioError.recoveryDamaged }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      _ = Darwin.close(descriptor); throw FolioError.stateInUse
    }
    lock = descriptor
  }

  deinit { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }

  func load() throws -> [String: SDKDraft] {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if fd < 0 {
      if errno == ENOENT { return [:] }
      throw FolioError.recoveryDamaged
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size <= Self.limit else { throw FolioError.recoveryDamaged }
    let data = try handle.read(upToCount: Self.limit + 1) ?? Data()
    guard data.count <= Self.limit else { throw FolioError.recoveryDamaged }
    let file = try JSONDecoder().decode(File.self, from: data)
    guard file.version == 1, file.scope == scope else { throw FolioError.recoveryDamaged }
    for (id, draft) in file.drafts {
      guard id == draft.id, try WikiPath.validate(draft.path) == draft.path,
        draft.path.hasPrefix("notes/"),
        SourceDigest.sha256(Data(draft.original.utf8)) == draft.revision else { throw FolioError.recoveryDamaged }
      if let pending = draft.pending, SourceDigest.sha256(Data(pending.text.utf8)) != pending.resultRevision {
        throw FolioError.recoveryDamaged
      }
    }
    return file.drafts
  }

  /// Retain the exact pending edit before an explicit user review replaces it.
  /// This archive is never replayed and the writer's original intent is untouched.
  func archivePending(_ draft: SDKDraft) throws {
    guard let pending = draft.pending else { throw FolioError.noChanges }
    let directory = url.deletingLastPathComponent().appendingPathComponent("ReviewedSaves", isDirectory: true)
    guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else {
      throw FolioError.recoveryDamaged
    }
    try WikiLocalStorage.createDirectory(directory)
    let destination = directory.appendingPathComponent(pending.operationID.uuidString + ".json")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(draft)
    guard data.count <= Self.limit else { throw FolioError.recoveryDamaged }
    try publish(data, to: destination, replacing: false)
  }

  func write(_ drafts: [String: SDKDraft]) throws {
    let file = File(version: 1, scope: scope, drafts: drafts.filter { $0.value.isDirty || $0.value.pending != nil })
    let data = try JSONEncoder().encode(file)
    guard data.count <= Self.limit else { throw FolioError.recoveryDamaged }
    try publish(data, to: url, replacing: true)
  }

  /// Apply permissions before publication: no fallible chmod can report a
  /// failed checkpoint after the old recovery file has already been replaced.
  private func publish(_ data: Data, to destination: URL, replacing: Bool) throws {
    let directory = destination.deletingLastPathComponent()
    guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else {
      throw FolioError.recoveryDamaged
    }
    let stage = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
    let fd = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw FolioError.recoveryDamaged }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close(); _ = unlink(stage.path) }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    if replacing {
      var info = stat()
      let status = lstat(destination.path, &info)
      guard (status == 0 && (info.st_mode & S_IFMT) == S_IFREG) || (status != 0 && errno == ENOENT),
        rename(stage.path, destination.path) == 0 else { throw FolioError.recoveryDamaged }
    } else if link(stage.path, destination.path) != 0 {
      guard errno == EEXIST else { throw FolioError.recoveryDamaged }
      let existing = Darwin.open(destination.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard existing >= 0 else { throw FolioError.recoveryDamaged }
      let reader = FileHandle(fileDescriptor: existing, closeOnDealloc: true)
      defer { try? reader.close() }
      var info = stat()
      guard fstat(existing, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
        info.st_size <= Self.limit,
        try reader.read(upToCount: Self.limit + 1) == data else { throw FolioError.recoveryDamaged }
    }
  }
}
