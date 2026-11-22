import Foundation

/// One cancellation-aware mechanism. Callers own the budget and the effect being interrupted.
package enum AcornryDeadline {
  package static func run<Value: Sendable>(
    for timeout: Duration,
    interrupt: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw AcornryError.protocolTimedOut
        }
        defer { group.cancelAll() }
        do {
          guard let first = try await group.next() else { throw AcornryError.connectionClosed }
          return first
        } catch {
          group.cancelAll()
          await interrupt()
          throw error
        }
      }
    } onCancel: {
      Task { await interrupt() }
    }
  }
}
