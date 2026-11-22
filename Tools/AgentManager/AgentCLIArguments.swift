import Foundation
import FolioAgents

enum AgentCLIError: LocalizedError {
  case usage(String)
  var errorDescription: String? {
    switch self { case .usage(let message): message }
  }
}

enum AgentCLIRequest: Sendable {
  case help
  case skill(SkillCLIRequest)
  case plugin(PluginCLIRequest)
}

struct SkillCLIRequest: Sendable {
  enum Action: Sendable {
    case list, install(SkillSource), update(String), remove(String)
  }
  let action: Action
  let target: SkillTarget
  let home: URL
}

struct PluginCLIRequest: Sendable {
  let operation: AgentPluginOperation
  let host: AgentHost
  let scope: AgentPluginScope
  let project: URL?
  let executable: URL?

  var action: String {
    switch operation {
    case .listPlugins: "list"
    case .install: "install"
    case .remove: "remove"
    case .update: "update"
    case .enable: "enable"
    case .disable: "disable"
    case .listMarketplaces: "marketplaces"
    case .addMarketplace: "add-marketplace"
    case .refreshMarketplace: "refresh-marketplace"
    case .removeMarketplace: "remove-marketplace"
    }
  }
}

enum AgentCLIArguments {
  static func parse(_ input: [String]) throws -> AgentCLIRequest {
    if input.isEmpty || input == ["help"] || input == ["--help"] { return .help }
    guard let command = input.first, ["list", "install", "update", "remove", "plugin"].contains(command) else {
      throw AgentCLIError.usage("지원하지 않는 명령입니다. --help를 확인하세요.")
    }
    if Array(input.dropFirst()) == ["--help"] { return .help }
    let common: Set<String> = ["--host", "--scope", "--project"]
    let allowed: Set<String> = switch command {
    case "install": common.union(["--home", "--source", "--repo", "--ref", "--path"])
    case "update", "remove": common.union(["--home", "--name"])
    case "plugin": common.union(["--action", "--value", "--executable"])
    default: common.union(["--home"])
    }
    let options = try parseOptions(Array(input.dropFirst()), allowed: allowed)
    guard let host = AgentHost(rawValue: try required("--host", in: options)) else {
      throw AgentCLIError.usage("--host는 codex 또는 claude여야 합니다.")
    }
    if command == "plugin" { return .plugin(try plugin(options, host: host)) }
    guard let scope = SkillScope(rawValue: try required("--scope", in: options)) else {
      throw AgentCLIError.usage("스킬 --scope는 global 또는 project여야 합니다.")
    }
    let project = options["--project"].map { fileURL($0) }
    guard scope != .project || project != nil else {
      throw AgentCLIError.usage("project 범위에는 --project 폴더가 필요합니다.")
    }
    let action: SkillCLIRequest.Action
    switch command {
    case "install":
      switch (options["--source"], options["--repo"]) {
      case (let local?, nil):
        guard options["--ref"] == nil, options["--path"] == nil else {
          throw AgentCLIError.usage("--ref와 --path는 --repo와 함께 사용하세요.")
        }
        action = .install(.local(fileURL(local)))
      case (nil, let repository?):
        action = .install(.git(repository: repository, reference: options["--ref"] ?? "HEAD",
          subdirectory: options["--path"] ?? ""))
      default:
        throw AgentCLIError.usage("설치에는 --source 또는 --repo 하나가 필요합니다.")
      }
    case "update": action = .update(try required("--name", in: options))
    case "remove": action = .remove(try required("--name", in: options))
    default: action = .list
    }
    return .skill(SkillCLIRequest(action: action, target: SkillTarget(host: host, scope: scope, project: project),
      home: options["--home"].map { fileURL($0) } ?? FileManager.default.homeDirectoryForCurrentUser))
  }

  private static func plugin(_ options: [String: String], host: AgentHost) throws -> PluginCLIRequest {
    guard let scope = AgentPluginScope(rawValue: options["--scope"] ?? "user") else {
      throw AgentCLIError.usage("플러그인 --scope는 user, project 또는 local이어야 합니다.")
    }
    let project = options["--project"].map { fileURL($0) }
    guard scope == .user || project != nil else {
      throw AgentCLIError.usage("플러그인 project·local 범위에는 --project 폴더가 필요합니다.")
    }
    let action = try required("--action", in: options)
    let value = options["--value"]
    let operation: AgentPluginOperation
    if action == "list" || action == "marketplaces" {
      guard value == nil else { throw AgentCLIError.usage("조회 작업에는 --value를 지정하지 마세요.") }
      operation = action == "list" ? .listPlugins : .listMarketplaces
    } else {
      let value = try required("--value", in: options)
      switch action {
      case "install": operation = .install(value)
      case "remove": operation = .remove(value)
      case "update": operation = .update(value)
      case "enable": operation = .enable(value)
      case "disable": operation = .disable(value)
      case "add-marketplace": operation = .addMarketplace(value)
      case "refresh-marketplace": operation = .refreshMarketplace(value)
      case "remove-marketplace": operation = .removeMarketplace(value)
      default: throw AgentCLIError.usage("지원하지 않는 플러그인 작업입니다. --help를 확인하세요.")
      }
    }
    return PluginCLIRequest(operation: operation, host: host, scope: scope,
      project: project, executable: options["--executable"].map { fileURL($0, directory: false) })
  }

  private static func parseOptions(_ input: [String], allowed: Set<String>) throws -> [String: String] {
    var options: [String: String] = [:]
    var index = 0
    while index < input.count {
      let key = input[index]
      guard allowed.contains(key) else { throw AgentCLIError.usage("알 수 없는 옵션입니다. --help를 확인하세요.") }
      guard options[key] == nil else { throw AgentCLIError.usage("같은 옵션을 두 번 지정할 수 없습니다.") }
      guard index + 1 < input.count, !input[index + 1].hasPrefix("--"), !input[index + 1].isEmpty,
        !input[index + 1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw AgentCLIError.usage("각 옵션 뒤에 비어 있지 않은 값 하나를 지정하세요.")
      }
      options[key] = input[index + 1]
      index += 2
    }
    return options
  }

  private static func required(_ key: String, in options: [String: String]) throws -> String {
    guard let value = options[key] else { throw AgentCLIError.usage("필수 옵션이 없습니다. --help를 확인하세요.") }
    return value
  }

  private static func fileURL(_ path: String, directory: Bool = true) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return URL(fileURLWithPath: expanded, isDirectory: directory, relativeTo: base).standardizedFileURL
  }
}
