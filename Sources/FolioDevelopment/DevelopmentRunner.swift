import Foundation

@MainActor public enum DevelopmentRunner {
  /// Returns only the last foreground diagnostic command; the CLI replaces itself
  /// with it so LLDB, log streaming, terminal input, and Ctrl-C retain native behavior.
  public static func run(_ plan: DevelopmentPlan) throws -> DevelopmentCommand? {
    guard !plan.request.dryRun else { return nil }
    if case .assets = plan.request.mode {} else { try DevelopmentPaths.validateBuildPaths(plan.request) }
    try validateOutput(plan.request)
    for action in plan.actions {
      switch action {
      case .requireStopped(let command, let executable):
        try DevelopmentProcess.requireStopped(command, matchingExecutable: executable)
      case .command(let command): try DevelopmentProcess.run(command)
      case .packageMac: try DevelopmentMacBundle.prepare(plan.request)
      case .assets: try DevelopmentAssets.render(plan.request)
      case .verifyMac(let command): try DevelopmentProcess.verify(command)
      case .foreground(let command): return command
      case .report(let message): try FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
      }
    }
    return nil
  }

  private static func validateOutput(_ request: DevelopmentRequest) throws {
    let output: URL
    let scope: URL
    switch request.mode {
    case .mac: output = request.buildPaths.macApp; scope = request.buildRoot
    case .ios: output = request.buildPaths.ios; scope = request.buildRoot
    case .cloud(.mac): output = request.buildPaths.signedMac; scope = request.buildRoot
    case .cloud: output = request.buildPaths.iphone; scope = request.buildRoot
    case .assets: output = request.root.appendingPathComponent("Assets"); scope = request.root
    }
    try DevelopmentPaths.validate(output, root: scope)
  }

}
