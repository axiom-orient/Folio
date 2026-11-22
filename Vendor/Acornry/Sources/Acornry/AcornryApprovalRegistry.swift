import Foundation

package struct AcornryApprovalDecision: Sendable {
  package let accepted: Bool
  package let reason: String?
}

package actor AcornryApprovalRegistry {
  private enum State {
    case pending
    case waiting(CheckedContinuation<AcornryApprovalDecision, any Error>)
    case decided(AcornryApprovalDecision)
  }
  private struct Entry {
    let token: UUID
    var state: State
    let timeout: Task<Void, Never>
  }
  private var entries: [AcornryTransferID: Entry] = [:]

  /// Install before the offer notification, so an immediate host decision is never lost.
  package func prepare(_ id: AcornryTransferID, timeout: Duration) throws -> UUID {
    guard entries[id] == nil else { throw AcornryError.transferConflict(id) }
    let token = UUID()
    let timer = Task { [weak self] in
      do { try await Task.sleep(for: timeout) } catch { return }
      await self?.expire(id, token: token)
    }
    entries[id] = Entry(token: token, state: .pending, timeout: timer)
    return token
  }

  package func wait(for id: AcornryTransferID, token: UUID) async throws -> AcornryApprovalDecision
  {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        guard var entry = entries[id], entry.token == token else {
          continuation.resume(throwing: AcornryError.operationCancelled)
          return
        }
        switch entry.state {
        case .pending:
          entry.state = .waiting(continuation)
          entries[id] = entry
        case .decided(let decision):
          entries.removeValue(forKey: id)
          entry.timeout.cancel()
          continuation.resume(returning: decision)
        case .waiting:
          continuation.resume(throwing: AcornryError.transferConflict(id))
        }
      }
    } onCancel: {
      Task { await self.discard(id, token: token) }
    }
  }

  package func decide(_ id: AcornryTransferID, accepted: Bool, reason: String?) throws {
    guard var entry = entries[id] else { throw AcornryError.approvalNotPending(id) }
    let decision = AcornryApprovalDecision(accepted: accepted, reason: reason)
    switch entry.state {
    case .pending:
      entry.state = .decided(decision)
      entries[id] = entry
    case .waiting(let continuation):
      entries.removeValue(forKey: id)
      continuation.resume(returning: decision)
    case .decided:
      throw AcornryError.approvalNotPending(id)
    }
    entry.timeout.cancel()
  }

  package func discard(_ id: AcornryTransferID, token: UUID) {
    guard let entry = entries[id], entry.token == token else { return }
    entries.removeValue(forKey: id)
    entry.timeout.cancel()
    if case .waiting(let continuation) = entry.state {
      continuation.resume(throwing: AcornryError.operationCancelled)
    }
  }

  package func cancelAll() {
    for (id, entry) in entries { discard(id, token: entry.token) }
  }

  private func expire(_ id: AcornryTransferID, token: UUID) {
    guard var entry = entries[id], entry.token == token else { return }
    let decision = AcornryApprovalDecision(accepted: false, reason: "approval_timeout")
    switch entry.state {
    case .pending:
      entry.state = .decided(decision)
      entries[id] = entry
    case .waiting(let continuation):
      entries.removeValue(forKey: id)
      continuation.resume(returning: decision)
    case .decided: break
    }
  }
}
