import Foundation
import FolioKnowledge
import FolioKnowledgeApple

/// Owns selection reads and their revision-based refresh history.
/// Reads stay in the caller's task and use the session's current source lifetime.
@MainActor
final class FolioDocumentReader {
  private var refreshes = FolioSelectionReadRefreshes()
  var onMessage: (@MainActor (String) -> Void)?

  private let session: FolioWorkspaceSession
  private let draftStore: FolioDraftStore
  private let history: FolioLibraryHistory

  init(session: FolioWorkspaceSession, draftStore: FolioDraftStore, history: FolioLibraryHistory) {
    self.session = session
    self.draftStore = draftStore
    self.history = history
  }

  func loadSelection(_ window: WikiWindowState) async {
    guard !Task.isCancelled, session.hasOpenWorkspace, let document = session.document(id: window.selectedDocumentID),
      let workspace = session.workspace else { return }
    let read = FolioSelectionRead(document: document, workspaceGeneration: session.generation,
      editorGeneration: draftStore.editingGeneration)
    if draftStore.drafts[document.id]?.isDirty == true { return }
    do {
      let bytes = try await workspace.source(relativePath: document.relativePath)
      // A file refresh may finish after the user has started typing. Preserve
      // that newly dirty draft instead of replacing it with the fetched baseline.
      guard acceptsSelectionRead(read, in: window) else { return }
      guard SourceDigest.sha256(bytes) == document.revision else { throw WikiError.changedSource }
      let text = String(decoding: bytes, as: UTF8.self)
      draftStore.load(FolioDraft(path: document.relativePath, text: text, original: text, revision: document.revision), id: document.id)
      history.recordOpened(documentID: document.id, workspaceID: session.snapshot?.workspace.id)
    } catch is CancellationError {
    } catch {
      guard acceptsSelectionRead(read, in: window) else { return }
      if (error as? WikiError) == .changedSource {
        if refreshes.begin(read) { session.requestRefresh() }
        else if !session.isRefreshing { onMessage?("원문이 계속 바뀌고 있습니다. 잠시 후 목록을 새로 고쳐 주세요.") }
      } else { onMessage?(error.localizedDescription) }
    }
  }

  private func acceptsSelectionRead(_ read: FolioSelectionRead, in window: WikiWindowState) -> Bool {
    read.isCurrent(document: session.document(id: window.selectedDocumentID), workspaceGeneration: session.generation,
      editorGeneration: draftStore.editingGeneration, hasOpenWorkspace: session.hasOpenWorkspace,
      isDirty: draftStore.drafts[read.documentID]?.isDirty == true, isCancelled: Task.isCancelled)
  }

  func declarationText(_ relation: WikiRelation) async throws -> String {
    guard let workspace = session.workspace,
      let document = session.document(id: relation.sourceID) else {
      throw WikiError.unavailable("관계 원문을 다시 검색해 주세요.")
    }
    let workspaceGeneration = session.generation
    let bytes = try await workspace.source(relativePath: document.relativePath)
    guard workspaceGeneration == session.generation,
      SourceDigest.sha256(bytes) == relation.sourceRevision else { throw WikiError.changedSource }
    return String(decoding: try relation.range.extract(from: bytes), as: UTF8.self)
  }
}
