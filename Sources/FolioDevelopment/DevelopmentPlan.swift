import Foundation

public struct DevelopmentCommand: Equatable, Sendable {
  public let executable: String
  public let arguments: [String]
  public let directory: URL
  public let environment: [String: String]

  public init(executable: String, arguments: [String], directory: URL, environment: [String: String]) {
    self.executable = executable; self.arguments = arguments; self.directory = directory; self.environment = environment
  }

  var json: [String: Any] { ["executable": executable, "arguments": arguments, "directory": directory.path, "environment": environment] }
}

public enum DevelopmentAction: Sendable {
  case requireStopped(DevelopmentCommand, matchingExecutable: String?)
  case command(DevelopmentCommand)
  case packageMac
  case assets
  case verifyMac(DevelopmentCommand)
  case foreground(DevelopmentCommand)
  case report(String)
}

public struct DevelopmentPlan: Sendable {
  public let request: DevelopmentRequest
  public let actions: [DevelopmentAction]

  public init(_ request: DevelopmentRequest) {
    self.request = request
    let paths = request.buildPaths
    let app = paths.macApp
    let binary = app.appendingPathComponent("Contents/MacOS/FolioMac")
    let stopped = DevelopmentAction.requireStopped(Self.macProcessCommand(request), matchingExecutable: nil)
    switch request.mode {
    case .mac(let mode):
      var steps: [DevelopmentAction] = [stopped, .command(Self.command(request, "/usr/bin/xcrun",
        ["swift", "build", "--package-path", request.root.appendingPathComponent("MacApp").path, "--scratch-path", paths.swiftPM.path, "--product", "FolioMac", "--jobs", "4"])), .packageMac,
        .report("Local-folder development bundle: \(app.path)\nUse Folio.xcodeproj for signed iCloud/App Group/Spotlight extension targets.")]
      switch mode {
      case .buildOnly: break
      case .debug: steps.append(.foreground(Self.command(request, "/usr/bin/xcrun", ["lldb", "--", binary.path])))
      case .run, .logs, .telemetry, .verify:
        steps.append(.command(Self.command(request, "/usr/bin/open", ["-n", app.path])))
        if mode == .logs || mode == .telemetry {
          let predicate = mode == .logs ? "process == \"FolioMac\"" : "subsystem == \"com.axient.Folio\""
          steps.append(.foreground(Self.command(request, "/usr/bin/log", ["stream", "--info", "--style", "compact", "--predicate", predicate])))
        } else if mode == .verify { steps.append(.verifyMac(Self.macProcessCommand(request))) }
      }
      actions = steps
    case .ios:
      actions = [.command(Self.command(request, "/usr/bin/xcodebuild", Self.buildArguments(scheme: "FolioIOS",
        destination: "generic/platform=iOS Simulator", output: paths.ios.path) +
        ["CODE_SIGNING_ALLOWED=NO", "FOLIO_IOS_INFO_PLIST=Apps/IOSLocalInfo.plist", "build"])),
        .report("Local iOS development app: \(paths.iosApp.path)")]
    case .cloud(let mode):
      let mac = mode == .mac
      let output = mac ? paths.signedMac : paths.iphone
      let cloudApp = mac ? paths.signedMacApp : paths.iphoneApp
      var steps: [DevelopmentAction] = []
      if mac {
        steps.append(.requireStopped(Self.command(request, "/bin/ps", ["-axo", "comm="]), matchingExecutable:
          cloudApp.appendingPathComponent("Contents/MacOS/FolioMac").path))
      }
      steps.append(.command(Self.command(request, "/usr/bin/xcodebuild", Self.buildArguments(scheme: mac ? "FolioMac" : "FolioIOS",
        destination: mac ? "platform=macOS" : "generic/platform=iOS", output: output.path) +
        ["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "DEVELOPMENT_TEAM=" + request.developmentTeam, "build"])))
      steps.append(.report(cloudApp.path))
      if case .installIPhone(let device) = mode {
        steps.append(.command(Self.command(request, "/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--device", device, cloudApp.path])))
        steps.append(.command(Self.command(request, "/usr/bin/xcrun", ["devicectl", "device", "process", "launch", "--device", device, "com.axient.Folio"])))
      }
      actions = steps
    case .assets: actions = [.assets, .report("Updated Folio Mac and iOS icons from FolioBrandMark.")]
    }
  }

  public var commands: [DevelopmentCommand] {
    actions.flatMap { action -> [DevelopmentCommand] in
      switch action {
      case .requireStopped(let command, _), .command(let command), .verifyMac(let command), .foreground(let command): [command]
      case .packageMac: DevelopmentMacBundle.preview(request)
      case .assets: DevelopmentAssets.preview(request)
      case .report: []
      }
    }
  }

  public func dryRunJSON() throws -> Data {
    let steps: [[String: Any]] = actions.map { action in
      switch action {
      case .requireStopped(let command, let executable):
        ["action": "requireStopped", "command": command.json, "matchingExecutable": executable ?? "FolioMac"]
      case .command(let command): ["action": "command", "command": command.json]
      case .foreground(let command): ["action": "replaceCLIForForeground", "command": command.json]
      case .report(let message): ["action": "reportOutput", "message": message]
      case .verifyMac(let command): ["action": "verifyAfterOneSecond", "command": command.json]
      case .packageMac: ["action": "stageSignAndReplaceMacBundle", "destination": request.buildPaths.macApp.path,
        "commands": DevelopmentMacBundle.preview(request).map(\.json)]
      case .assets: ["action": "renderAndCopyIconVariants", "commands": DevelopmentAssets.preview(request).map(\.json),
        "copies": DevelopmentAssets.copies(request).map { ["source": $0.source.path, "destination": $0.destination.path] }]
      }
    }
    return try JSONSerialization.data(withJSONObject: ["root": request.root.path, "buildRoot": request.buildRoot.path,
      "developerDirectory": request.developerDirectory, "developmentTeam": request.developmentTeam,
      "actions": steps, "commands": commands.map(\.json)], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }

  static func command(_ request: DevelopmentRequest, _ executable: String, _ arguments: [String]) -> DevelopmentCommand {
    DevelopmentCommand(executable: executable, arguments: arguments, directory: request.root,
      environment: ["DEVELOPER_DIR": request.developerDirectory])
  }

  static func macProcessCommand(_ request: DevelopmentRequest) -> DevelopmentCommand {
    command(request, "/usr/bin/pgrep", ["-x", "FolioMac"])
  }

  private static func buildArguments(scheme: String, destination: String, output: String) -> [String] {
    ["-project", "Folio.xcodeproj", "-scheme", scheme, "-configuration", "Debug", "-destination", destination,
      "-derivedDataPath", output, "-jobs", "4"]
  }
}
