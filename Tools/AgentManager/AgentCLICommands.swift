import Foundation
import FolioAgents

@MainActor enum AgentCLICommands {
  static func execute(_ request: AgentCLIRequest) async throws -> [String: Any] {
    switch request {
    case .help: [:]
    case .skill(let request): try await skill(request)
    case .plugin(let request): try await plugin(request)
    }
  }

  private static func skill(_ request: SkillCLIRequest) async throws -> [String: Any] {
    let store = SkillStore(home: request.home)
    let target = request.target
    let directory = try target.directory(home: request.home)
    var result: [String: Any] = ["host": target.host.rawValue, "scope": target.scope.rawValue,
      "target": directory.path]
    switch request.action {
    case .list:
      result["skills"] = try await store.list(target).map(serialize)
    case .install(let source):
      result["skill"] = serialize(try await store.install(source: source, target: target))
    case .update(let name):
      let installed = try await managedSkill(name, store: store, target: target, directory: directory)
      result["skill"] = serialize(try await store.update(installed, target: target))
    case .remove(let name):
      let installed = try await managedSkill(name, store: store, target: target, directory: directory)
      try await store.remove(installed, target: target)
      result["removed"] = installed.name
      result["path"] = installed.directory.path
    }
    return result
  }

  private static func managedSkill(_ name: String, store: SkillStore, target: SkillTarget,
    directory: URL) async throws -> InstalledSkill {
    let skills = try await store.list(target)
    // Compatibility entries may share a name; only this target's owned path can mutate.
    guard let installed = skills.first(where: {
      $0.name == name && $0.directory.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }), installed.isManaged, !installed.isSymbolicLink else {
      throw AgentCLIError.usage("선택한 범위에 Folio가 설치한 스킬이 없습니다. 외부·레거시 설치는 변경하지 않습니다.")
    }
    return installed
  }

  private static func plugin(_ request: PluginCLIRequest) async throws -> [String: Any] {
    guard let executable = AgentPlugins.executable(for: request.host, preferred: request.executable) else {
      throw AgentCLIError.usage("실행 가능한 호스트 CLI가 없습니다. --executable 경로를 지정하세요.")
    }
    let result = try await AgentPlugins.execute(request.operation, host: request.host, executable: executable,
      projectRoot: request.project, scope: request.scope)
    return ["host": request.host.rawValue, "scope": request.scope.rawValue, "action": request.action,
      "output": result.output]
  }

  private static func serialize(_ skill: InstalledSkill) -> [String: Any] {
    var result: [String: Any] = ["name": skill.name, "summary": AgentPlugins.displayOutput(skill.summary),
      "path": skill.directory.path, "managed": skill.isManaged, "symbolicLink": skill.isSymbolicLink]
    if let revision = skill.revision { result["revision"] = revision }
    if let warning = skill.warning { result["warning"] = AgentPlugins.displayOutput(warning) }
    switch skill.source {
    case .local(let url): result["source"] = ["kind": "local", "path": url.path]
    case .git(_, let reference, let subdirectory):
      // Repository URLs stay in the local receipt and never enter terminal logs.
      result["source"] = ["kind": "git", "reference": AgentPlugins.displayOutput(reference),
        "subdirectory": AgentPlugins.displayOutput(subdirectory)]
    case nil: break
    }
    return result
  }
}
