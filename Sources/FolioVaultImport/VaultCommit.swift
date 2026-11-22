import Darwin
import Foundation

enum VaultCommit {
  private struct OwnedDirectory {
    let url: URL
    let device: dev_t
    let inode: ino_t

    init(_ url: URL) throws {
      var value = stat()
      guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
        throw VaultImportError.invalid("출력 작업 폴더를 확인하지 못했습니다.")
      }
      self.url = url; device = value.st_dev; inode = value.st_ino
    }

    func owns(_ location: URL? = nil) -> Bool {
      var value = stat()
      return lstat((location ?? url).path, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
        && value.st_dev == device && value.st_ino == inode
    }
  }

  static func write(_ plan: VaultPlan, locations: VaultImportLocations) throws {
    var parents: [OwnedDirectory] = []; var stages: [OwnedDirectory] = []
    var preserveForRecovery = false; var finished = false
    defer {
      if !preserveForRecovery {
        for stage in stages where stage.owns() { try? FileManager.default.removeItem(at: stage.url) }
        if !finished { for parent in parents.reversed() where parent.owns() { _ = rmdir(parent.url.path) } }
      }
    }
    try createParents(locations.destination.deletingLastPathComponent(), owned: &parents)
    try createParents(locations.evidence.deletingLastPathComponent(), owned: &parents)
    let workspace = try stage(beside: locations.destination, label: "workspace")
    stages.append(workspace)
    let evidence = try stage(beside: locations.evidence, label: "evidence")
    stages.append(evidence)
    try write(plan.workspace, to: workspace.url, directories: [VaultPaths.notesDirectory, "attachments"])
    try write(plan.evidence, to: evidence.url, directories: ["originals"])
    try renameExclusive(workspace.url, locations.destination)
    do { try renameExclusive(evidence.url, locations.evidence) }
    catch {
      let commitError = error
      // Two directory roots cannot commit atomically. Restore the first rename
      // only while it still identifies our stage; preserve both copies on failure.
      do {
        guard workspace.owns(locations.destination) else {
          throw VaultImportError.invalid("확정한 자료함이 외부에서 변경되어 자동 복구하지 못했습니다.")
        }
        try renameExclusive(locations.destination, workspace.url)
      } catch {
        preserveForRecovery = true
        throw VaultImportError.incompleteCommit(workspace: locations.destination, evidence: evidence.url)
      }
      throw commitError
    }
    finished = true
  }

  private static func stage(beside target: URL, label: String) throws -> OwnedDirectory {
    let url = target.deletingLastPathComponent().appendingPathComponent(".folio-vault-\(label)-\(UUID().uuidString)", isDirectory: true)
    guard mkdir(url.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return try OwnedDirectory(url)
  }

  private static func createParents(_ url: URL, owned: inout [OwnedDirectory]) throws {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
      current.appendPathComponent(component, isDirectory: true)
      var metadata = stat()
      if lstat(current.path, &metadata) == 0 {
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
          throw VaultImportError.invalid("출력 상위 폴더가 변경되었거나 실제 폴더가 아닙니다.")
        }
      } else {
        guard errno == ENOENT, mkdir(current.path, 0o700) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        owned.append(try OwnedDirectory(current))
      }
    }
  }

  private static func write(_ files: [VaultOutputFile], to root: URL, directories: [String]) throws {
    let manager = FileManager.default
    for path in directories {
      try manager.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    for file in files {
      let output = root.appendingPathComponent(file.relativePath)
      try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try file.data.write(to: output, options: .withoutOverwriting)
    }
  }

  private static func renameExclusive(_ source: URL, _ destination: URL) throws {
    guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
