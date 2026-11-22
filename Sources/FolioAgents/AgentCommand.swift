import Foundation
#if os(macOS)
import Darwin
import Synchronization
#endif

public struct CommandResult: Sendable {
  public let status: Int32
  public let output: String

  public init(status: Int32, output: String) {
    self.status = status
    self.output = output
  }
}

public enum AgentCommandError: Error, LocalizedError, Sendable {
  case unavailable, invalidExecutable, invalidDirectory, invalidArgument, launchFailed, outputLimit

  public var errorDescription: String? {
    switch self {
    case .unavailable: "명령 실행은 Mac에서 사용할 수 있습니다."
    case .invalidExecutable: "실행 가능한 CLI 파일을 선택하세요."
    case .invalidDirectory: "작업할 프로젝트 폴더를 다시 선택하세요."
    case .invalidArgument: "명령에 사용할 수 없는 입력입니다."
    case .launchFailed: "CLI를 시작하지 못했습니다. 실행 파일과 접근 권한을 확인하세요."
    case .outputLimit: "CLI 출력이 너무 커서 실행을 중단했습니다. 터미널에서 상태를 확인하세요."
    }
  }
}

/// Executes argument vectors directly. It never invokes a shell or prints command inputs.
public enum AgentCommand {
  public static let outputLimit = 1_048_576

  static func isExecutable(_ url: URL) -> Bool {
    url.isFileURL && url.path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: url.path)
      && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
  }

  @concurrent public static func run(
    executable: URL, arguments: [String], directory: URL? = nil,
    environment: [String: String] = [:]
  ) async throws -> CommandResult {
    #if os(macOS)
    try Task.checkCancellation()
    guard isExecutable(executable) else { throw AgentCommandError.invalidExecutable }
    if let directory {
      guard directory.isFileURL, directory.path.hasPrefix("/"),
            (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      else { throw AgentCommandError.invalidDirectory }
    }
    guard arguments.allSatisfy({ !$0.utf8.contains(0) }),
          environment.allSatisfy({ !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) })
    else { throw AgentCommandError.invalidArgument }

    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("folio-command-\(UUID())", isDirectory: true)
    do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    catch { throw AgentCommandError.launchFailed }
    defer { try? FileManager.default.removeItem(at: temporary) }
    let outputURL = temporary.appendingPathComponent("output")
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
          let output = try? FileHandle(forWritingTo: outputURL)
    else { throw AgentCommandError.launchFailed }
    defer { try? output.close() }

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var processEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    processEnvironment["GIT_TERMINAL_PROMPT"] = "0"
    processEnvironment["GCM_INTERACTIVE"] = "never"
    processEnvironment["SSH_ASKPASS_REQUIRE"] = "never"
    processEnvironment["SSH_ASKPASS"] = "/usr/bin/false"
    process.environment = processEnvironment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    let lifetime = CommandLifetime(process)

    return try await withTaskCancellationHandler {
      do {
        try lifetime.start()
        while process.isRunning {
          try Task.checkCancellation()
          let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
          if size > outputLimit {
            lifetime.stop()
            throw AgentCommandError.outputLimit
          }
          try await Task.sleep(for: .milliseconds(40))
        }
        try Task.checkCancellation()
        try? output.close()
        let input = try FileHandle(forReadingFrom: outputURL)
        defer { try? input.close() }
        let data = try input.read(upToCount: outputLimit + 1) ?? Data()
        guard data.count <= outputLimit else { throw AgentCommandError.outputLimit }
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
      } catch {
        lifetime.stop()
        if Task.isCancelled { throw CancellationError() }
        if let error = error as? AgentCommandError { throw error }
        throw AgentCommandError.launchFailed
      }
    } onCancel: {
      lifetime.stop()
    }
    #else
    throw AgentCommandError.unavailable
    #endif
  }
}

#if os(macOS)
/// The launch/cancel handshake is synchronous; no lock crosses a suspension point.
private final class CommandLifetime: Sendable {
  private struct State { var started = false; var stopped = false; var processGroup: pid_t? }
  private let state = Mutex(State())
  private let process: Process

  init(_ process: Process) { self.process = process }

  func start() throws {
    try state.withLock { state in
      guard !state.stopped else { throw CancellationError() }
      do {
        try process.run()
        state.started = true
        let group = getpgid(process.processIdentifier)
        // Foundation currently gives a launched task its own process group.
        // Verify ownership before ever sending a signal to a group.
        if group == process.processIdentifier, group != getpgrp() { state.processGroup = group }
      }
      catch { throw AgentCommandError.launchFailed }
    }
  }

  func stop() {
    state.withLock { state in
      state.stopped = true
      guard state.started else { return }
      if let group = state.processGroup {
        // Include Git, SSH and package-manager children that inherit this group.
        _ = kill(-group, SIGTERM)
        _ = kill(-group, SIGKILL)
      } else if process.isRunning {
        process.terminate()
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      }
      if process.isRunning { process.waitUntilExit() }
    }
  }
}
#endif
