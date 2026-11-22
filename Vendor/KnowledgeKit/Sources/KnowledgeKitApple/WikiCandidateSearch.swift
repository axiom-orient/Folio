import Foundation
import FolioKnowledge

/// A timed-out provider may ignore cancellation. Keep its slot until it exits,
/// so repeated searches cannot accumulate unbounded provider tasks.
actor WikiCandidateSearch {
  struct Result: Sendable {
    let ids: [String]
    let state: String
    let source: WikiSearchSource
  }

  private var activeID: UUID?
  private var activeTask: Task<Void, Never>?

  deinit { activeTask?.cancel() }

  func search(source: WikiSearchSource, timeout: Duration = .milliseconds(800),
    operation: @escaping @Sendable () async throws -> Result
  ) async -> Result {
    guard !Task.isCancelled else { return Result(ids: [], state: "cancelled", source: source) }
    guard activeID == nil else { return Result(ids: [], state: "systemSearchBusy", source: source) }
    let id = UUID()
    activeID = id
    let (stream, continuation) = AsyncStream<Result>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let worker = Task { [weak self] in
      let result: Result
      do { result = try await operation() }
      catch { result = Result(ids: [], state: "degraded: \(error.localizedDescription)", source: source) }
      await self?.finished(id)
      continuation.yield(result)
      continuation.finish()
    }
    activeTask = worker
    let timer = Task {
      do { try await Task.sleep(for: timeout) }
      catch { return }
      continuation.finish()
    }
    var iterator = stream.makeAsyncIterator()
    let result = await iterator.next()
    timer.cancel()
    worker.cancel()
    return result ?? Result(ids: [], state: "systemSearchTimedOut", source: source)
  }

  private func finished(_ id: UUID) {
    guard activeID == id else { return }
    activeID = nil
    activeTask = nil
  }
}
