import SwiftUI

struct WikiFileActionView: View {
  let model: WikiAppModel
  let action: WikiFileAction
  @State private var name = ""
  @State private var destination = "notes"
  @State private var failure: String?
  @State private var submitting = false
  @Environment(\.dismiss) private var dismiss
  private var destinationFolders: [String] {
    model.documentLibrary.moveDestinations(for: action.path)
  }

  var body: some View {
    NavigationStack {
      Form {
        LabeledContent(action.needsName ? "위치" : "대상") {
          Text(WikiFileAction.folderLabel(action.path)).textSelection(.enabled)
        }
        if action.needsName {
          TextField("이름", text: $name).onSubmit(submit)
            .accessibilityIdentifier("file-action-name")
        }
        if action.needsDestination {
          Picker("대상 폴더", selection: $destination) {
            ForEach(destinationFolders, id: \.self) { path in
              Text(WikiFileAction.folderLabel(path)).tag(path)
            }
          }.accessibilityIdentifier("file-action-destination")
          if destinationFolders.isEmpty { Text("이동할 다른 폴더를 먼저 만들어 주세요.").font(.callout) }
        }
        switch action.kind {
        case .trash: Text("휴지통에서 다시 복원할 수 있습니다.").font(.callout)
        case .purge: Text("휴지통의 원문을 영구 삭제합니다. 이 작업은 되돌릴 수 없습니다.").font(.callout)
        case .restore: Text("원래 폴더로 복원합니다.").font(.callout)
        default: EmptyView()
        }
        if let failure { FolioMessage(message: failure) }
      }.formStyle(.grouped)
      .navigationTitle(action.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(submitting) }
        ToolbarItem(placement: .confirmationAction) {
          Button(action.title, role: action.isDestructive ? .destructive : nil, action: submit)
            .disabled(submitting || model.documentLibrary.phase.isBusy || (action.needsName && FolioInput.name(name) == nil)
              || (action.needsDestination && !destinationFolders.contains(destination)))
            .keyboardShortcut(.defaultAction).accessibilityIdentifier("file-action-submit")
        }
      }
      .onAppear {
        if case .rename = action.kind { name = (action.path as NSString).lastPathComponent }
        if action.needsDestination { destination = destinationFolders.first ?? "notes" }
      }
      .task { await model.reloadDocumentLibrary(context: action.context) }
      .interactiveDismissDisabled(submitting)
    }.folioSheetSize(width: 520, height: 330)
  }

  private func submit() {
    guard !submitting else { return }
    submitting = true; failure = nil
    Task {
      defer { submitting = false }
      if await model.performFileAction(action, name: name, destination: destination) { dismiss() }
      else { failure = model.message ?? "작업을 완료하지 못했습니다. 대상과 현재 원문을 확인해 주세요." }
    }
  }
}
