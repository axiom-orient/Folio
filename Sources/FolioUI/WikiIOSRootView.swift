#if os(iOS)
import FolioKnowledge
import SwiftUI
import UIKit

public struct WikiRootView: View {
  @State private var model: WikiAppModel
  @State private var window = WikiWindowState()
  @State private var path: [String] = []
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  @State private var initialized = false
  @State private var showLibrary = false
  @State private var showBrowse = false
  @State private var isCreatingNote = false
  @State private var showInbox = false
  @State private var documentImportTarget: FolioReceivedTarget?
  @State private var sceneSessionID: String?
  @FocusState private var searchFocused: Bool
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  public init(model: WikiAppModel = WikiAppModel()) { _model = State(initialValue: model) }

  public var body: some View {
    Group {
      if horizontalSizeClass == .compact {
        NavigationStack(path: $path) {
          home.navigationDestination(for: String.self) { id in
            WikiDocumentView(model: model, window: window, documentID: id)
          }
        }
      } else { regularNavigation }
    }
    .task {
      await model.attach(window)
      window.selectedDocumentID = nil; initialized = true
    }
    .background(WikiSceneIdentity { sceneSessionID = $0 }.frame(width: 0, height: 0))
    .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { note in
      guard let scene = note.object as? UIScene, scene.session.persistentIdentifier == sceneSessionID else { return }
      Task { await model.detach(window) }
    }
    .onChange(of: window.selectedDocumentID) { _, id in
      guard initialized, !model.documentLibrary.phase.isApplying else { return }
      guard let id else { path = []; compactColumn = .sidebar; return }
      path = window.navigationPath(selecting: id, in: path); compactColumn = .detail
    }
    .onChange(of: path) { _, value in
      if !value.isEmpty { searchFocused = false }
      if window.selectedDocumentID != value.last { window.selectedDocumentID = value.last }
      if value.isEmpty { compactColumn = .sidebar }
    }
    .onChange(of: window.documentCatalogRevision) { _, _ in
      path = window.navigationPath(selecting: window.selectedDocumentID, in: path)
      if path.isEmpty { compactColumn = .sidebar }
    }
    .onChange(of: model.snapshot?.workspace.id) { old, new in
      if old != new, !model.isSuspended { path = []; window.selectedDocumentID = nil; compactColumn = .sidebar }
    }
    .modifier(WikiWindowTasks(model: model, window: window))
    .modifier(WikiWindowPresentation(model: model, window: window, showLibrary: $showLibrary,
      showNewDocument: $isCreatingNote, showInbox: $showInbox, documentImportTarget: $documentImportTarget))
    .sheet(isPresented: $showBrowse) { WikiDocumentBrowseView(model: model, window: window) }
    .overlay {
      if model.isPreparingStorage { ProgressView("자료 준비 중…").frame(maxWidth: .infinity, maxHeight: .infinity).background(.background) }
      else if !model.protectedDataAvailable {
        ContentUnavailableView("iPhone을 한 번 잠금 해제하세요", systemImage: "lock",
          description: Text("재부팅 후 처음 사용할 때 또는 기존 자료를 준비할 때 한 번 필요합니다."))
          .background(.background)
      }
      else if model.isBusy { ProgressView("자료 여는 중…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
    }
    .disabled(model.isBusy || !model.protectedDataAvailable)
  }

  private var regularNavigation: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      home
    } detail: {
      NavigationStack(path: linkedDocuments) {
        Group {
          if let id = path.first { WikiDocumentView(model: model, window: window, documentID: id) }
          else { ContentUnavailableView("문서를 선택하세요", systemImage: "doc.text") }
        }.navigationDestination(for: String.self) { id in
          WikiDocumentView(model: model, window: window, documentID: id)
        }
      }
    }
  }

  private var home: some View {
    WikiIOSHomeView(model: model, window: window, showLibrary: $showLibrary, showBrowse: $showBrowse,
      isCreatingNote: $isCreatingNote, showInbox: $showInbox, documentImportTarget: $documentImportTarget, searchFocused: $searchFocused,
      selectFromList: selectFromList)
  }

  /// The first document is the split view's detail root; only document links push another screen.
  private var linkedDocuments: Binding<[String]> {
    Binding(get: { Array(path.dropFirst()) }, set: { links in
      path = path.first.map { [$0] + links } ?? []
    })
  }

  private func selectFromList(_ id: String) {
    path = [id]
    window.isEditing = false
    window.selectedDocumentID = id
    compactColumn = .detail
  }
}
#endif
