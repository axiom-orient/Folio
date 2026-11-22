import Foundation
import SwiftUI

struct WikiDocumentMergeView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme
  let model: WikiAppModel
  let selection: WikiAppModel.MergeSelection
  @State private var choices: [Int: FolioDocumentMerge.Choice] = [:]

  private var isSaving: Bool { model.savingDocuments.contains(selection.documentID) }
  private var isCurrent: Bool {
    model.hasOpenWorkspace && model.openedSourceRoot == selection.sourceRoot
      && model.snapshot?.workspace.id == selection.workspaceID
  }
  private var canSave: Bool {
    isCurrent && !isSaving && selection.plan.conflicts.allSatisfy { choices[$0.id] != nil }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 12) {
            Text(selection.title).font(.title2.weight(.semibold))
              .foregroundStyle(FolioTheme.text(scheme))
              .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)
            Text("같은 부분이 다르게 수정됐어요. 남길 내용을 선택하세요.")
              .font(.callout).foregroundStyle(FolioTheme.muted(scheme))
              .fixedSize(horizontal: false, vertical: true)
          }
          ForEach(selection.plan.conflicts, id: \.id) { conflict in
            VStack(spacing: 8) {
              WikiMergeChoice(title: "내 편집", text: conflict.edited,
                isSelected: choices[conflict.id] == .edited) { choices[conflict.id] = .edited }
                .accessibilityIdentifier("document-merge-edited-\(conflict.id)")
              WikiMergeChoice(title: "받은 변경", text: conflict.received,
                isSelected: choices[conflict.id] == .received) { choices[conflict.id] = .received }
                .accessibilityIdentifier("document-merge-received-\(conflict.id)")
            }
            if conflict.id != selection.plan.conflicts.last?.id { Divider() }
          }
          if !isCurrent {
            FolioMessage(message: "자료함이 바뀌었습니다. 원래 자료함에서 다시 열어 주세요.")
          }
          if let message = model.message { FolioMessage(message: message) }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(24).frame(maxWidth: .infinity, alignment: .top)
      }
      .background(FolioTheme.paper(scheme))
      .navigationTitle("변경 내용 확인")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("나중에") { dismiss() }.disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isSaving ? "저장 중…" : "저장", action: save)
            .disabled(!canSave).keyboardShortcut("s", modifiers: .command)
            .accessibilityIdentifier("document-merge-save")
        }
      }
      .disabled(isSaving)
      .interactiveDismissDisabled(isSaving)
    }
    .tint(FolioTheme.accent(scheme))
    .folioSheetSize(width: 680, height: 600)
  }

  private func save() {
    guard canSave else { return }
    let submittedChoices = choices
    Task { await model.saveMergedSelection(selection, choices: submittedChoices) }
  }
}

private struct WikiMergeChoice: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  let text: String
  let isSelected: Bool
  let choose: () -> Void
  private var displayedText: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "이 부분 삭제" : text
  }

  var body: some View {
    Button(action: choose) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text(title).font(.callout.weight(.semibold))
          Spacer(minLength: 12)
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? FolioTheme.accent(scheme) : FolioTheme.muted(scheme))
            .accessibilityHidden(true)
        }
        Text(verbatim: displayedText).font(.body)
          .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(FolioTheme.text(scheme))
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .padding(16).contentShape(Rectangle())
      .background(isSelected ? FolioTheme.accent(scheme).opacity(0.08) : .clear,
        in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(isSelected ? FolioTheme.accent(scheme) : FolioTheme.muted(scheme).opacity(0.3))
      }
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title).accessibilityValue(displayedText)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { choose() }
  }
}
