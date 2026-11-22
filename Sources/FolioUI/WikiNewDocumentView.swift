import SwiftUI

struct WikiNewDocumentView: View {
  let model: WikiAppModel
  let window: WikiWindowState
  @State private var destination: Destination?
  @State private var title = ""
  @State private var isCreating = false
  @State private var error: String?
  @State private var createdDocument: WikiAppModel.CreatedDocument?
  @State private var folder = "notes"
  @FocusState private var titleFocused: Bool
  @Environment(\.dismiss) private var dismiss

  private struct Destination {
    let context: FolioDocumentContext
    let recoveryScope: URL
    let name: String
    let storage: String
  }

  init(model: WikiAppModel, window: WikiWindowState) {
    self.model = model
    self.window = window
    let admitted: Destination?
    if let context = model.documentContext, let scope = model.draftStore.recoveryScopeURL,
      let name = model.snapshot?.workspace.name, let target = model.receivedFileTarget {
      admitted = .init(context: context, recoveryScope: scope, name: name, storage: target.storageTitle)
    } else { admitted = nil }
    _destination = State(initialValue: admitted)
  }

  private var destinationIsCurrent: Bool {
    guard let destination else { return false }
    return destination.context == model.documentContext && destination.recoveryScope == model.draftStore.recoveryScopeURL
  }

  private var folders: [String] {
    model.documentLibrary.context == destination?.context ? model.documentLibrary.folders : ["notes"]
  }

  private var canSubmit: Bool {
    guard !isCreating, !model.isBusy, destinationIsCurrent else { return false }
    return createdDocument != nil || (FolioInput.name(title) != nil && folders.contains(folder))
  }

  private var actionTitle: String {
    if isCreating { return createdDocument == nil ? "만드는 중…" : "확인 중…" }
    guard let createdDocument else { return "만들기" }
    return createdDocument.wasObserved ? "문서 열기" : "결과 확인"
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if createdDocument == nil {
            TextField("제목", text: $title).focused($titleFocused).onSubmit(create)
            if folders.count > 1 || folder != "notes" {
              Picker("폴더", selection: $folder) {
                if !folders.contains(folder) { Text("폴더를 다시 선택하세요").tag(folder).disabled(true) }
                ForEach(folders, id: \.self) { path in Text(WikiFileAction.folderLabel(path)).tag(path) }
              }
            }
          } else {
            FolioFileHeader(name: title, detail: folder == "notes" ? nil : WikiFileAction.folderLabel(folder))
          }
        }
        if let destination {
          Section {
            LabeledContent("자료함") {
              VStack(alignment: .trailing, spacing: 4) {
                Text(destination.name)
                Text(destination.storage).font(.callout).foregroundStyle(.secondary)
              }.fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        if !isCreating && !destinationIsCurrent {
          Section {
            FolioMessage(message: createdDocument == nil
              ? "문서를 만들 자료함을 열고 다시 시도해 주세요."
              : "원래 자료함에서 생성 결과를 확인해 주세요.")
          }
        } else if let error { Section { FolioMessage(message: error) } }
      }.formStyle(.grouped)
      .navigationTitle("새 문서")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(isCreating) }
        ToolbarItem(placement: .confirmationAction) {
          Button(actionTitle, action: create).disabled(!canSubmit).keyboardShortcut(.defaultAction)
        }
      }
      .onAppear { titleFocused = createdDocument == nil && destinationIsCurrent }.disabled(isCreating)
      .interactiveDismissDisabled(isCreating)
      .task { if let destination, destinationIsCurrent { await model.reloadDocumentLibrary(context: destination.context) } }
    }
    #if os(macOS)
    .folioSheetSize(width: 440, height: 320)
    #else
    .presentationDetents([.medium, .large])
    #endif
  }

  private func create() {
    guard canSubmit else { return }
    let name = title
    let selectedFolder = folder
    isCreating = true; error = nil
    Task {
      defer { isCreating = false }
      guard destinationIsCurrent, !model.isBusy else {
        error = "자료함이 준비되면 다시 시도해 주세요."
        return
      }
      if let createdDocument {
        if await model.openCreatedDocument(createdDocument, in: window) { dismiss(); return }
      } else {
        createdDocument = await model.createDocument(in: window, title: name, folder: selectedFolder)
        if let createdDocument, window.selectedDocumentID == createdDocument.id, window.isEditing { dismiss(); return }
      }
      error = model.message ?? (createdDocument == nil
        ? "문서를 만들지 못했습니다. 제목과 자료함을 확인해 주세요."
        : createdDocument?.wasObserved == true ? "문서는 만들었지만 열지 못했습니다. 같은 문서 열기를 다시 시도하세요."
        : "문서 생성 결과를 확인하지 못했습니다. 같은 요청의 결과를 다시 확인해 주세요.")
    }
  }
}
