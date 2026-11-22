import SwiftUI
import FolioKnowledge

struct WikiSourceRepairView: View {
  let model: WikiAppModel
  let selection: WikiAppModel.RepairSelection
  @State private var isEditing: Bool
  @State private var isSaving = false
  @State private var closingText: String?
  @State private var discardText: String?
  @State private var showObservedSource = false
  @Environment(\.dismiss) private var dismiss

  init(model: WikiAppModel, selection: WikiAppModel.RepairSelection) {
    self.model = model; self.selection = selection
    _isEditing = State(initialValue: selection.path != "_ontology.md")
    _showObservedSource = State(initialValue: selection.path == "_ontology.md")
  }
  private var currentSource: Bool {
    model.hasOpenWorkspace && model.openedSourceRoot == selection.sourceRoot
      && model.snapshot?.workspace.id == selection.workspaceID
      && selection.documentGeneration == model.documentContextGeneration
  }
  private var currentEditingOwner: Bool {
    !selection.isResolved && model.canAcceptPrivateEdits && model.openedSourceRoot == selection.sourceRoot
      && model.snapshot?.workspace.id == selection.workspaceID
      && selection.documentGeneration == model.documentContextGeneration
  }
  private var contentText: String { selection.draftID.flatMap { model.drafts[$0]?.text } ?? selection.editedText }
  private var isDraftDocument: Bool {
    guard selection.draftID != nil, selection.path != "_ontology.md" else { return false }
    // The normal body-only flow must not silently conceal metadata that would
    // be replaced by the remaining explicit, advanced repair route.
    guard let received = selection.observedSourceText else { return true }
    return Data(FolioEditorContent(source: selection.text).metadata.utf8)
      == Data(FolioEditorContent(source: received).metadata.utf8)
  }
  private var editorText: Binding<String> {
    let generation = model.editorGeneration
    return Binding(get: {
      isDraftDocument ? FolioEditorContent(source: contentText).body : contentText
    }, set: { value in
      guard currentEditingOwner else { return }
      let replacement = isDraftDocument ? FolioEditorContent(source: contentText).replacingBody(with: value) : value
      if let id = selection.draftID { model.editText(replacement, documentID: id, generation: generation) }
      else { selection.edit(value) }
    })
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if !isDraftDocument {
          HStack {
            if isEditing {
              Text(selection.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            sourceOptions
          }.padding(.horizontal, 24).padding(.top, 16)
        }
        if selection.draftID != nil {
          WikiDraftSourceReview(observedSourceText: selection.observedSourceText,
            availability: selection.sourceAvailability, bodyOnly: isDraftDocument, showObservedSource: $showObservedSource)
        }
        if isEditing {
          WikiRawEditor(text: editorText, documentID: selection.path, canEdit: { currentEditingOwner })
            .disabled(!currentEditingOwner)
            #if os(iOS)
            .frame(minHeight: 120)
            #endif
            .padding(16)
        } else { WikiOntologyRules(source: contentText) }
        if !currentSource {
          FolioMessage(message: "자료함이 바뀌었습니다. 원래 자료함에서 다시 열어 주세요.").padding()
        }
        if let message = model.message { FolioMessage(message: message).padding() }
      }
      .navigationTitle(selection.path == "_ontology.md" ? "관계 규칙" : selection.draftID == nil ? "원문 복구" : "편집 계속")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("닫기", action: close) }
        if isDraftDocument {
          ToolbarItem(placement: .secondaryAction) { sourceOptions }
        }
        ToolbarItem(placement: .confirmationAction) {
          if isEditing {
            Button(isSaving ? "저장 중…" : "저장", action: save)
              .disabled(!currentSource || !selection.sourceAvailability.allowsSave || selection.isResolved || isSaving
                || (contentText == selection.text && selection.draftID == nil))
              .keyboardShortcut("s", modifiers: .command)
              .accessibilityIdentifier("draft-recovery-save")
          } else { Button("원문 편집") { isEditing = true }.disabled(!currentSource) }
        }
      }
      .disabled(isSaving)
      .interactiveDismissDisabled(isSaving || selection.hasUnsavedInput)
      .alert("저장하지 않고 닫을까요?", isPresented: Binding(
        get: { closingText != nil }, set: { if !$0 { closingText = nil } }), presenting: closingText) { expectedText in
        Button("편집 버리고 닫기", role: .destructive) {
          guard selection.discardChanges(matching: expectedText) else {
            model.message = "편집 내용이 바뀌었습니다. 다시 확인해 주세요."
            return
          }
          dismiss()
        }
        Button("계속 편집", role: .cancel) {}
      } message: { _ in Text("이번 화면에서 바꾼 원문은 저장하지 않습니다.") }
      .confirmationDialog("편집을 취소할까요?", isPresented: Binding(
        get: { discardText != nil }, set: { if !$0 { discardText = nil } }),
        titleVisibility: .visible, presenting: discardText) { expectedText in
        Button("편집 취소", role: .destructive) {
          guard currentSource, let id = selection.draftID else { return }
          guard model.drafts[id]?.text == expectedText else { model.message = "편집 내용이 바뀌었습니다. 다시 확인해 주세요."; return }
          model.removeDraft(id: id); dismiss()
        }
        Button("취소", role: .cancel) {}
      } message: { _ in Text("저장하지 않은 변경을 취소합니다. 저장한 문서는 유지됩니다.") }
    }.folioSheetSize(width: 600, height: 540)
  }

  private func close() {
    if selection.draftID != nil { model.persistDrafts(); dismiss() }
    else if selection.hasUnsavedInput { closingText = contentText }
    else { dismiss() }
  }

  private func save() {
    guard !isSaving, currentSource, selection.sourceAvailability.allowsSave else { return }
    isSaving = true
    let replacement = contentText
    Task { await model.repairSource(selection, text: replacement); isSaving = false }
  }

  private var sourceOptions: some View {
    Menu(isDraftDocument ? "편집 옵션" : "원문 옵션", systemImage: "ellipsis") {
      ShareLink(item: contentText) { Label(isDraftDocument ? "편집 내용 공유" : "편집 복사본 공유", systemImage: "square.and.arrow.up") }
      if selection.draftID != nil {
        Button(isDraftDocument ? "받은 내용 다시 확인" : "현재 원문 다시 확인") {
          if let id = selection.draftID { Task { await model.showDraftRecovery(id: id) } }
        }.disabled(!currentSource)
        Button("편집 취소", role: .destructive) { discardText = contentText }.disabled(!currentSource)
      }
    }.menuStyle(.borderlessButton).fixedSize()
  }
}

