import Darwin
import Foundation

@MainActor enum DevelopmentProcess {
  struct Result { let status: Int32; let output: String }

  static func run(_ command: DevelopmentCommand) throws {
    _ = try checkedExecute(command, capture: false)
  }

  static func capture(_ command: DevelopmentCommand) throws -> String {
    let result = try checkedExecute(command, capture: true)
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func requireStopped(_ command: DevelopmentCommand, matchingExecutable: String?) throws {
    let result = try execute(command, capture: true)
    if let matchingExecutable {
      guard result.status == 0 else { throw DevelopmentError.commandFailed("ps", result.status) }
      guard !result.output.components(separatedBy: .newlines).contains(matchingExecutable) else { throw DevelopmentError.runningApplication }
    } else {
      guard result.status == 1 else {
        if result.status == 0 { throw DevelopmentError.runningApplication }
        throw DevelopmentError.commandFailed("pgrep", result.status)
      }
    }
  }

  static func verify(_ command: DevelopmentCommand) throws {
    Thread.sleep(forTimeInterval: 1)
    guard try execute(command, capture: true).status == 0 else { throw DevelopmentError.verificationFailed }
  }

  private static func checkedExecute(_ command: DevelopmentCommand, capture: Bool) throws -> Result {
    let result = try execute(command, capture: capture)
    guard result.status == 0 else {
      throw DevelopmentError.commandFailed(URL(fileURLWithPath: command.executable).lastPathComponent, result.status)
    }
    return result
  }

  private static func execute(_ command: DevelopmentCommand, capture: Bool) throws -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.currentDirectoryURL = command.directory
    process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
    process.standardInput = FileHandle.standardInput
    let pipe = capture ? Pipe() : nil
    if let pipe { process.standardOutput = pipe } else { process.standardOutput = FileHandle.standardOutput }
    process.standardError = FileHandle.standardError
    let relay = DevelopmentSignalRelay(process)
    defer { relay.finish() }
    do { try process.run() } catch { throw DevelopmentError.launchFailed }
    let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    process.waitUntilExit()
    let status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    return Result(status: status, output: String(decoding: data, as: UTF8.self))
  }
}

/// Build subprocesses run in their own process group. Forward terminal interrupts
/// while joined, then restore the caller's handlers before a foreground exec.
private final class DevelopmentSignalRelay {
  private let queue = DispatchQueue(label: "com.axient.FolioDeveloper.signals")
  private let interrupt: any DispatchSourceSignal
  private let terminate: any DispatchSourceSignal
  private let previousInterrupt: sig_t?
  private let previousTerminate: sig_t?

  init(_ process: Process) {
    // A caught handler resets on exec, so child tools retain default signal handling.
    previousInterrupt = signal(SIGINT, { _ in })
    previousTerminate = signal(SIGTERM, { _ in })
    interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
    terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    interrupt.setEventHandler { if process.isRunning { process.interrupt() } }
    terminate.setEventHandler { if process.isRunning { process.terminate() } }
    interrupt.resume(); terminate.resume()
  }

  func finish() {
    interrupt.cancel(); terminate.cancel()
    queue.sync {}
    signal(SIGINT, previousInterrupt); signal(SIGTERM, previousTerminate)
  }
}
