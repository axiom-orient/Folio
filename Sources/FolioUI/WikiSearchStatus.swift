import SwiftUI

/// Search tools and source coverage belong above the first result.
struct WikiSearchTools: View {
  let model: WikiAppModel
  let window: WikiWindowState
  let showFilters: () -> Void
  var beforePresentation: () -> Void = {}

  @State private var showSemantic = false
  @State private var showKnowledge = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button {
          beforePresentation()
          showKnowledge = true
        } label: {
          Label("PDF·노트 근거 찾기", systemImage: "text.bubble")
            .frame(minHeight: minimumControlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("knowledge-search-open")
        Spacer(minLength: 4)
        Menu {
          Button("뜻으로 찾기", systemImage: "sparkle.magnifyingglass") {
            beforePresentation()
            showSemantic = true
          }
          .accessibilityIdentifier("semantic-search-open")
          Button("폴더·태그", systemImage: "line.3.horizontal.decrease", action: showFilters)
            .accessibilityIdentifier("document-filters")
        } label: {
          Label("검색 옵션", systemImage: "ellipsis")
            .labelStyle(.iconOnly)
            .frame(minWidth: minimumControlHeight, minHeight: minimumControlHeight)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("search-options")
      }
      .disabled(!model.hasOpenWorkspace)
      if let results = window.searchState.results {
        if results.totalCount > 0 {
          Text(results.hits.count == results.totalCount
            ? "검색 결과 \(results.totalCount)개"
            : "검색 결과 \(results.totalCount)개 중 \(results.hits.count)개 표시")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("search-result-count")
        }
        if !results.coverageComplete {
          Label("일부 원문을 읽지 못했습니다.", systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .sheet(isPresented: $showKnowledge) {
      FolioKnowledgeQueryView(model: model, window: window, initialQuestion: window.query)
    }
    .sheet(isPresented: $showSemantic) { FolioSemanticReviewView(model: model, window: window, document: nil) }
  }

  private var minimumControlHeight: CGFloat {
    #if os(iOS)
    44
    #else
    32
    #endif
  }
}

/// Source collection offers one entry while keeping import and writing distinct.
struct WikiLibraryAddMenu: View {
  let model: WikiAppModel
  let window: WikiWindowState
  @Binding var importTarget: FolioReceivedTarget?
  var showsTitle = false
  let configureNote: () -> Void

  var body: some View {
    Menu {
      Button("파일 가져오기…", systemImage: "square.and.arrow.down") {
        importTarget = model.receivedFileTarget
      }
      .disabled(model.receivedFileTarget == nil)
      .accessibilityIdentifier("document-import")
      Divider()
      Button(window.quickCreationTitle, systemImage: "square.and.pencil") {
        Task { await model.quickCreateDocument(in: window) }
      }
      .disabled(window.isCreatingDocument)
      .accessibilityIdentifier("document-create")
      Button("제목·폴더 지정…", action: configureNote)
    } label: {
      Group {
        if showsTitle { Label("자료 추가", systemImage: "plus") }
        else { Label("자료 추가", systemImage: "plus").labelStyle(.iconOnly) }
      }
      #if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
      #endif
    }
    .disabled(!model.hasOpenWorkspace)
    .accessibilityIdentifier("document-add")
    #if os(macOS)
    .menuStyle(.borderlessButton)
    #endif
  }
}

/// Paging and retry stay with the results that can change.
struct WikiSearchStatus: View {
  let model: WikiAppModel
  let window: WikiWindowState

  var body: some View {
    if let error = window.searchState.error {
      VStack(alignment: .leading, spacing: 6) {
        Text(error).font(.callout).foregroundStyle(.secondary)
        Button("검색 다시 시도") { Task { await model.search(window, append: window.searchState.results?.nextCursor != nil) } }
          .buttonStyle(.bordered)
      }
    } else if window.searchState.isLoadingMore {
      ProgressView("다음 결과 불러오는 중…")
    } else if window.searchState.results?.nextCursor != nil {
      Button("검색 결과 더 보기") { Task { await model.search(window, append: true) } }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("search-load-more")
    }
  }
}
