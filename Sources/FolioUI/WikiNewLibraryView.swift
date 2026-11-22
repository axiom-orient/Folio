import SwiftUI
import FolioKnowledgeApple

struct WikiNewLibraryView: View {
  let model: WikiAppModel
  @Binding var name: String
  @Binding var useCloud: Bool
  @Binding var createdLocation: WikiWorkspaceLocation?
  let created: () -> Void
  @State private var isCreating = false
  @State private var error: String?
  @FocusState private var nameFocused: Bool

  private var canSubmit: Bool {
    !isCreating && !model.isBusy && (createdLocation != nil || FolioInput.name(name) != nil)
  }

  private var actionTitle: String {
    if isCreating { return createdLocation == nil ? "만드는 중…" : "여는 중…" }
    return createdLocation == nil ? "만들기" : "자료함 열기"
  }

  var body: some View {
    Form {
      Section {
        if let createdLocation {
          let storage = if case .managedCloud = createdLocation { "iCloud" } else { "이 기기" }
          FolioFileHeader(name: name, detail: storage, icon: "folder")
        } else {
          TextField("이름", text: $name).focused($nameFocused).onSubmit(create)
          if model.supportsManagedCloud {
            Picker("저장 위치", selection: $useCloud) {
              Text("이 기기").tag(false)
              Text("iCloud").tag(true)
            }.pickerStyle(.segmented)
          }
        }
      }
      if let error { Section { FolioMessage(message: error) } }
    }
    .formStyle(.grouped)
    .navigationTitle("새 자료함")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(actionTitle, action: create)
          .disabled(!canSubmit)
          .keyboardShortcut(.defaultAction)
      }
    }
    .onAppear { nameFocused = createdLocation == nil }
    .disabled(isCreating)
  }

  private func create() {
    guard canSubmit else { return }
    isCreating = true; error = nil
    let title = name; let cloud = useCloud
    Task {
      if let createdLocation { await model.open(createdLocation) }
      else { createdLocation = await model.createLibrary(name: title, useCloud: cloud) }
      isCreating = false
      if let createdLocation, model.isSelectedWorkspace(createdLocation) { created() }
      else {
        error = model.message ?? (createdLocation == nil
          ? "자료함을 만들지 못했습니다. 이름과 저장 위치를 확인해 주세요."
          : "자료함은 만들었지만 열지 못했습니다. 같은 자료함 열기를 다시 시도하세요.")
      }
    }
  }
}
