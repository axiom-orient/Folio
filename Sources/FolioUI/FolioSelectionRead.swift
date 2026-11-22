import FolioKnowledge

/// A read may update a draft or report an error only while its source is still selected.
struct FolioSelectionRead: Sendable {
  let workspaceGeneration: Int
  let editorGeneration: Int
  let documentID: String
  let path: String
  let revision: String

  init(document: WikiDocument, workspaceGeneration: Int, editorGeneration: Int) {
    self.workspaceGeneration = workspaceGeneration
    self.editorGeneration = editorGeneration
    documentID = document.id
    path = document.relativePath
    revision = document.revision
  }

  func isCurrent(document: WikiDocument?, workspaceGeneration: Int, editorGeneration: Int,
    hasOpenWorkspace: Bool, isDirty: Bool, isCancelled: Bool
  ) -> Bool {
    hasOpenWorkspace && !isCancelled && !isDirty
      && self.workspaceGeneration == workspaceGeneration && self.editorGeneration == editorGeneration
      && document?.id == documentID && document?.relativePath == path && document?.revision == revision
  }
}

/// One automatic refresh per observed source revision prevents read/refresh recursion.
struct FolioSelectionReadRefreshes {
  private struct Source: Hashable {
    let documentID: String
    let path: String
    let revision: String
  }
  private var workspaceGeneration: Int?
  private var attemptedSources: Set<Source> = []

  mutating func begin(_ read: FolioSelectionRead) -> Bool {
    if workspaceGeneration != read.workspaceGeneration {
      workspaceGeneration = read.workspaceGeneration
      attemptedSources = []
    }
    return attemptedSources.insert(Source(documentID: read.documentID, path: read.path, revision: read.revision)).inserted
  }
}
