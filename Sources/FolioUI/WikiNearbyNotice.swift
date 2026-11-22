import FolioNearbyTransport
import SwiftUI

/// Only active work and unresolved delivery belong beside the current document.
/// Historical receipts remain available in the inbox.
struct WikiNearbyNotice: View {
  let model: WikiAppModel
  let openInbox: (UUID?) -> Void
  private var transfer: FolioNearbyModel { model.nearby }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let offer = transfer.snapshot?.incomingOffers.first {
        Text(offer.manifest.displayName).font(.headline).fixedSize(horizontal: false, vertical: true)
        Text("\(offer.manifest.sender.displayName) · \(ByteCountFormatter.string(fromByteCount: offer.manifest.totalBytes, countStyle: .file))")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("받기") { Task { await transfer.accept(offer) } }.buttonStyle(.borderedProminent)
          Button("거절") { Task { await transfer.reject(offer.id) } }.buttonStyle(.borderless)
        }
      } else if let progress = transfer.activeTransfers.last {
        HStack {
          Text(progressLabel(progress)).font(.callout)
          Spacer()
          Button("취소") { Task { await transfer.cancel(progress.id) } }.buttonStyle(.borderless)
        }
        if progress.phase == .transferring && progress.totalBytes > 0 {
          ProgressView(value: Double(max(0, min(progress.completedBytes, progress.totalBytes))), total: Double(progress.totalBytes))
        } else { ProgressView().controlSize(.small) }
      } else if transfer.isWorking {
        HStack {
          ProgressView(); Text("파일 처리 중…").font(.callout); Spacer()
          if transfer.canCancelPreparation { Button("취소") { transfer.cancelPreparation() }.buttonStyle(.borderless) }
        }
      }
      if let message = inlineMessage {
        HStack(alignment: .top, spacing: 12) {
          Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          if transfer.needsDeliveryReview {
            Button("전송 확인") { openInbox(nil) }.buttonStyle(.borderless)
              .accessibilityIdentifier("transfer-delivery-review")
          }
          Button("알림 닫기", systemImage: "xmark") { transfer.message = nil }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
      }
    }
    .padding(hasContent ? 16 : 0).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
  }

  private var hasContent: Bool {
    transfer.snapshot?.incomingOffers.isEmpty == false || !transfer.activeTransfers.isEmpty || transfer.isWorking
      || transfer.needsDeliveryReview || transfer.message != nil
  }
  private var inlineMessage: String? {
    guard hasContent else { return nil }
    return transfer.message ?? (transfer.needsDeliveryReview ? "상대 기기의 저장 결과를 확인해 주세요." : nil)
  }
  private func progressLabel(_ progress: AcornryTransferProgress) -> String {
    switch progress.phase {
    case .awaitingApproval: progress.direction == .outgoing ? "상대가 받기를 기다리는 중…" : "수신 승인 대기 중…"
    case .committing: progress.direction == .incoming ? "받은 파일 저장 중…" : "상대의 저장 결과 확인 중…"
    case .transferring: progress.direction == .incoming ? "파일 받는 중…" : "파일 보내는 중…"
    default: "전송 준비 중…"
    }
  }
}
