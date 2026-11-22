import Foundation
import FolioKnowledge
import Testing
@testable import FolioUI

@Suite struct SelectionReadTests {
  @Test func lateReadCannotApplyOrReportAnErrorAfterTheCurrentSourceChanges() throws {
    let original = try selectionReadDocument(id: "selected", path: "notes/selected.md", revision: "revision-a")
    let read = FolioSelectionRead(document: original, workspaceGeneration: 4, editorGeneration: 9)
    let changedSources: [WikiDocument?] = [
      try selectionReadDocument(id: original.id, path: original.relativePath, revision: "revision-b"),
      try selectionReadDocument(id: original.id, path: "notes/moved.md", revision: original.revision),
      try selectionReadDocument(id: "another-document", path: original.relativePath, revision: original.revision),
      nil,
    ]
    for current in changedSources {
      #expect(!read.isCurrent(document: current, workspaceGeneration: 4, editorGeneration: 9,
        hasOpenWorkspace: true, isDirty: false, isCancelled: false))
    }
    #expect(read.isCurrent(document: original, workspaceGeneration: 4, editorGeneration: 9,
      hasOpenWorkspace: true, isDirty: false, isCancelled: false))
  }

  @Test func dirtyDraftCancellationAndRevokedLifetimesRejectReadCompletion() throws {
    let document = try selectionReadDocument(id: "selected", path: "notes/selected.md", revision: "revision-a")
    let read = FolioSelectionRead(document: document, workspaceGeneration: 4, editorGeneration: 9)
    let states = [
      (workspace: 5, editor: 9, open: true, dirty: false, cancelled: false),
      (workspace: 4, editor: 10, open: true, dirty: false, cancelled: false),
      (workspace: 4, editor: 9, open: false, dirty: false, cancelled: false),
      (workspace: 4, editor: 9, open: true, dirty: true, cancelled: false),
      (workspace: 4, editor: 9, open: true, dirty: false, cancelled: true),
    ]
    for state in states {
      #expect(!read.isCurrent(document: document, workspaceGeneration: state.workspace, editorGeneration: state.editor,
        hasOpenWorkspace: state.open, isDirty: state.dirty, isCancelled: state.cancelled))
    }
  }

  @Test func automaticRefreshRunsOncePerSourceRevisionAcrossDuplicateReadersAndResetsWithWorkspace() throws {
    var refreshes = FolioSelectionReadRefreshes()
    let original = try selectionReadDocument(id: "selected", path: "notes/selected.md", revision: "revision-a")
    let changed = try selectionReadDocument(id: original.id, path: original.relativePath, revision: "revision-b")
    let read = FolioSelectionRead(document: original, workspaceGeneration: 4, editorGeneration: 9)
    let duplicateWindow = FolioSelectionRead(document: original, workspaceGeneration: 4, editorGeneration: 10)
    let changedRead = FolioSelectionRead(document: changed, workspaceGeneration: 4, editorGeneration: 10)
    let reopenedRead = FolioSelectionRead(document: original, workspaceGeneration: 5, editorGeneration: 11)
    let firstAttempt = refreshes.begin(read)
    let duplicateAttempt = refreshes.begin(duplicateWindow)
    let changedAttempt = refreshes.begin(changedRead)
    let repeatedOriginalAttempt = refreshes.begin(read)
    let reopenedAttempt = refreshes.begin(reopenedRead)
    let repeatedReopenedAttempt = refreshes.begin(reopenedRead)

    #expect(firstAttempt)
    #expect(!duplicateAttempt)
    #expect(changedAttempt)
    #expect(!repeatedOriginalAttempt)
    #expect(reopenedAttempt)
    #expect(!repeatedReopenedAttempt)
  }
}

private func selectionReadDocument(id: String, path: String, revision: String) throws -> WikiDocument {
  let fields: [String: Any] = ["id": id, "relativePath": path, "title": id, "aliases": [String](),
    "revision": revision, "sections": [Any](), "declarations": [Any]()]
  return try JSONDecoder().decode(WikiDocument.self, from: JSONSerialization.data(withJSONObject: fields))
}
