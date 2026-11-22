#if os(macOS)
import CryptoKit
import Foundation

/// A bounded immutable snapshot separates source reads from destination writes.
struct SkillFiles: Sendable {
  struct File: Sendable { let path: String; let data: Data; let permissions: Int }
  struct Folder: Sendable { let path: String; let permissions: Int }
  static let receiptName = ".folio-install.json"
  private static let byteLimit = 32 * 1024 * 1024
  private static let itemLimit = 4096
  let manifest: SkillManifest
  let files: [File]
  let folders: [Folder]
  let digest: String

  init(directory: URL, allowReceipt: Bool = false) throws {
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
    let root = try directory.resourceValues(forKeys: keys)
    guard root.isDirectory == true, root.isSymbolicLink != true else {
      throw SkillError.invalid("실제 스킬 폴더를 선택해 주세요. 설치 원본의 심볼릭 링크는 지원하지 않습니다.")
    }
    var failure: (any Error)?
    guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
      errorHandler: { _, error in failure = error; return false }) else {
      throw SkillError.invalid("스킬 폴더를 읽지 못했습니다.")
    }
    var files: [File] = []; var folders: [Folder] = []; var size = 0; var items = 0
    for case let url as URL in enumerator {
      try Task.checkCancellation()
      // Enumerator depth is stable even when Darwin expands /var to /private/var.
      let path = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
      if path == ".git" {
        guard !allowReceipt else { throw SkillError.modified }
        if try url.resourceValues(forKeys: keys).isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      if path == Self.receiptName {
        guard allowReceipt else { throw SkillError.invalid("Folio 설치 영수증이 포함된 원본은 가져올 수 없습니다.") }
        continue
      }
      items += 1
      guard items <= Self.itemLimit else { throw SkillError.invalid("스킬은 폴더·파일 4,096개 이하이어야 합니다.") }
      let values = try url.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true else { throw SkillError.invalid("스킬 내부의 심볼릭 링크는 설치하지 않습니다.") }
      let permissions = (try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
      if values.isDirectory == true {
        folders.append(Folder(path: path, permissions: permissions & 0o777)); continue
      }
      guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= Self.byteLimit - size else {
        throw SkillError.invalid("일반 파일로 구성된 32 MiB 이하의 스킬만 설치할 수 있습니다.")
      }
      let data = try SkillIO.read(url, limit: path == "SKILL.md" ? SkillManifest.byteLimit : Self.byteLimit - size)
      size += data.count
      guard size <= Self.byteLimit else { throw SkillError.invalid("스킬 크기가 32 MiB를 넘었습니다.") }
      files.append(File(path: path, data: data, permissions: permissions & 0o777))
    }
    if let failure { throw failure }
    guard let skill = files.first(where: { $0.path == "SKILL.md" }) else { throw SkillError.invalid("선택한 폴더에 SKILL.md가 없습니다.") }
    manifest = try SkillManifest(data: skill.data, directoryName: directory.lastPathComponent)
    self.files = files.sorted { $0.path < $1.path }
    self.folders = folders.sorted { $0.path < $1.path }
    var hash = SHA256()
    for folder in self.folders { hash.update(data: Data("d:\(folder.path.utf8.count):\(folder.path):\(folder.permissions):".utf8)) }
    for file in self.files {
      hash.update(data: Data("\(file.path.utf8.count):\(file.path):\(file.permissions):\(file.data.count):".utf8))
      hash.update(data: file.data)
    }
    digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func write(to directory: URL) throws {
    for folder in folders {
      try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder.path), withIntermediateDirectories: true)
    }
    for file in files {
      let url = directory.appendingPathComponent(file.path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try file.data.write(to: url, options: .withoutOverwriting)
      try FileManager.default.setAttributes([.posixPermissions: file.permissions], ofItemAtPath: url.path)
    }
    for folder in folders.reversed() {
      try FileManager.default.setAttributes([.posixPermissions: folder.permissions], ofItemAtPath: directory.appendingPathComponent(folder.path).path)
    }
  }
}
#endif
