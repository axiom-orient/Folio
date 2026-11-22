import FolioCore
import SwiftUI

/// Local native text remains authoritative until an atomic recovery checkpoint succeeds.
/// A failed disk write must never reset the editor to an older session value.
@MainActor
struct FolioDocumentEditor: View {
  let session: FolioSession
  let document: FolioDocument
  let target: FolioEditingTarget?
  @Binding var message: String?
  let preservationChanged: @MainActor (Bool) -> Void
  @State private var text: String
  @State private var checkpointFailed = false
  @State private var comparison: SourceComparison?

  init(session: FolioSession, document: FolioDocument, message: Binding<String?>,
    preservationChanged: @escaping @MainActor (Bool) -> Void
  ) {
    self.session = session
    self.document = document
    target = session.editingTarget
    _message = message
    self.preservationChanged = preservationChanged
    _text = State(initialValue: session.draftText)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(document.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if checkpointFailed {
        Label("복구본을 보관하지 못했습니다. 입력은 이 화면에 남아 있습니다.", systemImage: "exclamationmark.triangle")
          .font(.caption)
        Button("복구본 보관 다시 시도", action: checkpoint)
          .disabled(session.isBusy)
      } else {
        Text(session.isDirty ? "저장하지 않은 편집이 있습니다" : "저장된 원문")
          .font(.caption).foregroundStyle(.secondary)
      }
      TextEditor(text: Binding(get: { text }, set: { replacement in
        text = replacement
        checkpoint()
      }))
      .font(.body.monospaced())
      .accessibilityLabel("Markdown 원문과 초안")
      .accessibilityIdentifier("folio-sdk-editor")
      .disabled(session.isBusy)
    }
    .padding()
    .navigationTitle(document.title)
    .onChange(of: session.draftText) { previous, replacement in
      if !checkpointFailed, text == previous { text = replacement }
    }
    .sheet(item: $comparison) { comparison in
      FolioSourceComparisonView(session: session, target: target, review: comparison.review, text: comparison.text,
        pendingOperationID: comparison.pendingOperationID) { replacement, failed in
        text = replacement
        checkpointFailed = failed
        preservationChanged(failed)
      }
    }
    .toolbar {
      ToolbarItem {
        Button("현재 원문과 비교", systemImage: "doc.on.doc") {
          let pendingOperationID = session.pendingOperationID
          Task {
            do {
              guard let target else { throw FolioError.noDocument }
              let review = try await session.readCurrentSource(target: target)
              comparison = SourceComparison(review: review, text: text, pendingOperationID: pendingOperationID)
            } catch { message = error.localizedDescription }
          }
        }
        .disabled(session.isBusy || checkpointFailed)
      }
      ToolbarItem {
        ShareLink(item: text) {
          Label("편집 복사본 공유", systemImage: "square.and.arrow.up")
        }
      }
      ToolbarItem {
        if session.pendingOperationID != nil {
          Button("저장 결과 확인", systemImage: "arrow.clockwise") {
            Task {
              do {
                guard let target else { throw FolioError.noDocument }
                switch try await session.resolvePendingSave(target: target) {
                case .committed: message = "저장된 원문을 확인했습니다."
                case .notObserved: message = "원문 반영을 확인하지 못했습니다. 초안을 보존했습니다."
                case .uncertain: message = "저장 결과가 아직 불확실합니다. 초안을 공유해 보관하고 다시 확인해 주세요."
                }
              } catch { message = error.localizedDescription }
            }
          }
          .disabled(session.isBusy || checkpointFailed)
        }
      }
      ToolbarItem {
        Button("저장", systemImage: "square.and.arrow.down") {
          Task {
            do {
              guard let target else { throw FolioError.noDocument }
              try await session.save(target: target)
            }
            catch { message = error.localizedDescription }
          }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(session.isBusy || !session.isDirty || session.pendingOperationID != nil || checkpointFailed)
      }
    }
  }

  private func checkpoint() {
    do {
      guard let target else { throw FolioError.noDocument }
      try session.updateDraft(text, target: target)
      checkpointFailed = false
      preservationChanged(false)
    } catch {
      checkpointFailed = true
      preservationChanged(true)
      message = error.localizedDescription
    }
  }

  private struct SourceComparison: Identifiable {
    let id = UUID()
    let review: FolioSourceReview
    let text: String
    let pendingOperationID: UUID?
  }
}

