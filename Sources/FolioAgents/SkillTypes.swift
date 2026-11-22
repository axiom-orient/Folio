import Foundation

public enum AgentHost: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex, claude
  public var id: String { rawValue }
  public var title: String { self == .codex ? "Codex" : "Claude Code" }
}

public enum SkillScope: String, Codable, CaseIterable, Identifiable, Sendable {
  case global, project
  public var id: String { rawValue }
  public var title: String { self == .global ? "글로벌" : "프로젝트" }
}

/// Private Git access is a source property, independent of installation scope.
public struct SkillTarget: Equatable, Sendable {
  public var host: AgentHost
  public var scope: SkillScope
  public var project: URL?
  public init(host: AgentHost, scope: SkillScope, project: URL? = nil) {
    self.host = host; self.scope = scope; self.project = project
  }
  public func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
    let base: URL
    switch scope {
    case .global: base = home
    case .project:
      guard let project, project.isFileURL else { throw SkillError.invalid("프로젝트 폴더를 선택해 주세요.") }
      base = project
    }
    return base.standardizedFileURL.appending(path: host == .codex ? ".agents/skills" : ".claude/skills", directoryHint: .isDirectory)
  }
}

public enum SkillSource: Codable, Equatable, Sendable {
  case local(URL)
  case git(repository: String, reference: String, subdirectory: String)
}

public struct InstalledSkill: Identifiable, Sendable {
  public let name: String
  public let summary: String
  public let directory: URL
  public let isManaged: Bool
  public let isSymbolicLink: Bool
  public let source: SkillSource?
  public let revision: String?
  public let warning: String?
  let receiptID: UUID?
  public var id: String { directory.path }
}

public enum SkillError: LocalizedError, Equatable {
  case invalid(String)
  case busy
  case modified
  case unmanaged
  public var errorDescription: String? {
    switch self {
    case .invalid(let detail): detail
    case .busy: "다른 설치 작업이 진행 중입니다."
    case .modified: "설치 후 파일이 변경되었습니다. 편집 내용을 보존하기 위해 업데이트·제거하지 않았습니다."
    case .unmanaged: "Folio가 설치한 원본을 확인할 수 없습니다. 기존 파일은 Finder에서 관리해 주세요."
    }
  }
}
