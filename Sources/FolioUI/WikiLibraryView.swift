import FolioKnowledgeApple
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

private extension WikiManagedWorkspace {
  var folioChoiceID: FolioLibraryIdentity { FolioLibraryIdentity(location: location, workspaceID: id) }
}

/// Each presenter retains its own selection until the native sheet has closed.
struct WikiLibraryPresentation: ViewModifier {
  let model: WikiAppModel
  let window: WikiWindowState
  @Binding var isPresented: Bool
  @State private var pendingAction: (@MainActor () async -> Void)?

  func body(content: Content) -> some View {
    content.sheet(isPresented: $isPresented, onDismiss: performSelection) {
      WikiLibraryView(model: model, window: window) { action in
        pendingAction = action
        isPresented = false
      }
    }
  }

  private func performSelection() {
    guard let action = pendingAction else { return }
    pendingAction = nil
    Task { await action() }
  }
}

/// Selection and presentation belong to this sheet; source effects remain in the app.
struct WikiLibraryView: View {
  @Environment(\.dismiss) private var dismiss
  let model: WikiAppModel
  let window: WikiWindowState
  let perform: (@escaping @MainActor () async -> Void) -> Void
  @State private var local: [WikiManagedWorkspace] = []
  @State private var name = "내 문서"
  @State private var useCloud = false
  @State private var createdLocation: WikiWorkspaceLocation?
  @State private var path: [Page] = []
  @State private var importer: ImportPurpose?
  @State private var importTarget: FolioReceivedTarget?
  @State private var sendSource: FolioSendSource?
  #if os(iOS)
  @State private var photo: PhotosPickerItem?
  @State private var photoTarget: FolioReceivedTarget?
  @State private var showPhotoPicker = false
  @State private var presentationDetent = PresentationDetent.large
  #endif
  private enum Page: Hashable { case create, manage }
  private enum ImportPurpose: Hashable {
    case workspace, attachment, sendFile
    #if os(macOS)
    case open, createFolder
    #endif
  }

