import Foundation

public enum DevelopmentMode: Equatable, Sendable {
  public enum Mac: String, Sendable { case run, buildOnly = "--build-only", debug = "--debug", logs = "--logs", telemetry = "--telemetry", verify = "--verify" }
  public enum Cloud: Equatable, Sendable { case mac, iphone, installIPhone(String) }
  case mac(Mac), ios, cloud(Cloud), assets
}

public struct DevelopmentRequest: Sendable {
  public let root: URL
  public let mode: DevelopmentMode
  public let dryRun: Bool
  public let developerDirectory: String
  public let developmentTeam: String
  public let buildRoot: URL
  var buildPaths: DevelopmentBuildPaths { DevelopmentBuildPaths(root: buildRoot) }

  public static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
    var rootPath: String?; var dryRun = false; var command: [String] = []; var index = 0
    while index < arguments.count {
      let value = arguments[index]
      guard valid(value) else { throw DevelopmentError.invalidArguments }
      switch value {
      case "--root":
        guard rootPath == nil, index + 1 < arguments.count, valid(arguments[index + 1]),
          !arguments[index + 1].hasPrefix("-") else { throw DevelopmentError.invalidArguments }
        rootPath = arguments[index + 1]; index += 2
      case "--dry-run":
        guard !dryRun else { throw DevelopmentError.invalidArguments }
        dryRun = true; index += 1
      default: command.append(value); index += 1
      }
    }
    guard let verb = command.first else { throw DevelopmentError.invalidArguments }
    let values = Array(command.dropFirst())
    let mode: DevelopmentMode
    switch verb {
    case "mac":
      guard values.count <= 1, let mac = DevelopmentMode.Mac(rawValue: values.first ?? "run") else { throw DevelopmentError.invalidArguments }
      mode = .mac(mac)
    case "ios":
      guard values.isEmpty || values == ["--local-simulator"] else { throw DevelopmentError.invalidArguments }
      mode = .ios
    case "cloud":
      if values.isEmpty || values == ["--iphone"] { mode = .cloud(.iphone) }
      else if values == ["--mac"] { mode = .cloud(.mac) }
      else if values.count == 2, values[0] == "--install-iphone", !values[1].hasPrefix("-"), valid(values[1]) {
        mode = .cloud(.installIPhone(values[1]))
      } else { throw DevelopmentError.invalidArguments }
    case "assets":
      guard values.isEmpty else { throw DevelopmentError.invalidArguments }
      mode = .assets
    default: throw DevelopmentError.invalidArguments
    }
    let developer = nonempty(environment["DEVELOPER_DIR"]) ?? "/Applications/Xcode.app/Contents/Developer"
    let team = nonempty(environment["FOLIO_DEVELOPMENT_TEAM"]) ?? "7WR76382QB"
    guard valid(developer), developer.hasPrefix("/"), valid(team), !team.hasPrefix("-") else { throw DevelopmentError.invalidArguments }
    let root = try DevelopmentPaths.repository(rootPath ?? FileManager.default.currentDirectoryPath)
    let buildRoot = try DevelopmentPaths.buildRoot(repository: root, override: nonempty(environment["FOLIO_BUILD_ROOT"]))
    return Self(root: root, mode: mode, dryRun: dryRun, developerDirectory: developer, developmentTeam: team,
      buildRoot: buildRoot)
  }

  private static func valid(_ value: String) -> Bool {
    !value.isEmpty && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
  private static func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
}

public enum DevelopmentError: LocalizedError, Sendable {
  case invalidArguments, invalidRepository, unsafeOutput, runningApplication, launchFailed
  case commandFailed(String, Int32)
  case verificationFailed
  case bundleCleanup(URL)

  public var errorDescription: String? {
    switch self {
    case .invalidArguments: "지원하지 않거나 누락·중복된 인수입니다. --help를 확인하세요."
    case .invalidRepository: "--root는 Package.swift와 Folio.xcodeproj가 있는 Folio 저장소여야 합니다."
    case .unsafeOutput: "출력 경로가 지정한 개발 캐시 범위를 벗어나거나 심볼릭 링크입니다. 기존 파일은 보존했습니다."
    case .runningApplication: "Folio가 실행 중입니다. 초안을 저장하고 앱을 종료한 뒤 다시 빌드하세요."
    case .launchFailed: "개발 도구를 시작하지 못했습니다. Xcode 경로와 실행 권한을 확인하세요."
    case .commandFailed(let executable, let status): "\(executable) 명령이 종료 코드 \(status)로 실패했습니다."
    case .verificationFailed: "앱을 연 뒤 FolioMac 실행을 확인하지 못했습니다."
    case .bundleCleanup(let backup): "새 앱은 준비했지만 이전 번들을 정리하지 못했습니다: \(backup.path)"
    }
  }
}
