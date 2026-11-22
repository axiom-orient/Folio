import FolioKnowledgeApple
import SwiftUI

struct WikiFileBrowserView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme
  let model: WikiAppModel
  let window: WikiWindowState
  let context: FolioDocumentContext
  @State private var folder = "notes"
  @State private var showingTrash = false
  @State private var action: WikiFileAction?
  @State private var catalogRequest = UUID()
  private struct CatalogTask: Hashable { let trash: Bool; let request: UUID }

  private var workspaceName: String {
    model.documentContext == context ? model.snapshot?.workspace.name ?? "자료함" : "자료함"
  }
  private var catalogObserved: Bool {
    model.documentLibrary.context == context && model.documentLibrary.loadProblem == nil && !model.documentLibrary.phase.isBusy
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        WikiFileBrowserBreadcrumb(workspace: workspaceName, folder: folder, showingTrash: showingTrash) { folder = $0 }
          .padding(.horizontal, 20).padding(.vertical, 12)
        #if os(macOS)
        HStack(spacing: 16) {
          if !showingTrash {
            Button("새 폴더", action: createFolder).fixedSize().accessibilityIdentifier("create-folder")
          }
          Button(showingTrash ? "문서 폴더" : "휴지통") { showingTrash.toggle() }
            .fixedSize().accessibilityIdentifier("toggle-trash")
          Button("새로고침", action: reload).fixedSize()
          Spacer(minLength: 0)
        }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.bottom, 12)
        #endif
        #if os(macOS)
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: 0) { catalogContents }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }.accessibilityIdentifier("document-management-scroll")
        #else
        List { catalogContents }.listStyle(.plain).scrollContentBackground(.hidden)
        #endif
      }.background(FolioTheme.paper(scheme))
      .navigationTitle(showingTrash ? "휴지통" : "문서 정리")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
        #if os(iOS)
        ToolbarItem(placement: .primaryAction) {
          Menu("폴더 작업", systemImage: "ellipsis") {
            if !showingTrash {
              Button("새 폴더", systemImage: "folder.badge.plus", action: createFolder).accessibilityIdentifier("create-folder")
            }
            Button(showingTrash ? "문서 폴더" : "휴지통", systemImage: showingTrash ? "folder" : "trash") {
              showingTrash.toggle()
            }.accessibilityIdentifier("toggle-trash")
            Button("새로고침", systemImage: "arrow.clockwise", action: reload)
          }.accessibilityIdentifier("file-browser-options")
        }
        #endif
      }
      .disabled(model.documentLibrary.phase.isBusy)
      .overlay { if model.documentLibrary.phase.isBusy { ProgressView("자료 확인 중…") } }
      .task(id: CatalogTask(trash: showingTrash, request: catalogRequest)) {
        await model.reloadDocumentLibrary(context: context)
        if showingTrash { await model.loadVisibleTrash(context: context) }
      }
      .onChange(of: model.documentLibrary.folders) { _, folders in if !folders.contains(folder) { folder = "notes" } }
      .sheet(item: $action, onDismiss: reload) { WikiFileActionView(model: model, action: $0) }
    }.folioSheetSize(width: 640, height: 580)
  }

  @ViewBuilder private var catalogContents: some View {
    WikiDocumentLibraryNotice(model: model)
    if showingTrash {
      if model.documentLibrary.trash.isEmpty && catalogObserved {
        Text("휴지통이 비어 있습니다.").foregroundStyle(FolioTheme.muted(scheme))
      }
      ForEach(model.documentLibrary.trash) { entry in
        WikiFileBrowserTrashRow(entry: entry, context: context, action: $action) {
          Task { await model.requestTrashDownload(id: entry.id, context: context); reload() }
        }
        #if os(macOS)
        Divider().accessibilityHidden(true)
        #endif
      }
    } else {
      let entries = model.documentLibrary.children(in: folder)
      if entries.isEmpty && catalogObserved { Text("빈 폴더입니다.").foregroundStyle(FolioTheme.muted(scheme)) }
      let folders = entries.filter(\.isDirectory)
      if !folders.isEmpty {
        WikiFileBrowserFolders(entries: folders, context: context, action: $action, open: open)
          #if os(iOS)
          .listRowSeparator(.hidden).listRowBackground(Color.clear)
          #endif
      }
      ForEach(entries.filter { !$0.isDirectory }) { entry in
        let document = model.snapshot?.documents.first(where: { $0.relativePath == entry.relativePath })
        WikiFileBrowserDocumentRow(entry: entry,
          title: document?.title ?? (entry.relativePath as NSString).lastPathComponent,
          documentType: document?.type, context: context, action: $action) { open(entry) }
        #if os(macOS)
        Divider().accessibilityHidden(true)
        #endif
      }
    }
    if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
  }

  private func createFolder() { action = WikiFileAction(kind: .createFolder(parent: folder), context: context) }
  private func reload() { catalogRequest = UUID() }
  private func open(_ entry: WikiLibraryEntry) {
    guard model.documentContext == context else {
      model.message = "자료함이 바뀌었습니다. 현재 자료함에서 문서 정리를 다시 열어 주세요."; return
    }
    if entry.isDirectory { folder = entry.relativePath }
    else if let document = model.snapshot?.documents.first(where: { $0.relativePath == entry.relativePath }) {
      window.selectedDocumentID = document.id; dismiss()
    } else { Task { await model.showSourceRepair(path: entry.relativePath) } }
  }
}

