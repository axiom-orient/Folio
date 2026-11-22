import Foundation

/// Refresh and index requests coalesce within a workspace lifetime. A drained
/// job cannot clear the registration of a newer job started during suspension.
@MainActor
final class FolioWorkspaceJobs {
  private struct Job {
    let id: UUID
    let task: Task<Void, Never>
  }
  private var refreshJob: Job?
  private var refreshPending = false
  private var indexJob: Job?
  private var indexPending = false

  var isRefreshing: Bool { refreshJob != nil }
  var isIndexing: Bool { indexJob != nil }

  func requestRefresh(operation: @escaping @MainActor () async -> Void) {
    refreshPending = true
    guard refreshJob == nil else { return }
    let id = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.refreshJob?.id == id { self.refreshJob = nil }
      }
      do {
        repeat {
          self.refreshPending = false
          try await Task.sleep(for: .milliseconds(120))
          guard !Task.isCancelled, self.refreshJob?.id == id else { return }
          await operation()
        } while self.refreshPending && !Task.isCancelled
      } catch {}
    }
    refreshJob = Job(id: id, task: task)
  }

  @discardableResult
  func scheduleIndex(operation: @escaping @MainActor () async -> Void) -> Bool {
    if let indexJob {
      if !indexJob.task.isCancelled { indexPending = true }
      return false
    }
    indexPending = true
    let id = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.indexJob?.id == id { self.indexJob = nil; self.indexPending = false }
      }
      repeat {
        self.indexPending = false
        guard !Task.isCancelled, self.indexJob?.id == id else { return }
        await operation()
        if self.indexPending { await Task.yield() }
      } while self.indexPending && !Task.isCancelled
    }
    indexJob = Job(id: id, task: task)
    return true
  }

  /// Revocation must cancel synchronously, before any background drain awaits.
  func cancel() { refreshJob?.task.cancel(); indexPending = false; indexJob?.task.cancel() }

  func drainRefresh() async {
    let previous = refreshJob
    previous?.task.cancel()
    refreshJob = nil; refreshPending = false
    await previous?.task.value
  }

  func drainIndex() async {
    let previous = indexJob
    indexPending = false
    previous?.task.cancel()
    await previous?.task.value
    if indexJob?.id == previous?.id { indexJob = nil }
  }
}
