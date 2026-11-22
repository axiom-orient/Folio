import FolioCore
import SwiftUI

/// Optional document UI. The host creates the session and owns its storage,
/// filesystem access, account changes, and scene lifetime.
@MainActor
public struct FolioLibraryView: View {
  private let session: FolioSession
  private let onUncheckpointedEdit: @MainActor (Bool) -> Void
  @State private var query = ""
  @State private var hits: [FolioSearchResult]?
  @State private var isLoadingMore = false
  @State private var nextContinuation: FolioSearchContinuation?
  @State private var totalSearchCount = 0
  @State private var searchCoverageComplete = true
  @State private var searchDiagnostics: [String] = []
  @State private var searchGeneration = UUID()
  @State private var activeSearchQuery: String?
  @State private var message: String?
  @State private var compactColumn: NavigationSplitViewColumn = .sidebar
  @State private var hasUncheckpointedEdit = false

  /// `onUncheckpointedEdit` lets a host keep the view alive if a filesystem
  /// checkpoint fails. Do not discard this view or close its session until the
  /// host has retained that native input or the checkpoint succeeds.
  public init(session: FolioSession,
    onUncheckpointedEdit: @escaping @MainActor (Bool) -> Void = { _ in }
  ) {
    self.session = session
    self.onUncheckpointedEdit = onUncheckpointedEdit
  }

  public var body: some View {
    let contextID = session.editingContextID
    let currentDocumentIDs = Set(session.documents.map(\.id))
    let missingSourceDrafts = session.recoverableDrafts.filter { !currentDocumentIDs.contains($0.id) }
    let diagnostics = Array(Set((session.snapshot?.diagnostics ?? []) + searchDiagnostics)).sorted()
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      List {
        Section {
          TextField("문서 검색", text: $query)
            .onSubmit(search)
            .accessibilityIdentifier("folio-sdk-search")
          if let hits {
            Text("검색 결과 \(hits.count) / \(totalSearchCount)")
              .font(.caption).foregroundStyle(.secondary)
            ForEach(hits) { hit in
              Button {
                openDocument(hit.documentID, contextID: contextID)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(hit.title).font(.headline)
                  Text(hit.excerpt).font(.caption).lineLimit(3)
                }
              }
            }
            if nextContinuation != nil {
              Button("결과 더 보기", action: loadMore)
                .disabled(isLoadingMore)
                .accessibilityIdentifier("folio-sdk-search-more")
            }
            if !searchCoverageComplete {
              Text("확인하지 못한 원문이 있어 검색 범위가 완전하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            }
          } else {
            ForEach(session.documents) { document in
              Button {
                openDocument(document.id, contextID: contextID)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(document.title)
                  Text(document.relativePath).font(.caption).foregroundStyle(.secondary)
                }
              }
              .accessibilityAddTraits(session.selectedDocument?.id == document.id ? .isSelected : [])
            }
          }
        }
        if !missingSourceDrafts.isEmpty {
          Section("복구할 초안") {
            Text("원문 목록에 없는 편집 복사본입니다. 내용을 확인하고 공유할 수 있습니다.")
              .font(.caption).foregroundStyle(.secondary)
            ForEach(missingSourceDrafts) { draft in
              Button {
                openDocument(draft.id, contextID: contextID)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(draft.title)
                  Text(draft.relativePath).font(.caption).foregroundStyle(.secondary)
                }
              }
              .accessibilityAddTraits(session.selectedDocument?.id == draft.id ? .isSelected : [])
            }
          }
        }
        if !diagnostics.isEmpty {
          Section("자료함 확인 필요") {
            ForEach(diagnostics, id: \.self) { diagnostic in
              Text(diagnostic).font(.caption).textSelection(.enabled)
            }
          }
        }
      }
      .disabled(session.isBusy || hasUncheckpointedEdit)
      .navigationTitle(session.snapshot?.name ?? "자료함")
      .toolbar {
        ToolbarItem {
          Button("검색", systemImage: "magnifyingglass", action: search)
            .disabled(session.isBusy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .onChange(of: query) { _, value in
        if activeSearchQuery != value.trimmingCharacters(in: .whitespacesAndNewlines) { resetSearch() }
      }
    } detail: {
      if let document = session.selectedDocument {
        FolioDocumentEditor(session: session, document: document, message: $message) { failed in
          hasUncheckpointedEdit = failed
          onUncheckpointedEdit(failed)
        }
        .id(session.editingTarget)
      } else {
        ContentUnavailableView("문서를 선택하세요", systemImage: "doc.text",
          description: Text("문서의 Markdown 원문을 읽고 편집합니다."))
      }
    }
    .onChange(of: session.editingContextID) { _, _ in
      query = ""; resetSearch(); message = nil
      compactColumn = .sidebar
    }
    .alert("문서 작업", isPresented: Binding(
      get: { message != nil }, set: { if !$0 { message = nil } }
    )) {
      Button("확인", role: .cancel) { message = nil }
    } message: {
      Text(message ?? "")
    }
  }

  private func openDocument(_ id: String, contextID: UUID) {
    Task {
      guard session.editingContextID == contextID else { return }
      do {
        try await session.openDocument(id: id)
        guard session.editingContextID == contextID else { return }
        compactColumn = .detail
      } catch {
        guard session.editingContextID == contextID else { return }
        message = error.localizedDescription
      }
    }
  }

  private func search() {
    let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
    resetSearch()
    guard !requested.isEmpty else { return }
    activeSearchQuery = requested
    let context = session.editingContextID
    let generation = searchGeneration
    Task {
      guard session.editingContextID == context,
        searchGeneration == generation,
        query.trimmingCharacters(in: .whitespacesAndNewlines) == requested else { return }
      do {
        let page = try await session.searchPage(requested)
        guard session.editingContextID == context,
          searchGeneration == generation,
          query.trimmingCharacters(in: .whitespacesAndNewlines) == requested else { return }
        hits = page.results
        publishSearchMetadata(page)
      } catch {
        guard session.editingContextID == context, searchGeneration == generation else { return }
        message = error.localizedDescription
      }
    }
  }

  private func loadMore() {
    guard !isLoadingMore, let continuation = nextContinuation, hits != nil, let requested = activeSearchQuery,
      requested == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
    let context = session.editingContextID
    let generation = searchGeneration
    isLoadingMore = true
    Task {
      defer { if searchGeneration == generation { isLoadingMore = false } }
      guard session.editingContextID == context, searchGeneration == generation else { return }
      do {
        let page = try await session.searchPage(requested, continuation: continuation)
        guard session.editingContextID == context, searchGeneration == generation else { return }
        hits = (hits ?? []) + page.results
        publishSearchMetadata(page)
      } catch {
        guard session.editingContextID == context, searchGeneration == generation else { return }
        nextContinuation = nil
        message = "이어 검색을 완료하지 못했습니다. 원문을 확인하고 검색을 다시 실행해 주세요. " + error.localizedDescription
      }
    }
  }

  private func publishSearchMetadata(_ page: FolioSearchPage) {
    nextContinuation = page.nextContinuation
    totalSearchCount = page.totalCount
    searchCoverageComplete = page.coverageComplete
    searchDiagnostics = page.diagnostics
  }

  private func resetSearch() {
    searchGeneration = UUID()
    activeSearchQuery = nil
    hits = nil; nextContinuation = nil; isLoadingMore = false
    totalSearchCount = 0; searchCoverageComplete = true; searchDiagnostics = []
  }
}

