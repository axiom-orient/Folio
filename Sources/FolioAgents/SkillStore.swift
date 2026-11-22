#if os(macOS)
import Darwin
import Foundation

/// The only mutation owner for standalone skills. Plugin caches belong to the host CLI.
public actor SkillStore {
  public enum Phase: Sendable { case idle, resolving, validating, committing }
  public private(set) var phase = Phase.idle
  private let catalog: SkillCatalog
  private let manager = FileManager.default
  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { catalog = SkillCatalog(home: home) }

  public func list(_ target: SkillTarget) throws -> [InstalledSkill] {
    try catalog.list(target)
  }

  public func install(source: SkillSource, target: SkillTarget) async throws -> InstalledSkill {
    guard case .idle = phase else { throw SkillError.busy }
    phase = .resolving; defer { phase = .idle }
    let root = try checkedRoot(target, create: false)
    let resolved = try await SkillSourceResolver.resolve(source)
    defer { resolved.cleanup() }
    try Task.checkCancellation()
    phase = .validating
    let files = try SkillFiles(directory: resolved.directory)
    if target.host == .claude, ["synced", "anthropic-skills"].contains(files.manifest.name) {
      throw SkillError.invalid("이 이름은 Claude 계정 동기화가 관리하는 예약 이름입니다.")
    }
    let destination = root.appendingPathComponent(files.manifest.name, isDirectory: true)
    guard !exists(destination) else { throw SkillError.invalid("같은 이름의 스킬이 이미 있습니다. 기존 설치는 보존했습니다.") }
    _ = try checkedRoot(target, create: true)
    return try commit(files, source: source, revision: resolved.revision, destination: destination, target: target, replacing: nil)
  }

  public func update(_ installed: InstalledSkill, target: SkillTarget) async throws -> InstalledSkill {
    guard case .idle = phase else { throw SkillError.busy }
    phase = .resolving; defer { phase = .idle }
    let receipt = try ownedReceipt(installed, target: target)
    let resolved = try await SkillSourceResolver.resolve(receipt.source)
    defer { resolved.cleanup() }
    try Task.checkCancellation()
    phase = .validating
    let files = try SkillFiles(directory: resolved.directory)
    guard files.manifest.name == receipt.name else { throw SkillError.invalid("업데이트 원본의 스킬 이름이 바뀌었습니다. 기존 설치는 보존했습니다.") }
    return try commit(files, source: receipt.source, revision: resolved.revision,
      destination: installed.directory, target: target, replacing: installed)
  }

  public func remove(_ installed: InstalledSkill, target: SkillTarget) throws {
    guard case .idle = phase else { throw SkillError.busy }
    phase = .validating; defer { phase = .idle }
    let root = try checkedRoot(target, create: false)
    try SkillIO.withMutationLock(at: root) {
      _ = try ownedReceipt(installed, target: target)
      try Task.checkCancellation()
      phase = .committing
      // Rename first: host discovery sees either the full skill or no skill.
      let tombstone = root.appendingPathComponent(".folio-removed-" + UUID().uuidString)
      try manager.moveItem(at: installed.directory, to: tombstone)
      do { try manager.removeItem(at: tombstone) }
      catch {
        try manager.moveItem(at: tombstone, to: installed.directory)
        throw error
      }
    }
  }

  private func commit(_ files: SkillFiles, source: SkillSource, revision: String?, destination: URL,
    target: SkillTarget, replacing installed: InstalledSkill?) throws -> InstalledSkill {
    let root = try checkedRoot(target, create: false)
    let stage = root.appendingPathComponent(".folio-stage-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: stage) }
    try files.write(to: stage)
    let receipt = SkillCatalog.Receipt(id: UUID(), name: files.manifest.name, destination: destination.path,
      host: target.host, source: source, revision: revision, digest: files.digest, installedAt: Date())
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(receipt).write(to: stage.appendingPathComponent(SkillFiles.receiptName), options: .withoutOverwriting)
    try Task.checkCancellation()
    return try SkillIO.withMutationLock(at: root) {
      _ = try checkedRoot(target, create: false)
      if let installed { _ = try ownedReceipt(installed, target: target) }
      phase = .committing
      let flag = installed == nil ? RENAME_EXCL : RENAME_SWAP
      guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, destination.path, UInt32(flag)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return catalog.entry(destination, target: target)
    }
  }

  private func ownedReceipt(_ installed: InstalledSkill, target: SkillTarget) throws -> SkillCatalog.Receipt {
    let root = try checkedRoot(target, create: false)
    guard SkillManifest.validName(installed.name), installed.isManaged,
      installed.directory.standardizedFileURL == root.appendingPathComponent(installed.name, isDirectory: true) else {
      throw SkillError.unmanaged
    }
    let values = try installed.directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      let receipt = catalog.readReceipt(installed.directory), receipt.id == installed.receiptID,
      receipt.destination == installed.directory.path, receipt.host == target.host, receipt.name == installed.name else {
      throw SkillError.unmanaged
    }
    guard try SkillFiles(directory: installed.directory, allowReceipt: true).digest == receipt.digest else { throw SkillError.modified }
    return receipt
  }

  /// User-selected bases may resolve to a real location; host configuration descendants may not redirect writes.
  private func checkedRoot(_ target: SkillTarget, create: Bool) throws -> URL {
    let root = try target.directory(home: catalog.home)
    let base = root.deletingLastPathComponent().deletingLastPathComponent()
    let baseValues = try base.resourceValues(forKeys: [.isDirectoryKey])
    guard baseValues.isDirectory == true else { throw SkillError.invalid("설치 대상 폴더가 없습니다.") }
    for url in [root.deletingLastPathComponent(), root] {
      if exists(url) {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw SkillError.invalid("설치 대상의 .agents·.claude·skills 경로는 실제 폴더여야 합니다.") }
      } else if create { try manager.createDirectory(at: url, withIntermediateDirectories: false) }
    }
    return root
  }

  private func exists(_ url: URL) -> Bool {
    (try? manager.attributesOfItem(atPath: url.path)) != nil
  }
}
#endif
