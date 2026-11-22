#if os(iOS)
import FolioKnowledge
import SwiftUI
import UIKit

/// The root keeps navigation and focus ownership; this view presents the current list.
struct WikiIOSHomeView: View {
  let model: WikiAppModel
  @Bindable var window: WikiWindowState
  @Binding var showLibrary: Bool
  @Binding var showBrowse: Bool
  @Binding var isCreatingNote: Bool
  @Binding var showInbox: Bool
  @Binding var documentImportTarget: FolioReceivedTarget?
  @FocusState.Binding var searchFocused: Bool
  let selectFromList: (String) -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let snapshot = model.snapshot {
        List {
          Section {
            if window.isSearchVisible || window.hasSearchQuery {
              WikiSearchTools(model: model, window: window,
                showFilters: { searchFocused = false; showBrowse = true },
                beforePresentation: { searchFocused = false })
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if !window.hasSearchQuery {
              let documents = snapshot.documents.filter(window.filter.matches)
              if snapshot.documents.isEmpty {
                if snapshot.diagnostics.contains(where: { $0.reason == "download_pending" }) {
                  ProgressView("문서를 받는 중…")
                    .padding(.vertical, 12).listRowSeparator(.hidden).listRowBackground(Color.clear)
                } else {
                  ContentUnavailableView {
                    Label("아직 문서가 없습니다", systemImage: "doc.badge.plus")
                  } actions: {
                    Button("문서 가져오기") { documentImportTarget = model.receivedFileTarget }
                      .disabled(model.receivedFileTarget == nil)
                      .buttonStyle(.borderedProminent)
                  }
                  .listRowSeparator(.hidden)
                  .listRowBackground(Color.clear)
                }
              } else if documents.isEmpty {
                ContentUnavailableView {
                  Label("이 범위에 문서가 없습니다", systemImage: "doc.text.magnifyingglass")
                } actions: { Button("모든 문서 보기") { window.filter = .init() } }
              } else {
                let duplicateTitles = folioDuplicateDocumentTitles(documents)
                ForEach(documents) { document in
                  documentRow(document, showsFolder: duplicateTitles.contains(document.title))
                }
              }
            } else if window.isSearching {
              ProgressView("검색 중…").frame(maxWidth: .infinity).listRowSeparator(.hidden)
            } else if window.hits.isEmpty && window.searchState.error == nil {
              Text("일치하는 노트가 없습니다")
              .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
            } else {
              ForEach(window.hits) { hit in
                Button {
                  Task {
                    if await model.openSearchHit(hit, in: window) { selectFromList(hit.reference.documentID) }
                  }
                } label: {
                  WikiSearchHitLabel(hit: hit, query: window.query, snapshot: snapshot)
                  .foregroundStyle(.primary)
                  .padding(.vertical, 12)
                  .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
              }
            }
            if window.hasSearchQuery && !window.isSearching {
              WikiSearchStatus(model: model, window: window)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
          }
          WikiRecoverySections(model: model, window: window, snapshot: snapshot)
        }
        .listStyle(.plain)
        .tint(FolioTheme.accent(colorScheme))
        .safeAreaInset(edge: .top, spacing: 0) {
          VStack(spacing: 0) {
            if window.isSearchVisible || window.hasSearchQuery { searchInput }
            else { libraryHeader }
            if window.filter != .init() { activeScope(documents: snapshot.documents) }
          }.background(FolioTheme.paper(colorScheme))
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(FolioTheme.paper(colorScheme))
        .scrollDismissesKeyboard(.interactively)
      } else {
        FolioWelcomeView { showLibrary = true }
      }
    }
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .tint(FolioTheme.accent(colorScheme))
    .toolbar(.hidden, for: .navigationBar)
    .safeAreaInset(edge: .top, spacing: 0) {
      if model.snapshot == nil {
        Button("받은 파일", systemImage: "tray.and.arrow.down") { showInbox = true }
          .frame(minHeight: 44)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(.horizontal, 20)
      }
    }
  }

  private var libraryHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        Button { showLibrary = true } label: {
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(model.snapshot?.workspace.name ?? "자료함")
              .font(.title2.weight(.semibold))
              .lineLimit(nil)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
          }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(FolioTheme.text(colorScheme))
        .accessibilityLabel("자료함 선택")
        .accessibilityValue(model.snapshot?.workspace.name ?? "")
        .accessibilityIdentifier("library-picker")
        Menu("더 보기", systemImage: "ellipsis") {
          Button("폴더·태그", systemImage: "line.3.horizontal.decrease") { searchFocused = false; showBrowse = true }
            .accessibilityIdentifier("document-filters")
          if model.hasOpenWorkspace {
            Button("문서 정리", systemImage: "folder") { window.fileBrowserContext = model.documentContext }
              .accessibilityIdentifier("document-management")
          }
          Button("받은 파일", systemImage: "tray.and.arrow.down") { showInbox = true }
        }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
          .accessibilityIdentifier("document-list-options")
      }
      if model.hasOpenWorkspace {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { searchShortcut; addMenu }
          VStack(alignment: .leading, spacing: 0) { searchShortcut; addMenu }
        }
      }
    }
    .foregroundStyle(FolioTheme.text(colorScheme))
    .padding(.horizontal, 20).padding(.top, 8)
  }

  private var searchShortcut: some View {
    Button {
      window.isSearchVisible = true
      searchFocused = true
    } label: {
      Label("노트 검색", systemImage: "magnifyingglass")
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .foregroundStyle(FolioTheme.muted(colorScheme))
      .accessibilityIdentifier("document-search-toggle")
  }

  private var addMenu: some View {
    WikiLibraryAddMenu(model: model, window: window, importTarget: $documentImportTarget, showsTitle: true) {
      isCreatingNote = true
    }
    .foregroundStyle(FolioTheme.accent(colorScheme))
  }

  private var searchInput: some View {
    HStack(spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(FolioTheme.muted(colorScheme)).accessibilityHidden(true)
        TextField("노트 검색", text: $window.query)
          .font(.body)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .submitLabel(.search)
          .onSubmit { searchFocused = false }
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .frame(minHeight: 44)
          .accessibilityLabel("노트 검색")
          .accessibilityIdentifier("document-search")
        if !window.query.isEmpty {
          Button("검색 지우기", systemImage: "xmark.circle.fill") { window.query = "" }
            .labelStyle(.iconOnly)
            .foregroundStyle(FolioTheme.muted(colorScheme))
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("document-search-clear")
        }
      }
      .padding(.leading, 12).padding(.trailing, window.query.isEmpty ? 12 : 0)
      .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
      Button("닫기") { window.query = ""; window.isSearchVisible = false; searchFocused = false }
        .buttonStyle(.borderless).frame(minHeight: 44).accessibilityLabel("검색 닫기")
    }
    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
    .disabled(!model.hasOpenWorkspace)
  }

  private func activeScope(documents: [WikiDocument]) -> some View {
    let options = WikiDocumentFilterOptions(documents: documents, folders: model.documentLibrary.folders, filter: window.filter)
    return HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(options.summary)
        .font(.subheadline)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(options.accessibilitySummary)
        .accessibilityIdentifier("document-list-scope")
        .foregroundStyle(FolioTheme.muted(colorScheme))
      Spacer(minLength: 8)
      Button("모두 보기") { window.filter = .init() }
        .font(.subheadline)
        .frame(minHeight: 44)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("document-filter-reset")
    }.padding(.horizontal, 20).padding(.bottom, 4)
  }

  private func documentRow(_ document: WikiDocument, showsFolder: Bool) -> some View {
    Button {
      selectFromList(document.id)
    } label: {
      WikiDocumentLabel(document: document, isDirty: model.drafts[document.id]?.isDirty == true, showsFolder: showsFolder)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    .listRowBackground(Color.clear)
    .contextMenu {
      if let context = model.documentContext {
        WikiDocumentContextActions(document: document, context: context, window: window)
      }
    }
  }

}
#endif
