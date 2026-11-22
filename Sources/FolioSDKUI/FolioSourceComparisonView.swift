import FolioCore
import SwiftUI

@MainActor
struct FolioSourceComparisonView: View {
  let session: FolioSession
  let target: FolioEditingTarget?
  let pendingOperationID: UUID?
  let draftChanged: @MainActor (String, Bool) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var review: FolioSourceReview
  @State private var text: String
  @State private var checkpointFailed = false
  @State private var message: String?

  init(session: FolioSession, target: FolioEditingTarget?, review: FolioSourceReview, text: String,
    pendingOperationID: UUID?,
    draftChanged: @escaping @MainActor (String, Bool) -> Void
  ) {
    self.session = session
    self.target = target
    self.pendingOperationID = pendingOperationID
    self.draftChanged = draftChanged
    _review = State(initialValue: review)
    _text = State(initialValue: text)
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        Text("현재 원문과 초안을 검토하고 아래 초안에 필요한 변경을 반영하세요. 초안을 준비한 뒤에도 저장은 별도로 실행합니다.")
          .font(.callout)
        if pendingOperationID != nil {
          Text("이전 저장 결과가 아직 확정되지 않았습니다. 확인한 원문과 미확정 저장 초안을 복사본으로 보존한 뒤 새 초안을 준비합니다. 이전 저장을 재실행하지 않으며 원문 반영은 별도 저장으로 결정합니다.")
            .font(.callout)
        }
        DisclosureGroup("확인한 현재 원문") {
          ScrollView {
            Text(review.text).font(.body.monospaced()).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 220)
          Text(review.revision).font(.caption2.monospaced()).textSelection(.enabled)
        }
        Text("편집할 초안").font(.headline)
        TextEditor(text: Binding(get: { text }, set: { replacement in
          text = replacement
          checkpoint()
        }))
        .font(.body.monospaced())
        .accessibilityLabel("검토 후 병합할 초안")
        .disabled(session.isBusy)
        if checkpointFailed {
          Text("입력은 이 화면에 남아 있습니다. 복구본을 보관하거나 편집 복사본을 공유해 주세요.").font(.caption)
          Button("복구본 보관 다시 시도", action: checkpoint)
        }
        Button(pendingOperationID == nil ? "확인한 원문을 기준으로 초안 준비" : "미확정 저장 복사본을 보존하고 새 초안 준비") {
          let submittedText = text
          let submittedReview = review
          Task {
            do {
              try await session.adoptReviewedSource(submittedReview, mergedText: submittedText,
                resolvingPendingSave: pendingOperationID)
            } catch {
              message = error.localizedDescription
              return
            }
            // Disabling a native editor can finish a composition while source
            // review is suspended. Retain that later input before dismissing.
            do {
              if text != submittedText {
                guard let target else { throw FolioError.noDocument }
                try session.updateDraft(text, target: target)
              }
              checkpointFailed = false
              draftChanged(text, false)
              dismiss()
            } catch {
              checkpointFailed = true
              draftChanged(text, true)
              message = error.localizedDescription
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(session.isBusy || checkpointFailed)
      }
      .padding()
      .navigationTitle("원문과 초안 비교")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("닫기") { dismiss() }.disabled(session.isBusy || checkpointFailed)
        }
        ToolbarItem {
          ShareLink(item: text) { Label("편집 복사본 공유", systemImage: "square.and.arrow.up") }
        }
        ToolbarItem {
          Button("원문 다시 확인", systemImage: "arrow.clockwise") {
            Task {
              do {
                guard let target else { throw FolioError.noDocument }
                review = try await session.readCurrentSource(target: target)
              }
              catch { message = error.localizedDescription }
            }
          }
          .disabled(session.isBusy)
        }
      }
    }
    .interactiveDismissDisabled(session.isBusy || checkpointFailed)
    .alert("원문 검토", isPresented: Binding(
      get: { message != nil }, set: { if !$0 { message = nil } }
    )) {
      Button("확인", role: .cancel) { message = nil }
    } message: { Text(message ?? "") }
  }

  private func checkpoint() {
    do {
      guard let target else { throw FolioError.noDocument }
      try session.updateDraft(text, target: target)
      checkpointFailed = false
      draftChanged(text, false)
    } catch {
      checkpointFailed = true
      draftChanged(text, true)
      message = error.localizedDescription
    }
  }
}
