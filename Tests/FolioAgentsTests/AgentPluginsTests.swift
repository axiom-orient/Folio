import Foundation
import Testing
@testable import FolioAgents

@Suite struct AgentPluginsTests {
  @Test func codexUsesNativeVerbsWithoutScopeFlags() throws {
    #expect(try AgentPlugins.arguments(for: .install("sample@team"), host: .codex)
      == ["plugin", "add", "sample@team", "--json"])
    #expect(try AgentPlugins.arguments(for: .remove("sample@team"), host: .codex)
      == ["plugin", "remove", "sample@team", "--json"])
    #expect(try AgentPlugins.arguments(for: .refreshMarketplace("team"), host: .codex)
      == ["plugin", "marketplace", "upgrade", "team", "--json"])
    #expect(throws: AgentPluginError.self) {
      try AgentPlugins.arguments(for: .install("sample@team"), host: .codex, scope: .project)
    }
    #expect(throws: AgentPluginError.self) {
      try AgentPlugins.arguments(for: .update("sample@team"), host: .codex)
    }
  }

  @Test func claudeUsesExplicitScopeOnlyWhereSupported() throws {
    #expect(try AgentPlugins.arguments(for: .install("sample@team"), host: .claude, scope: .project)
      == ["plugin", "install", "sample@team", "--scope", "project", "--json"])
    #expect(try AgentPlugins.arguments(for: .enable("sample@team"), host: .claude, scope: .local)
      == ["plugin", "enable", "sample@team", "--scope", "local", "--json"])
    #expect(try AgentPlugins.arguments(for: .refreshMarketplace("team"), host: .claude, scope: .project)
      == ["plugin", "marketplace", "update", "team", "--json"])
  }

  @Test(arguments: ["--all", "name;echo", "sample@team --scope project", "../plugin", "a\nb"])
  func rejectsPluginArgumentInjection(_ input: String) {
    #expect(throws: AgentPluginError.self) {
      try AgentPlugins.arguments(for: .remove(input), host: .codex)
    }
  }

  @Test(arguments: ["https://token@example.com/private.git", "https://user:pass@example.com/private.git",
    "https://example.com/private.git?token=private", "--config", "ext::arbitrary", "a\nb"])
  func rejectsCredentialsAndUnsafeMarketplaceSources(_ source: String) {
    #expect(throws: AgentPluginError.self) {
      try AgentPlugins.arguments(for: .addMarketplace(source), host: .codex)
    }
  }

  @Test func acceptsPrivateSSHWithoutEmbeddingSecrets() throws {
    #expect(try AgentPlugins.arguments(for: .addMarketplace("git@example.com:team/private.git"), host: .codex)
      == ["plugin", "marketplace", "add", "git@example.com:team/private.git", "--json"])
  }

  @Test func hidesCredentialsAndSourceAddressesBeforeDisplay() {
    let text = #"{"url":"https:\/\/user:secret@example.com/private.git","token":"bearer-private","password":"another-private","source":"git@example.com:team/private.git"}"#
    let result = AgentPlugins.displayOutput(text)
    #expect(!result.contains("example.com"))
    #expect(!result.contains("bearer-private"))
    #expect(!result.contains("another-private"))
  }

  #if os(macOS)
  @Test func runsLiteralArgumentsAndDisablesGitPrompts() async throws {
    let literal = "$(echo should-never-run); spaces stay literal"
    let result = try await AgentCommand.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", literal])
    #expect(result.status == 0)
    #expect(result.output == literal)
    let environment = try await AgentCommand.run(executable: URL(fileURLWithPath: "/usr/bin/printenv"),
      arguments: ["GIT_TERMINAL_PROMPT"], environment: ["GIT_TERMINAL_PROMPT": "1"])
    #expect(environment.output == "0\n")
  }

  @Test func rejectsUnrecognizedCLIWithoutRunningMutation() async {
    await #expect(throws: AgentPluginError.self) {
      try await AgentPlugins.execute(.install("sample@team"), host: .codex,
        executable: URL(fileURLWithPath: "/bin/echo"))
    }
  }

  @Test func cancelsRunningProcess() async throws {
    let start = ContinuousClock.now
    let task = Task { try await AgentCommand.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) }
    try await Task.sleep(for: .milliseconds(120))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(3))
  }

  @Test func stopsUnboundedOutput() async {
    await #expect(throws: AgentCommandError.self) {
      try await AgentCommand.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["bounded"])
    }
  }
  #endif
}
