import Foundation

/// Executes one outgoing protocol exchange inside the façade's reserved task.
/// The journal remains the authority for a dispatch whose receipt was not observed.
struct AcornryOutgoingTransferSession: Sendable {
  let configuration: AcornryConfiguration
  let journal: AcornryOperationJournal
  let event: @Sendable (AcornryTransferSessionEvent) async -> Void

  func run(
    _ prepared: AcornryPreparedTransfer, to peer: AcornryPeer,
    framed: AcornryFramedConnection,
    isolation: isolated (any Actor)? = #isolation
  ) async throws -> AcornryTransferReceipt {
    let transferID = prepared.manifest.transferID
    var commitMayHaveOccurred = false
    do {
      try await journal.bind(prepared.manifest, to: peer.id)
      try Task.checkCancellation()
      await event(.outgoingStarted(transferID, peer.id))
      try await framed.send(.offer, AcornryOffer(manifest: prepared.manifest))
      let response = try await framed.receive(timeout: configuration.approvalExchangeTimeout)
      switch response.kind {
      case .receipt:
        let receipt = try AcornryWire.decodeJSON(
          AcornryTransferReceipt.self, from: response.payload)
        try receipt.validate(for: prepared.manifest)
        try await journal.settle(receipt)
        await framed.close()
        return receipt
      case .decision:
        let decision = try AcornryWire.decodeJSON(AcornryDecision.self, from: response.payload)
        guard decision.transferID == transferID else {
          throw AcornryError.protocolViolation("decision transfer id mismatch")
        }
        guard decision.accepted else {
          throw AcornryError.transferRejected(transferID, decision.reason)
        }
      case .protocolError:
        let value = try AcornryWire.decodeJSON(
          AcornryProtocolErrorPayload.self, from: response.payload)
        if value.code == "transfer_conflict" {
          throw AcornryError.transferConflict(transferID)
        }
        throw AcornryError.protocolViolation("\(value.code): \(value.detail)")
      default:
        throw AcornryError.protocolViolation("expected decision, got \(response.kind)")
      }

      await event(.phase(transferID, .transferring))
      var completedBytes: Int64 = 0
      for (fileIndex, pair) in zip(
        prepared.manifest.files.indices, zip(prepared.manifest.files, prepared.sources))
      {
        try Task.checkCancellation()
        let (entry, source) = pair
        try AcornryPath.requireRegularFile(source.fileURL)
        let handle = try FileHandle(forReadingFrom: source.fileURL)
        var hasher = AcornrySHA256()
        var offset: Int64 = 0
        do {
          while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: configuration.limits.chunkBytes) ?? Data()
            guard !chunk.isEmpty else { break }
            let payload = try AcornryWire.encodeChunk(
              transferID: transferID,
              fileIndex: fileIndex,
              offset: offset,
              bytes: chunk)
            try await framed.send(.chunk, payload: payload)
            hasher.update(chunk)
            offset += Int64(chunk.count)
            await event(.progress(
              .init(
                transferID: transferID,
                direction: .outgoing,
                peerID: peer.id,
                phase: .transferring,
                completedBytes: completedBytes + offset,
                totalBytes: prepared.manifest.totalBytes,
                completedFiles: fileIndex,
                totalFiles: prepared.manifest.files.count)))
          }
          try handle.close()
        } catch {
          try? handle.close()
          throw error
        }
        guard offset == entry.byteCount, hasher.finalizeHex() == entry.checksumSHA256 else {
          try? await framed.send(
            .cancel,
            AcornryCancel(
              transferID: transferID, reason: "source_changed"))
          throw AcornryError.sourceChanged(entry.relativePath)
        }
        try await framed.send(
          .fileEnd,
          AcornryFileEnd(
            transferID: transferID,
            fileIndex: fileIndex,
            byteCount: entry.byteCount,
            checksumSHA256: entry.checksumSHA256))
        completedBytes += entry.byteCount
        await event(.progress(
          .init(
            transferID: transferID,
            direction: .outgoing,
            peerID: peer.id,
            phase: .transferring,
            completedBytes: completedBytes,
            totalBytes: prepared.manifest.totalBytes,
            completedFiles: fileIndex + 1,
            totalFiles: prepared.manifest.files.count)))
      }

      try Task.checkCancellation()
      try await journal.markAwaitingReceipt(transferID)
      commitMayHaveOccurred = true
      try await framed.send(.transferEnd, AcornryTransferEnd(transferID: transferID))
      let final = try await framed.receive()
      guard final.kind == .receipt else {
        throw AcornryError.protocolViolation("receipt required after transfer end")
      }
      let receipt = try AcornryWire.decodeJSON(AcornryTransferReceipt.self, from: final.payload)
      try receipt.validate(for: prepared.manifest)
      try await journal.settle(receipt)
      await framed.close()
      return receipt
    } catch {
      await framed.close()
      if commitMayHaveOccurred { throw AcornryError.outcomeUnknown(transferID) }
      if Task.isCancelled || error is CancellationError { throw AcornryError.operationCancelled }
      throw error
    }
  }

  func reconcile(
    _ record: AcornryOutgoingRecord, with peer: AcornryPeer,
    framed: AcornryFramedConnection,
    isolation: isolated (any Actor)? = #isolation
  ) async throws -> AcornryTransferReceipt? {
    let transferID = record.transferID
    do {
      await event(.progress(
        .init(
          transferID: transferID, direction: .outgoing, peerID: peer.id, phase: .outcomeUnknown,
          completedBytes: 0, totalBytes: record.manifest.totalBytes, completedFiles: 0,
          totalFiles: record.manifest.files.count)))
      try await framed.send(
        .receiptQuery,
        AcornryReceiptQuery(
          transferID: transferID, expectedManifestDigestSHA256: record.manifest.digestSHA256()))
      let response = try await framed.receive()
      let receipt: AcornryTransferReceipt?
      switch response.kind {
      case .receipt:
        let value = try AcornryWire.decodeJSON(
          AcornryTransferReceipt.self, from: response.payload)
        try value.validate(for: record.manifest)
        try await journal.settle(value)
        receipt = value
      case .receiptUnavailable:
        let value = try AcornryWire.decodeJSON(
          AcornryReceiptUnavailable.self, from: response.payload)
        guard value.transferID == transferID else {
          throw AcornryError.protocolViolation("receipt unavailable id mismatch")
        }
        receipt = nil
      case .protocolError:
        let value = try AcornryWire.decodeJSON(
          AcornryProtocolErrorPayload.self, from: response.payload)
        if value.code == "transfer_conflict" { throw AcornryError.transferConflict(transferID) }
        throw AcornryError.protocolViolation("\(value.code): \(value.detail)")
      default:
        throw AcornryError.protocolViolation("unexpected reconcile response \(response.kind)")
      }
      await framed.close()
      return receipt
    } catch {
      await framed.close()
      throw error
    }
  }
}
