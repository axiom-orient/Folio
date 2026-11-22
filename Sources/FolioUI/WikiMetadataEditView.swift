import FolioKnowledge
import SwiftUI

struct WikiMetadataSelection: Identifiable {
  let id = UUID()
  let document: WikiDocument
  let context: FolioDocumentContext
}

struct WikiMetadataEditView: View {
  enum Submission { case editing, saving, failed(String) }
  let model: WikiAppModel
  let selection: WikiMetadataSelection
  @State private var title: String
  @State private var tags: [String]
  @State private var newTag = ""
  @State private var submission: Submission = .editing
  @State private var confirmClose = false
  @Environment(\.dismiss) private var dismiss

  init(model: WikiAppModel, selection: WikiMetadataSelection) {
    self.model = model; self.selection = selection
    _title = State(initialValue: selection.document.title)
    _tags = State(initialValue: selection.document.tags)
  }
  private var saving: Bool { if case .saving = submission { true } else { false } }
  private var pendingTag: String { newTag.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var changed: Bool { (FolioInput.name(title) ?? title) != selection.document.title || tags != selection.document.tags || !pendingTag.isEmpty }

  var body: some View {
    NavigationStack {
      Form {
        Section("제목") {
          TextField("문서 제목", text: $title).accessibilityIdentifier("metadata-title")
        }
        Section("태그") {
          ForEach(tags, id: \.self) { tag in
            HStack {
              Text(tag).textSelection(.enabled)
              Spacer()
              Button("태그 제거", systemImage: "xmark.circle") { tags.removeAll { WikiTags.key($0) == WikiTags.key(tag) } }
                .labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityLabel("\(tag) 태그 제거")
            }
          }
          HStack {
            TextField("새 태그", text: $newTag).onSubmit(addTag).accessibilityIdentifier("metadata-new-tag")
            Button("추가", action: addTag).disabled(pendingTag.isEmpty)
          }
        }
        if case .failed(let message) = submission { FolioMessage(message: message) }
      }.formStyle(.grouped).disabled(saving)
      .navigationTitle("제목·태그 편집")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("취소", action: close).disabled(saving) }
        ToolbarItem(placement: .confirmationAction) {
          Button("저장", action: save).disabled(saving || model.documentLibrary.phase.isBusy || !changed || FolioInput.name(title) == nil)
            .keyboardShortcut(.defaultAction).accessibilityIdentifier("metadata-save")
        }
      }
      .interactiveDismissDisabled(changed || saving)
      .confirmationDialog("변경을 저장하지 않고 닫을까요?", isPresented: $confirmClose, titleVisibility: .visible) {
        Button("변경 버리고 닫기", role: .destructive) { dismiss() }
        Button("계속 편집", role: .cancel) {}
      }
    }.folioSheetSize(width: 500, height: 440)
  }

  private func addTag() {
    do {
      tags = try WikiTags.normalize(tags + [newTag])
      newTag = ""; submission = .editing
    } catch { submission = .failed(error.localizedDescription) }
  }
  private func close() { if changed { confirmClose = true } else { dismiss() } }
  private func save() {
    guard !saving, let title = FolioInput.name(title) else { return }
    do {
      let submitted = try WikiTags.normalize(tags + (pendingTag.isEmpty ? [] : [pendingTag]))
      submission = .saving
      Task {
        if await model.updateDocumentMetadata(selection, title: title, tags: submitted) { dismiss() }
        else { submission = .failed(model.message ?? "변경을 저장하지 못했습니다. 현재 원문을 확인해 주세요.") }
      }
    } catch { submission = .failed(error.localizedDescription) }
  }
}
