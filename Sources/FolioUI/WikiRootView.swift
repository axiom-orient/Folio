#if os(macOS)
import SwiftUI
import FolioKnowledge

public struct WikiRootView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorScheme) private var scheme
  @State private var model: WikiAppModel
  @State private var window = WikiWindowState()
  @State private var showLibrary = false
  @State private var showNewDocument = false
  @State private var showInbox = false
  @State private var showBrowse = false
  @State private var documentImportTarget: FolioReceivedTarget?
  @FocusState private var searchFocused: Bool
  public init(model: WikiAppModel = WikiAppModel()) { _model = State(initialValue: model) }

  public var body: some View {
    GeometryReader { viewport in
      rootContent(viewport: viewport.size).frame(width: viewport.size.width, height: viewport.size.height)
    }.frame(minWidth: 700, minHeight: 480)
  }

  private func rootContent(viewport: CGSize) -> some View {
    HSplitView {
      if window.showSidebar && model.snapshot != nil {
        sidebar.frame(minWidth: 260, idealWidth: 300, maxWidth: 360).frame(height: viewport.height)
      }
      Group {
        if model.snapshot != nil { WikiDocumentView(model: model, window: window) }
        else { firstLibrary }
      }.frame(minWidth: 0, maxWidth: .infinity).frame(height: viewport.height)
    }
    .background {
      Button("노트 검색") { window.showSidebar = true; window.isSearchVisible = true; searchFocused = true }
        .keyboardShortcut("f", modifiers: .command).disabled(window.isEditing || !model.hasOpenWorkspace).hidden()
      Button("새 문서") { Task { await model.quickCreateDocument(in: window) } }
        .keyboardShortcut("n", modifiers: .command).disabled(!model.hasOpenWorkspace).hidden()
    }
    .navigationTitle("Folio")
    .tint(FolioTheme.accent(scheme))
    .task { await model.attach(window); await model.refreshCloudLibrary() }
    .modifier(WikiWindowTasks(model: model, window: window))
    .onDisappear { Task { await model.detach(window) } }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { model.persistDrafts(); Task { await model.nearby.stop() } }
      if phase == .active { Task { await model.nearby.ready(); await model.refresh(); await model.refreshCloudLibrary() } }
    }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        if model.snapshot == nil {
          Button("받은 파일", systemImage: "tray.and.arrow.down") { showInbox = true }.labelStyle(.titleOnly)
        }
      }
      ToolbarItem(placement: .navigation) {
        if model.snapshot != nil {
          Button("사이드바", systemImage: "sidebar.left") { window.showSidebar.toggle() }
            .labelStyle(.iconOnly).keyboardShortcut("s", modifiers: [.command, .control])
        }
      }
      ToolbarItemGroup {
        if model.snapshot != nil {
          Button("이전 문서", systemImage: "chevron.left") { window.goBack() }
            .disabled(!window.canGoBack).keyboardShortcut("[", modifiers: .command)
          Button("다음 문서", systemImage: "chevron.right") { window.goForward() }
            .disabled(!window.canGoForward).keyboardShortcut("]", modifiers: .command)
        }
      }
    }
    .modifier(WikiWindowPresentation(model: model, window: window, showLibrary: $showLibrary,
      showNewDocument: $showNewDocument, showInbox: $showInbox, documentImportTarget: $documentImportTarget))
    .disabled(model.isBusy)
    .overlay { if model.isBusy { ProgressView("문서 여는 중…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }

  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      if window.isSearchVisible || window.hasSearchQuery {
        HStack(spacing: 8) {
          TextField("노트 검색", text: $window.query).textFieldStyle(.roundedBorder).focused($searchFocused)
            .accessibilityIdentifier("document-search")
          Button("닫기") {
            window.query = ""; window.isSearchVisible = false; searchFocused = false
          }.accessibilityLabel("검색 닫기").buttonStyle(.borderless)
        }.padding(16).disabled(!model.hasOpenWorkspace)
      } else { libraryHeader }
      if window.filter != WikiDocumentFilter() {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(filterOptions.summary).font(.callout).foregroundStyle(FolioTheme.muted(scheme))
            .lineLimit(nil).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(filterOptions.accessibilitySummary).accessibilityIdentifier("document-list-scope")
          Button("해제") { window.filter = .init() }.buttonStyle(.borderless)
            .accessibilityLabel("필터 해제").accessibilityIdentifier("document-filter-reset")
        }.padding(.horizontal, 16).padding(.bottom, 8)
      }
      documentList
    }
    .background(FolioTheme.paper(scheme))
    .popover(isPresented: $showBrowse) { WikiDocumentBrowseView(model: model, window: window) }
  }

  private var libraryHeader: some View {
    HStack(spacing: 10) {
      Button { showLibrary = true } label: {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(model.snapshot?.workspace.name ?? "자료함").font(.body.weight(.semibold))
            .lineLimit(nil).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
          Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.plain).accessibilityLabel("자료함 선택").accessibilityIdentifier("library-picker")
        .accessibilityValue(model.snapshot?.workspace.name ?? "")
      Button("노트 검색", systemImage: "magnifyingglass") {
        window.isSearchVisible = true; searchFocused = true
      }.labelStyle(.iconOnly).accessibilityIdentifier("document-search-toggle")
      WikiLibraryAddMenu(model: model, window: window, importTarget: $documentImportTarget) {
        showNewDocument = true
      }
      Menu("더 보기", systemImage: "ellipsis") {
        Button("폴더·태그", systemImage: "line.3.horizontal.decrease") { showBrowse = true }
          .accessibilityIdentifier("document-filters")
        Button("문서 정리", systemImage: "folder") { window.fileBrowserContext = model.documentContext }
          .accessibilityIdentifier("document-management")
        Button("받은 파일", systemImage: "tray.and.arrow.down") { showInbox = true }
      }.labelStyle(.iconOnly).menuStyle(.borderlessButton).accessibilityIdentifier("document-list-options")
    }.buttonStyle(.borderless).foregroundStyle(FolioTheme.text(scheme))
      .padding(.horizontal, 16).padding(.vertical, 16)
  }

  private var filterOptions: WikiDocumentFilterOptions {
    WikiDocumentFilterOptions(documents: model.snapshot?.documents ?? [], folders: model.documentLibrary.folders,
      filter: window.filter)
  }

  private var documentList: some View {
    List(selection: documentSelection) {
      if let snapshot = model.snapshot {
        if window.isSearchVisible || window.hasSearchQuery {
          WikiSearchTools(model: model, window: window, showFilters: { showBrowse = true })
        }
        if !window.hasSearchQuery {
          let documents = snapshot.documents.filter(window.filter.matches)
          let duplicateTitles = folioDuplicateDocumentTitles(documents)
          if snapshot.documents.isEmpty && snapshot.diagnostics.contains(where: { $0.reason == "download_pending" }) {
            ProgressView("문서를 받는 중…").font(.callout).padding(20).frame(maxWidth: .infinity)
          } else if documents.isEmpty {
            VStack(spacing: 12) {
              Text(snapshot.documents.isEmpty ? "아직 문서가 없습니다" : "필터에 맞는 문서가 없습니다").font(.callout)
              if snapshot.documents.isEmpty { Button("새 문서 만들기") { showNewDocument = true } }
              else { Button("필터 초기화") { window.filter = .init() } }
            }.padding(20).frame(maxWidth: .infinity)
          }
          ForEach(documents) { document in
            WikiDocumentLabel(document: document, isDirty: model.drafts[document.id]?.isDirty == true,
              isSelected: window.selectedDocumentID == document.id, showsFolder: duplicateTitles.contains(document.title))
              .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
              .contentShape(Rectangle()).tag(document.id)
              .accessibilityAddTraits(window.selectedDocumentID == document.id ? .isSelected : [])
              .contextMenu {
                if let context = model.documentContext {
                  WikiDocumentContextActions(document: document, context: context, window: window)
                }
              }
          }
        } else if window.isSearching {
          ProgressView("검색 중…").frame(maxWidth: .infinity)
        } else if window.hits.isEmpty && window.searchState.error == nil {
          Text("일치하는 노트가 없습니다").font(.callout).foregroundStyle(.secondary)
            .padding(.vertical, 12)
        } else {
          ForEach(window.hits) { hit in
            WikiSearchHitLabel(hit: hit, query: window.query, snapshot: snapshot,
              isSelected: window.selectedSectionID == hit.reference.sectionID)
              .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
              .contentShape(Rectangle()).tag(hit.id)
              .accessibilityAddTraits(window.selectedSectionID == hit.reference.sectionID ? .isSelected : [])
          }
        }
        if window.hasSearchQuery { WikiSearchStatus(model: model, window: window) }
        WikiRecoverySections(model: model, window: window, snapshot: snapshot)
      }
    }.listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(FolioTheme.paper(scheme))
  }

  private var documentSelection: Binding<String?> {
    Binding(get: { window.hasSearchQuery ? window.selectedSectionID : window.selectedDocumentID }, set: { id in
      guard let id else { return }
      if window.hasSearchQuery {
        guard let hit = window.hits.first(where: { $0.id == id }) else { return }
        Task { await model.openHit(hit, in: window) }
      } else { window.selectedDocumentID = id }
    })
  }

  private var firstLibrary: some View { FolioWelcomeView { showLibrary = true } }
}
#endif
