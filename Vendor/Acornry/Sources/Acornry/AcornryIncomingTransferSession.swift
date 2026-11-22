import Foundation

/// One receive exchange. Nearby retains connection reservations and observable state.
struct AcornryIncomingTransferSession: Sendable {
  let configuration: AcornryConfiguration
  let receiveStore: AcornryReceiveStore
  let fileStore: AcornryFileStore
  let journal: AcornryOperationJournal
  let approvals: AcornryApprovalRegistry
  let event: @Sendable (AcornryTransferSessionEvent) async -> Void

  func run(
    manifest: AcornryTransferManifest, from peer: AcornryPeer,
    over channel: any AcornryByteConnection, framed: AcornryFramedConnection,
    isolation: isolated (any Actor)? = #isolation
  ) async throws {
    let transferID = manifest.transferID
    var approvalToken: UUID?
    var stagingBegan = false
    var stagingFinalized = false
    var ownsProgress = false
    var offerPending = false
    do {
      try Task.checkCancellation()
      if try await journal.record(transferID) != nil {
        throw AcornryError.transferConflict(transferID)
      }
      if let completed = try await fileStore.completedReceipt(for: manifest) {
        try await framed.send(
          .receipt, AcornryTransferReceipt(local: completed, manifest: manifest))
        return
      }
      try Task.checkCancellation()
      if configuration.incomingPolicy == .requireApproval {
        approvalToken = try await approvals.prepare(
          transferID, timeout: configuration.approvalTimeout)
        try Task.checkCancellation()
      }
      let now = Date()
      let incoming = AcornryIncomingOffer(
        manifest: manifest, transport: channel.transportKind, receivedAt: now,
        expiresAt: now.addingTimeInterval(configuration.approvalExpirationInterval))
      ownsProgress = true
      offerPending = true
      await event(
        .offer(
          incoming,
          .init(
            transferID: transferID, direction: .incoming, peerID: peer.id,
            phase: configuration.incomingPolicy == .automatic ? .transferring : .awaitingApproval,
            completedBytes: 0, totalBytes: manifest.totalBytes, completedFiles: 0,
            totalFiles: manifest.files.count)))
      let decision: AcornryApprovalDecision
      var prefetchedFrame: AcornryFrame?
      if let token = approvalToken {
        (decision, prefetchedFrame) = try await AcornryApprovalExchange.wait(
          transferID: transferID, token: token, framed: framed, approvals: approvals,
          remoteBudget: configuration.approvalExchangeTimeout,
          idleTimeout: configuration.protocolIdleTimeout)
        await approvals.discard(transferID, token: token)
        approvalToken = nil
      } else {
        decision = .init(accepted: true, reason: nil)
        try await framed.send(
          .decision, AcornryDecision(transferID: transferID, accepted: true, reason: nil))
      }
      await event(.removeOffer(transferID))
      offerPending = false
      guard decision.accepted else {
        await event(.phase(transferID, decision.reason == "cancelled" ? .cancelled : .rejected))
        return
      }
      try Task.checkCancellation()
      try await receiveStore.begin(manifest, limits: configuration.limits)
      stagingBegan = true
      await event(.phase(transferID, .transferring))
      var currentFile = 0
      var completedBytes: Int64 = 0
      while true {
        try Task.checkCancellation()
        let frame: AcornryFrame
        if let first = prefetchedFrame {
          frame = first
          prefetchedFrame = nil
        } else {
          frame = try await framed.receive()
        }
        switch frame.kind {
        case .chunk:
          guard currentFile < manifest.files.count else {
            throw AcornryError.protocolViolation("chunk after all files completed")
          }
          let (id, fileIndex, offset, bytes) = try AcornryWire.decodeChunk(frame.payload)
          guard id == transferID, fileIndex == currentFile, !bytes.isEmpty else {
            throw AcornryError.protocolViolation("unexpected chunk order")
          }
          try await receiveStore.appendChunk(
            transferID: id, fileIndex: fileIndex, offset: offset, bytes: bytes)
          await event(
            .progress(
              .init(
                transferID: transferID, direction: .incoming, peerID: peer.id, phase: .transferring,
                completedBytes: completedBytes + offset + Int64(bytes.count),
                totalBytes: manifest.totalBytes,
                completedFiles: currentFile, totalFiles: manifest.files.count)))
        case .fileEnd:
          let end = try AcornryWire.decodeJSON(AcornryFileEnd.self, from: frame.payload)
          guard currentFile < manifest.files.count, end.transferID == transferID,
            end.fileIndex == currentFile
          else {
            throw AcornryError.protocolViolation("unexpected file end order")
          }
          try await receiveStore.finishFile(end)
          completedBytes += manifest.files[currentFile].byteCount
          currentFile += 1
          await event(
            .progress(
              .init(
                transferID: transferID, direction: .incoming, peerID: peer.id, phase: .transferring,
                completedBytes: completedBytes, totalBytes: manifest.totalBytes,
                completedFiles: currentFile, totalFiles: manifest.files.count)))
        case .transferEnd:
          let end = try AcornryWire.decodeJSON(AcornryTransferEnd.self, from: frame.payload)
          guard end.transferID == transferID, currentFile == manifest.files.count else {
            throw AcornryError.protocolViolation("transfer ended before all files completed")
          }
          let staged = try await receiveStore.finalize(transferID)
          stagingFinalized = true
          try Task.checkCancellation()
          await event(.phase(transferID, .committing))
          let local = try await fileStore.commit(staged)
          let remote = try AcornryTransferReceipt(local: local, manifest: manifest)
          await event(.received(remote, peerID: peer.id, totalBytes: manifest.totalBytes))
          do { try await framed.send(.receipt, remote) } catch {
            // The local receipt remains authoritative. Expose delivery failure without changing saved state.
            await event(.receiptDeliveryFailed(transferID, String(describing: error)))
          }
          return
        case .cancel:
          let cancel = try AcornryWire.decodeJSON(AcornryCancel.self, from: frame.payload)
          guard cancel.transferID == transferID else {
            throw AcornryError.protocolViolation("cancel id mismatch")
          }
          try await receiveStore.abort(transferID, removeStaging: true)
          stagingBegan = false
          await event(.phase(transferID, .cancelled))
          return
        default: throw AcornryError.protocolViolation("unexpected transfer frame \(frame.kind)")
        }
      }
    } catch {
      if let token = approvalToken { await approvals.discard(transferID, token: token) }
      if ownsProgress {
        let cancelled =
          Task.isCancelled || error is CancellationError
          || error as? AcornryError == .operationCancelled
          || (offerPending && error as? AcornryError == .connectionClosed)
        await event(.phase(transferID, cancelled ? .cancelled : .failed))
      }
      if stagingBegan && !stagingFinalized {
        do { try await receiveStore.abort(transferID, removeStaging: true) } catch let cleanup {
          throw AcornryError.invalidState(
            "receive failed: \(error); staging cleanup failed: \(cleanup)")
        }
      }
      if case AcornryError.transferConflict = error {
        do {
          try await framed.send(
            .protocolError,
            AcornryProtocolErrorPayload(
              code: "transfer_conflict", detail: String(describing: error)))
        } catch let delivery {
          await event(.failed(transferID, "conflict delivery failed: \(delivery)"))
        }
      }
      throw error
    }
  }

  func answerReceiptQuery(
    _ frame: AcornryFrame,
    from peer: AcornryPeer,
    framed: AcornryFramedConnection,
    isolation: isolated (any Actor)? = #isolation
  ) async throws {
    let query = try AcornryWire.decodeJSON(AcornryReceiptQuery.self, from: frame.payload)
    if let receipt = try await fileStore.transferReceipt(
      for: query.transferID,
      expectedManifestDigest: query.expectedManifestDigestSHA256,
      requestingPeerID: peer.id)
    {
      try await framed.send(.receipt, receipt)
    } else {
      try await framed.send(
        .receiptUnavailable, AcornryReceiptUnavailable(transferID: query.transferID))
    }
  }
}
