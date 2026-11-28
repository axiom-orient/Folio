import FolioKnowledge
import QuickLook
import SwiftUI

/// Both platforms restart window work from the same selection, search and source identities.
struct WikiWindowTasks: ViewModifier {
  let model: WikiAppModel
  let window: WikiWindowState

  func body(content: Content) -> some View {
    content
      .task(id: window.selectedDocumentID) { await model.loadSelection(window) }
      .task(id: window.searchCriteria) {
        do { try await Task.sleep(for: .milliseconds(180)); await model.search(window) }
        catch is CancellationError {}
        catch { model.message = error.localizedDescription }
      }
      .task(id: model.documentContext) {
        if let context = model.documentContext { await model.reloadDocumentLibrary(context: context) }
      }
  }
}

/// Context-menu commands capture the document revision and source context from the row.
struct WikiDocumentContextActions: View {
  let document: WikiDocument
  let context: FolioDocumentContext
  @Bindable var window: WikiWindowState

  var body: some View {
    Button("제목·태그 편집…", systemImage: "tag") {
      window.metadataSelection = .init(document: document, context: context)
    }
    WikiFileActionButtons(path: document.relativePath, revision: document.revision, context: context, action: $window.fileAction)
  }
}

/// Each window owns its presentation; both platforms use the same actions.
struct WikiWindowPresentation: ViewModifier {
  @Bindable var model: WikiAppModel
  @Bindable var window: WikiWindowState
  @Binding var showLibrary: Bool
  @Binding var showNewDocument: Bool
  @Binding var showInbox: Bool
  @Binding var documentImportTarget: FolioReceivedTarget?
  @State private var incomingSource: WikiIncomingSource?
  @State private var receivedTransferID: UUID?

  func body(content: Content) -> some View {
    content
      .onOpenURL { url in
        if let transferID = FolioTransferStorage.receivedTransfer(from: url) {
          receivedTransferID = transferID; showInbox = true
        } else if url.isFileURL { incomingSource = WikiIncomingSource(url: url) }
        else { Task { await model.openLink(url, in: window) } }
      }
      .sheet(item: $incomingSource) { source in
        WikiSourceImportView(model: model, window: window, url: source.url) {
          if incomingSource?.id == source.id { incomingSource = nil }
        }
      }
      .background {
        if let target = documentImportTarget {
          WikiFilePicker(contentTypes: WikiFilePicker.documentContentTypes,
            cancellation: { documentImportTarget = nil }) { result in
            documentImportTarget = nil
            switch result {
            case .success(let urls):
              guard let url = urls.first else { return }
              Task { await model.importSource(url, in: window, expectedTarget: target) }
            case .failure(let error): model.message = error.localizedDescription
            }
          }
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
        Task { await model.cloudIdentityChanged() }
      }
      .sheet(isPresented: $showInbox, onDismiss: { receivedTransferID = nil }) {
        WikiNearbyView(model: model, window: window, focusTransferID: receivedTransferID)
      }
      .modifier(WikiLibraryPresentation(model: model, window: window, isPresented: $showLibrary))
      .sheet(isPresented: $showNewDocument) { WikiNewDocumentView(model: model, window: window) }
      .sheet(item: $window.fileBrowserContext) { WikiFileBrowserView(model: model, window: window, context: $0) }
      .sheet(item: $window.fileAction) { WikiFileActionView(model: model, action: $0) }
      .sheet(item: $window.metadataSelection) { WikiMetadataEditView(model: model, selection: $0) }
      .sheet(item: $window.knowledgeRequest) { request in
        if request.context == model.documentContext, request.workspaceGeneration == model.workspaceGeneration {
          FolioKnowledgeQueryView(model: model, window: window, documentID: request.documentID,
            initialQuestion: request.initialQuestion).id(request.id)
        }
      }
      .onChange(of: model.workspaceGeneration) { _, _ in window.knowledgeRequest = nil }
      .onChange(of: model.hasOpenWorkspace) { _, isOpen in if !isOpen { window.knowledgeRequest = nil } }
      .sheet(item: $model.conflictSelection) { WikiConflictView(model: model, selection: $0) }
      .sheet(item: $model.repairSelection) { WikiSourceRepairView(model: model, selection: $0) }
      .sheet(item: $model.mergeSelection) { WikiDocumentMergeView(model: model, selection: $0) }
      .quickLookPreview($model.previewURL)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          WikiNearbyNotice(model: model) { id in receivedTransferID = id; showInbox = true }
          if let message = model.message {
            HStack(alignment: .top, spacing: 12) {
              Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
              Button("알림 닫기", systemImage: "xmark") { model.message = nil }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }.padding(16).background(.regularMaterial)
          }
        }
      }
  }
}