private struct WikiOntologyRules: View {
  let source: String

  var body: some View {
    Form {
      if let ontology = try? WikiOntology(bytes: Data(source.utf8)) {
        Section("문서 유형") {
          if ontology.types.isEmpty { Text("등록한 유형이 없습니다.").foregroundStyle(.secondary) }
          ForEach(ontology.types.sorted(), id: \.self) { type in
            LabeledContent(FolioTheme.typeName(type), value: type)
          }
        }
        Section("연결 규칙") {
          if ontology.relations.isEmpty { Text("Markdown 링크로 문서를 연결할 수 있습니다.").foregroundStyle(.secondary) }
          ForEach(ontology.relations.keys.sorted(), id: \.self) { predicate in
            if let rule = ontology.relations[predicate] {
              VStack(alignment: .leading, spacing: 6) {
                Text(predicate).font(.body.weight(.medium))
                Text(rule.from.sorted().map { FolioTheme.typeName($0) }.joined(separator: ", ")
                  + " → " + rule.to.sorted().map { FolioTheme.typeName($0) }.joined(separator: ", "))
                  .font(.callout).foregroundStyle(.secondary)
              }
            }
          }
        }
      } else {
        Section { FolioMessage(message: "규칙을 읽지 못했습니다. 원문 편집에서 형식을 확인하세요.") }
      }
      Section {
        DisclosureGroup("원문 보기") { Text(source).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
      }
    }.formStyle(.grouped)
  }
}

private struct WikiDraftSourceReview: View {
  let observedSourceText: String?
  let availability: WikiAppModel.RepairSelection.SourceAvailability
  let bodyOnly: Bool
  @Binding var showObservedSource: Bool

  private var maximumPreviewHeight: CGFloat {
    #if os(iOS)
    100
    #else
    140
    #endif
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let observed = observedSourceText {
        if !bodyOnly {
          Text("현재 원문과 비교해 편집하세요. 저장하면 아래 초안으로 원문을 변경합니다.").font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        DisclosureGroup(bodyOnly ? "받은 내용" : "현재 원문", isExpanded: $showObservedSource) {
          ScrollView {
            Text(bodyOnly ? FolioEditorContent(source: observed).body : observed)
              .font(bodyOnly ? .body : .system(.callout, design: .monospaced)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: maximumPreviewHeight).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
      } else if availability == .unavailableCloud {
        Text("문서를 아직 받지 못했습니다. 편집 내용은 이 기기에 보관됩니다. 문서를 받은 뒤 저장할 수 있습니다.")
          .font(.callout).foregroundStyle(.secondary)
          .accessibilityIdentifier("draft-recovery-cloud-unavailable")
      } else {
        Text("문서가 없습니다. 저장하면 편집한 내용으로 다시 만듭니다.").font(.callout).foregroundStyle(.secondary)
      }
      if !bodyOnly { Text("보존한 초안").font(.callout.weight(.medium)) }
    }.padding(.horizontal, 24).padding(.top, 12)
  }
}