  var body: some View {
    NavigationStack(path: $path) {
      WikiLibraryCollection(current: currentChoice,
        local: local.filter(isActiveChoice).map(choiceContent),
        cloud: model.cloudLibrary.workspaces.filter(isActiveChoice).map(choiceContent),
        archived: (local + model.cloudLibrary.workspaces).filter {
          !model.isSelectedWorkspace($0.location) && model.archivedLibraryIDs.contains($0.folioChoiceID)
        }.map(choiceContent),
        supportsCloud: model.supportsManagedCloud, gatheringCloud: model.cloudLibrary.isGathering,
        cloudProblem: model.cloudLibrary.problem, open: openLibrary,
        manage: { path.append(.manage) }, create: { path.append(.create) },
        importWorkspace: { chooseImport(.workspace) }, openFolder: openFolderAction,
        refreshCloud: { Task { await model.refreshCloudLibrary() } },
        archive: { model.setLibraryArchived($0, archived: true) },
        restore: { model.setLibraryArchived($0, archived: false) })
      .navigationTitle("자료함")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
      }
      .navigationDestination(for: Page.self) { page in
        switch page {
        case .create:
          WikiNewLibraryView(model: model, name: $name, useCloud: $useCloud, createdLocation: $createdLocation) { dismiss() }
        case .manage:
          WikiWorkspaceView(model: model, isAddingPhoto: isAddingPhoto, action: handleWorkspaceAction)
          #if os(iOS)
          .photosPicker(isPresented: $showPhotoPicker, selection: $photo, matching: .images)
          #endif
        }
      }
    }
    .task { local = model.localWorkspaces(); await model.refreshCloudLibrary() }
    .sheet(item: $sendSource) { WikiNearbyView(model: model, window: window, source: $0) }
    .background {
      if let purpose = importer {
        WikiFilePicker(contentTypes: contentTypes(for: purpose), cancellation: { importer = nil; importTarget = nil }) { [expectedTarget = importTarget] result in
          importer = nil
          importTarget = nil
          switch result {
          case .success(let urls):
            guard let url = urls.first else { return }
            if purpose == .sendFile { sendSource = .file(url); return }
            perform {
              switch purpose {
              case .attachment:
                guard let expectedTarget, model.receivedFileTarget == expectedTarget else {
                  model.message = "자료함이 바뀌었습니다. 추가할 자료함에서 파일을 다시 선택하세요."; return
                }
                await model.captureAttachment(url, in: window, expectedTarget: expectedTarget)
              case .workspace: await model.importWorkspaceSource(url, in: window)
              case .sendFile: break
              #if os(macOS)
              case .open, .createFolder: await model.openExternal(url, create: purpose == .createFolder)
              #endif
              }
            }
          case .failure(let error): model.message = error.localizedDescription
          }
        }.id(purpose)
      }
    }
    #if os(iOS)
    .task(id: photo) {
      guard let photo else { return }
      let expectedTarget = photoTarget
      defer { self.photo = nil; photoTarget = nil }
      guard let expectedTarget, model.receivedFileTarget == expectedTarget else {
        model.message = "자료함이 바뀌었습니다. 추가할 자료함에서 사진을 다시 선택하세요."; return
      }
      do {
        guard let selection = try await photo.loadTransferable(type: WikiPickedPhoto.self) else {
          model.message = "사진을 읽지 못했습니다. 다른 사진이나 파일을 선택해 주세요."; return
        }
        guard !Task.isCancelled else {
          try? FileManager.default.removeItem(at: selection.url.deletingLastPathComponent()); return
        }
        perform {
          guard model.receivedFileTarget == expectedTarget else {
            try? FileManager.default.removeItem(at: selection.url.deletingLastPathComponent())
            model.message = "자료함이 바뀌었습니다. 추가할 자료함에서 사진을 다시 선택하세요."; return
          }
          defer { try? FileManager.default.removeItem(at: selection.url.deletingLastPathComponent()) }
          await model.captureAttachment(selection.url, in: window, expectedTarget: expectedTarget)
        }
      } catch is CancellationError {} catch { model.message = error.localizedDescription }
    }
    #endif
    .folioSheetSize(width: 460, height: 560)
    #if os(iOS)
    .presentationDetents([.medium, .large], selection: $presentationDetent)
    .presentationDragIndicator(.visible)
    #endif
  }

  private func handleWorkspaceAction(_ action: WikiWorkspaceView.Action) {
    switch action {
    #if os(iOS)
    case .photo:
      guard photo == nil else { return }
      guard let target = model.receivedFileTarget else {
        model.message = "자료함이 준비되면 사진을 다시 선택하세요."
        return
      }
      photoTarget = target
      photo = nil
      showPhotoPicker = true
    #endif
    case .attachment: chooseImport(.attachment)
    case .sendFile: chooseImport(.sendFile)
    case .sendArchive: if let archive = model.archiveShare { sendSource = .archive(archive) }
    case .ontology: perform { await model.showOntology() }
    case .refresh: perform { await model.refresh() }
    case .rebuildSearch: perform { await model.recoverSearch() }
    case .publish: perform { await model.publishToCloud() }
    #if os(macOS)
    case .reveal: perform { await model.revealWorkspace() }
    case .createFolder: chooseImport(.createFolder)
    case .connect: perform { await model.connectSEMI() }
    #endif
    }
  }

  private var isAddingPhoto: Bool {
    #if os(iOS)
    photo != nil
    #else
    false
    #endif
  }

  private func chooseImport(_ purpose: ImportPurpose) {
    if purpose == .attachment {
      guard let target = model.receivedFileTarget else {
        model.message = "자료함이 준비되면 파일을 다시 선택하세요."
        return
      }
      importTarget = target
    } else { importTarget = nil }
    importer = purpose
  }

  private func contentTypes(for purpose: ImportPurpose) -> [UTType] {
    switch purpose {
    case .attachment, .sendFile: [.item]
    case .workspace: [.folder, .zip]
    #if os(macOS)
    case .open, .createFolder: [.folder]
    #endif
    }
  }

  private var openFolderAction: (() -> Void)? {
    #if os(macOS)
    { chooseImport(.open) }
    #else
    nil
    #endif
  }

  private func isActiveChoice(_ choice: WikiManagedWorkspace) -> Bool {
    !model.isSelectedWorkspace(choice.location) && !model.archivedLibraryIDs.contains(choice.folioChoiceID)
  }

  private var currentChoice: FolioLibraryChoice? {
    guard let snapshot = model.snapshot, let location = model.currentWorkspaceLocation else { return nil }
    return FolioLibraryChoice(id: .init(location: location, workspaceID: snapshot.workspace.id),
      name: snapshot.workspace.name, notice: cloudNotice(snapshot.workspace.id, location: location))
  }

  private func choiceContent(_ choice: WikiManagedWorkspace) -> FolioLibraryChoice {
    FolioLibraryChoice(id: choice.folioChoiceID, name: choice.name,
      notice: cloudNotice(choice.id, location: choice.location))
  }

  private func cloudNotice(_ id: UUID, location: WikiWorkspaceLocation) -> FolioLibraryChoice.Notice? {
    guard case .managedCloud = location, let status = model.cloudLibrary.statusByWorkspace[id] else { return nil }
    return .init(cloudStatus: status)
  }

  private func openLibrary(_ id: FolioLibraryIdentity) {
    if currentChoice?.id == id { dismiss(); return }
    guard let choice = (local + model.cloudLibrary.workspaces).first(where: { $0.folioChoiceID == id }) else { return }
    perform { await model.open(choice.location) }
  }
}

struct WikiCloudStatusText: View {
  let status: WikiCloudStatus?
  private var label: String {
    guard let status else { return "iCloud 상태 확인 중…" }
    if let notice = FolioLibraryChoice.Notice(cloudStatus: status) { return notice.text }
    if status.pendingDownloads > 0 { return "문서를 받는 중…" }
    if status.uploaded { return "이 기기의 문서를 iCloud에 보냈습니다" }
    return status.gatheringComplete ? "문서를 iCloud에 보내는 중…" : "iCloud 상태 확인 중…"
  }
  var body: some View { Text(label) }
}
