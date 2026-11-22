import Darwin
import Foundation
import FolioAgents

@main enum FolioAgentCLI {
  @MainActor static func main() async {
    do {
      let request = try AgentCLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
      if case .help = request { print(help); return }
      let result = try await AgentCLICommands.execute(request)
      let data = try JSONSerialization.data(withJSONObject: result,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      try FileHandle.standardOutput.write(contentsOf: data + Data([0x0A]))
    } catch {
      let message: String
      switch error {
      case let error as AgentCLIError: message = error.localizedDescription
      case let error as SkillError: message = error.localizedDescription
      case let error as AgentPluginError: message = error.localizedDescription
      case let error as AgentCommandError: message = error.localizedDescription
      case is CancellationError: message = "작업을 취소했습니다. list로 현재 설치 상태를 확인하세요."
      default: message = "작업을 완료하지 못했습니다. 파일 접근 권한·SKILL.md 형식·호스트 CLI 상태를 확인하세요."
      }
      let safeMessage = AgentPlugins.displayOutput(message)
      try? FileHandle.standardError.write(contentsOf: Data("FolioAgentsCLI: \(safeMessage)\n".utf8))
      exit(error is AgentCLIError ? 2 : 1)
    }
  }

  private static let help = """
  FolioAgentsCLI — Codex·Claude Code 스킬 및 플러그인 관리

  스킬:
    list    --host codex|claude --scope global|project [--project PATH] [--home PATH]
    install --host codex|claude --scope global|project [--project PATH] [--home PATH]
            (--source LOCAL_FOLDER | --repo URL [--ref REF] [--path SUBDIRECTORY])
    update  --host codex|claude --scope global|project --name NAME [--project PATH] [--home PATH]
    remove  --host codex|claude --scope global|project --name NAME [--project PATH] [--home PATH]

  플러그인 (호스트 CLI 위임):
    plugin --host codex|claude --action ACTION [--value VALUE]
           [--scope user|project|local] [--project PATH] [--executable PATH]
    ACTION: list, install, remove, update, enable, disable, marketplaces,
            add-marketplace, refresh-marketplace, remove-marketplace
    list·marketplaces를 제외한 작업은 --value가 필요합니다.
    Codex 플러그인은 user만 허용하고 호스트 CLI에 --scope를 전달하지 않습니다.
    update·enable·disable은 Claude에서 제공합니다.

  예:
    FolioAgentsCLI list --host codex --scope global
    FolioAgentsCLI install --host claude --scope project --project . --source ./skills/my-skill
    FolioAgentsCLI install --host codex --scope global --repo git@github.com:owner/private.git --path skills/my-skill
    FolioAgentsCLI update --host codex --scope global --name my-skill
    FolioAgentsCLI remove --host claude --scope project --project . --name my-skill
    FolioAgentsCLI plugin --host claude --action list
    FolioAgentsCLI plugin --host claude --action install --value plugin@marketplace --scope project --project .

  Git ref 기본값은 HEAD입니다. 비공개 저장소는 기존 Git/SSH 인증을 사용합니다.
  global 기본 홈은 현재 사용자 홈이며 --home으로 다른 홈을 지정할 수 있습니다.
  project 범위에는 --project가 필요합니다. 상대 폴더 경로는 현재 작업 폴더 기준입니다.
  기존 외부 설치·레거시 설치·수정된 설치 사본은 업데이트하거나 제거하지 않습니다.
  결과는 JSON, 오류는 표준 오류로 출력합니다. 저장소 URL과 호스트 CLI의 비밀값은 출력하지 않습니다.
  """
}
