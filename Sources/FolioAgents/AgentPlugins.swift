import Foundation

public enum AgentPluginScope: String, CaseIterable, Identifiable, Sendable {
  case user, project, local
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .user: "사용자 전체"
    case .project: "프로젝트 공유"
    case .local: "이 프로젝트의 나만"
    }
  }
}

public enum AgentPluginOperation: Sendable, Equatable {
  case listPlugins, install(String), remove(String), update(String), enable(String), disable(String)
  case listMarketplaces, addMarketplace(String), refreshMarketplace(String), removeMarketplace(String)

  public var changesInstallation: Bool {
    switch self {
    case .listPlugins, .listMarketplaces: false
    default: true
    }
  }

  var supportsScope: Bool {
    switch self {
    case .listPlugins, .listMarketplaces, .refreshMarketplace: false
    default: true
    }
  }
}

public enum AgentPluginError: Error, LocalizedError, Sendable {
  case invalidInput, credentialsInSource, missingProject, unsupportedOperation, unsupportedCLI, commandFailed

  public var errorDescription: String? {
    switch self {
    case .invalidInput: "플러그인 ID 또는 마켓플레이스 입력을 확인하세요."
    case .credentialsInSource: "주소에 암호나 토큰을 넣지 마세요. Git 자격 증명 도우미 또는 SSH 인증을 사용하세요."
    case .missingProject: "프로젝트 또는 로컬 범위를 사용하려면 프로젝트 폴더를 선택하세요."
    case .unsupportedOperation: "이 호스트 CLI는 선택한 작업이나 설치 범위를 제공하지 않습니다."
    case .unsupportedCLI: "설치된 CLI가 이 명령 또는 설치 범위를 지원하지 않습니다. CLI를 업데이트한 뒤 다시 확인하세요."
    case .commandFailed: "CLI 작업을 완료하지 못했습니다. 일부 변경이 반영되었을 수 있으니 인증과 설치 목록을 다시 확인하세요."
    }
  }
}

/// Plugin lifecycle and package fetching belong to the host's native CLI.
/// Folio does not edit host configuration or plugin caches itself.
public enum AgentPlugins {
  public static func executable(for host: AgentHost, preferred: URL? = nil) -> URL? {
    #if os(macOS)
    let name = switch host { case .codex: "codex"; case .claude: "claude" }
    if let preferred {
      return AgentCommand.isExecutable(preferred) ? preferred : nil
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    var directories = [home.appendingPathComponent(".local/bin"),
      home.appendingPathComponent(".npm-global/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"),
      URL(fileURLWithPath: "/usr/local/bin"), URL(fileURLWithPath: "/usr/bin")]
    directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
      .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
    var candidates = directories.map { $0.appendingPathComponent(name) }
    if host == .codex {
      candidates += [
        URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
        URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")]
    }
    return candidates.first(where: AgentCommand.isExecutable)
    #else
    return nil
    #endif
  }

  public static func arguments(
    for operation: AgentPluginOperation, host: AgentHost, scope: AgentPluginScope = .user
  ) throws -> [String] {
    if host == .codex, scope != .user { throw AgentPluginError.unsupportedOperation }
    var result = ["plugin"]
    switch operation {
    case .listPlugins: result += ["list", "--available"]
    case .install(let id): result += [host == .codex ? "add" : "install", try identifier(id)]
    case .remove(let id): result += [host == .codex ? "remove" : "uninstall", try identifier(id)]
    case .update(let id):
      guard host == .claude else { throw AgentPluginError.unsupportedOperation }
      result += ["update", try identifier(id)]
    case .enable(let id), .disable(let id):
      guard host == .claude else { throw AgentPluginError.unsupportedOperation }
      result += [operation == .enable(id) ? "enable" : "disable", try identifier(id)]
    case .listMarketplaces: result += ["marketplace", "list"]
    case .addMarketplace(let source): result += ["marketplace", "add", try marketplaceSource(source)]
    case .refreshMarketplace(let name):
      result += ["marketplace", host == .codex ? "upgrade" : "update", try identifier(name)]
    case .removeMarketplace(let name): result += ["marketplace", "remove", try identifier(name)]
    }
    if host == .claude, operation.supportsScope { result += ["--scope", scope.rawValue] }
    result += ["--json"]
    return result
  }

  @concurrent public static func execute(
    _ operation: AgentPluginOperation, host: AgentHost, executable: URL,
    projectRoot: URL? = nil, scope: AgentPluginScope = .user
  ) async throws -> CommandResult {
    if scope != .user, projectRoot == nil { throw AgentPluginError.missingProject }
    var arguments = try arguments(for: operation, host: host, scope: scope)
    let commandDepth = arguments[1] == "marketplace" ? 3 : 2
    let help = try await AgentCommand.run(executable: executable,
      arguments: Array(arguments.prefix(commandDepth)) + ["--help"], directory: projectRoot)
    let usage = help.output.split(separator: "\n").filter { $0.lowercased().contains("usage:") }.joined(separator: " ")
    let command = arguments.prefix(commandDepth).joined(separator: " ")
    guard help.status == 0, usage.contains(command),
          !arguments.contains("--scope") || help.output.contains("--scope")
    else { throw AgentPluginError.unsupportedCLI }
    // Older hosts can still provide text results; scope must never silently fall back.
    if !help.output.contains("--json") { arguments.removeAll { $0 == "--json" } }
    if !help.output.contains("--available") { arguments.removeAll { $0 == "--available" } }
    let result = try await AgentCommand.run(executable: executable, arguments: arguments, directory: projectRoot)
    // Keep error diagnostics and source credentials out of the UI and model state.
    guard result.status == 0 else { throw AgentPluginError.commandFailed }
    return CommandResult(status: result.status, output: displayOutput(result.output))
  }

  /// Redaction happens before output becomes observable UI state.
  public static func displayOutput(_ output: String) -> String {
    var safe = output.replacingOccurrences(of: "\\/", with: "/")
    let replacements = [
      (#"(?i)(?:https?|ssh|file)://[^\s\"<>]+"#, "[주소 숨김]"),
      (#"[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^\s\"<>]+"#, "[주소 숨김]"),
      (#"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,})\b"#, "[비밀값 숨김]"),
      (#"(?i)(\"?(?:access[_-]?token|refresh[_-]?token|token|api[_-]?key|secret|password|authorization|credential)\"?\s*[:=]\s*)[^\n,}]+"#, "$1\"[비밀값 숨김]\"")]
    for (pattern, replacement) in replacements {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      safe = regex.stringByReplacingMatches(in: safe, range: NSRange(safe.startIndex..., in: safe), withTemplate: replacement)
    }
    return safe.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func identifier(_ input: String) throws -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*(?:@[A-Za-z0-9][A-Za-z0-9._-]*)?$"#, options: .regularExpression) != nil,
          value.count <= 256
    else { throw AgentPluginError.invalidInput }
    return value
  }

  private static func marketplaceSource(_ input: String) throws -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 4096, !value.hasPrefix("-"),
          !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), !value.contains("::")
    else { throw AgentPluginError.invalidInput }
    if value.contains("://") {
      guard let components = URLComponents(string: value),
            ["https", "http", "ssh"].contains(components.scheme?.lowercased() ?? ""),
            components.host != nil
      else { throw AgentPluginError.invalidInput }
      guard components.password == nil,
            components.scheme?.lowercased() == "ssh" || components.user == nil,
            components.query == nil
      else { throw AgentPluginError.credentialsInSource }
    }
    return value
  }
}
