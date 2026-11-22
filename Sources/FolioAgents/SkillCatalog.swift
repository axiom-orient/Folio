#if os(macOS)
import Foundation

/// Inspects standalone installations without granting mutation authority.
/// The store rechecks paths, receipts, and content immediately before effects.
struct SkillCatalog {
  let home: URL

  init(home: URL) { self.home = home.standardizedFileURL }

  func list(_ target: SkillTarget) throws -> [InstalledSkill] {
    let root = try target.directory(home: home)
    var entries = try scan(root, target: target)
    if target.host == .codex, target.scope == .global {
      let legacy = home.appending(path: ".codex/skills", directoryHint: .isDirectory)
      if legacy.resolvingSymlinksInPath() != root.resolvingSymlinksInPath() {
        entries += try scan(legacy, target: target, compatibility: true)
      }
    }
    return entries.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
  }

  private func scan(_ root: URL, target: SkillTarget, compatibility: Bool = false) throws -> [InstalledSkill] {
    let manager = FileManager.default
    guard manager.fileExists(atPath: root.path) else { return [] }
    var failure: (any Error)?
    guard let items = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, error in failure = error; return false }) else {
      throw SkillError.invalid("설치 목록을 읽지 못했습니다.")
    }
    var result: [InstalledSkill] = []
    var visited = 0
    for case let enumerated as URL in items {
      visited += 1
      guard visited <= 4096 else { throw SkillError.invalid("설치 폴더가 4,096개를 넘었습니다. 폴더를 나누어 관리해 주세요.") }
      let directory = root.appendingPathComponent(enumerated.lastPathComponent, isDirectory: true)
      if manager.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path) {
        result.append(entry(directory, target: target, compatibility: compatibility))
      }
    }
    if let failure { throw failure }
    return result
  }

  func entry(_ directory: URL, target: SkillTarget, compatibility: Bool = false) -> InstalledSkill {
    let link = (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    let receipt = readReceipt(directory)
    let manifest = try? SkillManifest(data: SkillIO.read(directory.appendingPathComponent("SKILL.md"), limit: SkillManifest.byteLimit), directoryName: directory.lastPathComponent)
    let managed = !compatibility && !link && manifest != nil && receipt?.host == target.host
      && receipt?.name == directory.lastPathComponent && receipt?.destination == directory.path
    let warning: String?
    if compatibility { warning = "기존 ~/.codex/skills 경로 · 읽기 전용" }
    else if link { warning = "심볼릭 링크 · 읽기 전용" }
    else if manifest == nil { warning = "SKILL.md 메타데이터를 확인해 주세요." }
    else if !managed { warning = "기존 설치 · 읽기 전용" }
    else { warning = nil }
    return InstalledSkill(name: manifest?.name ?? directory.lastPathComponent, summary: manifest?.summary ?? "",
      directory: directory, isManaged: managed, isSymbolicLink: link, source: managed ? receipt?.source : nil,
      revision: managed ? receipt?.revision : nil, warning: warning, receiptID: managed ? receipt?.id : nil)
  }

  func readReceipt(_ directory: URL) -> Receipt? {
    let url = directory.appendingPathComponent(SkillFiles.receiptName)
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
      values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 256 * 1024,
      let data = try? SkillIO.read(url, limit: 256 * 1024), let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.schema == 1 else { return nil }
    return receipt
  }

  struct Receipt: Codable {
    var schema = 1
    let id: UUID
    let name: String
    let destination: String
    let host: AgentHost
    let source: SkillSource
    let revision: String?
    let digest: String
    let installedAt: Date
  }
}
#endif
