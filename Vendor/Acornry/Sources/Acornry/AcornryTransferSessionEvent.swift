/// Internal effects reported by a protocol session to the façade's single state owner.
/// These values are neither wire messages nor persisted recovery records.
enum AcornryTransferSessionEvent: Sendable {
  case progress(AcornryTransferProgress)
  case phase(AcornryTransferID, AcornryTransferPhase)
  case outgoingStarted(AcornryTransferID, AcornryPeerID)
  case offer(AcornryIncomingOffer, AcornryTransferProgress)
  case removeOffer(AcornryTransferID)
  case received(AcornryTransferReceipt, peerID: AcornryPeerID, totalBytes: Int64)
  case receiptDeliveryFailed(AcornryTransferID, String)
  case failed(AcornryTransferID, String)
}
