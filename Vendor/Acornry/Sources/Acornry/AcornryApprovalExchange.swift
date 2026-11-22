import Foundation

/// One protocol exchange races human approval against the remote cancel/first frame.
/// Nearby retains reservations and offers; the incoming session owns approval cleanup.
enum AcornryApprovalExchange {
  private enum WaitResult: Sendable {
    case decision(AcornryApprovalDecision)
    case remote(AcornryFrame)
  }

  static func wait(
    transferID: AcornryTransferID,
    token: UUID,
    framed: AcornryFramedConnection,
    approvals: AcornryApprovalRegistry,
    remoteBudget: Duration,
    idleTimeout: Duration
  ) async throws -> (AcornryApprovalDecision, AcornryFrame?) {
    try await withThrowingTaskGroup(of: WaitResult.self) { group in
      group.addTask { [approvals] in
        .decision(try await approvals.wait(for: transferID, token: token))
      }
      group.addTask { .remote(try await framed.receive(timeout: remoteBudget)) }
      defer { group.cancelAll() }

      guard let first = try await group.next() else {
        throw AcornryError.connectionClosed
      }
      switch first {
      case .remote(let frame):
        group.cancelAll()
        guard frame.kind == .cancel else {
          throw AcornryError.protocolViolation(
            "only cancel is valid while awaiting receiver approval")
        }
        let cancel = try AcornryWire.decodeJSON(AcornryCancel.self, from: frame.payload)
        guard cancel.transferID == transferID else {
          throw AcornryError.protocolViolation("cancel id mismatch while awaiting approval")
        }
        return (.init(accepted: false, reason: "cancelled"), nil)

      case .decision(let decision):
        try await framed.send(
          .decision,
          AcornryDecision(
            transferID: transferID,
            accepted: decision.accepted,
            reason: decision.reason))
        if !decision.accepted {
          group.cancelAll()
          return (decision, nil)
        }
        group.addTask {
          try await Task.sleep(for: idleTimeout)
          throw AcornryError.protocolTimedOut
        }
        guard let second = try await group.next() else {
          throw AcornryError.connectionClosed
        }
        guard case .remote(let frame) = second else {
          throw AcornryError.invalidState("approval race returned duplicate decision")
        }
        return (decision, frame)
      }
    }
  }
}
