import Darwin
import Foundation
import FolioDevelopment

@main enum FolioDeveloperCLI {
  @MainActor static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] { print(help); return }
      let request = try DevelopmentRequest.parse(arguments)
      let plan = DevelopmentPlan(request)
      if request.dryRun {
        try FileHandle.standardOutput.write(contentsOf: plan.dryRunJSON() + Data([0x0A]))
      } else if let foreground = try DevelopmentRunner.run(plan) { try replaceProcess(with: foreground) }
    } catch {
      let message = (error as? DevelopmentError)?.localizedDescription ?? "개발 작업을 완료하지 못했습니다. 파일 접근 권한과 Xcode 설치 상태를 확인하세요."
      try? FileHandle.standardError.write(contentsOf: Data("FolioDeveloper: \(message)\n".utf8))
      if case .commandFailed(_, let status) = error as? DevelopmentError { exit(status) }
      if case .invalidArguments = error as? DevelopmentError { exit(2) }
      exit(1)
    }
  }

  private static func replaceProcess(with command: DevelopmentCommand) throws {
    guard FileManager.default.changeCurrentDirectoryPath(command.directory.path) else { throw DevelopmentError.invalidRepository }
    let environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
    let arguments = ([command.executable] + command.arguments).map { strdup($0) }
    let variables = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
    defer { for pointer in arguments + variables { free(pointer) } }
    let argv = arguments + [nil]; let envp = variables + [nil]
    argv.withUnsafeBufferPointer { argv in
      envp.withUnsafeBufferPointer { envp in
        _ = execve(command.executable, argv.baseAddress, envp.baseAddress)
      }
    }
    throw DevelopmentError.launchFailed
  }

  private static let help = """
  FolioDeveloper — Folio의 Swift 개발 도구

  사용: FolioDeveloper [--root PATH] [--dry-run] COMMAND
    mac [run|--build-only|--debug|--logs|--telemetry|--verify]
    ios [--local-simulator]
    cloud [--mac|--iphone|--install-iphone DEVICE_ID]
    assets

  --root 기본값은 현재 작업 폴더입니다. --dry-run은 명령과 동작을 JSON으로만 출력합니다.
  DEVELOPER_DIR와 FOLIO_DEVELOPMENT_TEAM 환경 설정을 사용하며 다른 환경은 상속합니다.
  개발 출력은 ~/Library/Developer/FolioBuilds에 보관합니다. FOLIO_BUILD_ROOT로 외부 절대 경로를 지정할 수 있습니다.
  mac은 로컬 개발 번들, ios는 서명 없는 로컬 시뮬레이터 빌드입니다.
  cloud는 프로비저닝을 포함한 서명 빌드이며 설치·실행은 --install-iphone을 지정할 때 수행합니다.
  """
}
