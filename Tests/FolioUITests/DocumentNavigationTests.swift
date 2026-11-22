import Foundation
import FolioKnowledge
import Testing
@testable import FolioUI

@MainActor @Suite struct DocumentNavigationTests {
  @Test func trashRemovesTheSelectionFromBothHistoryDirectionsAndSearch() throws {
    let window = WikiWindowState()
    let removed = try navigationDocument("removed")
    for id in ["a", removed.id, "b", removed.id, "c", removed.id, "d"] { window.selectedDocumentID = id }
    window.goBack(); window.goBack(); window.goBack()
    #expect(window.selectedDocumentID == removed.id)
    window.readingAnchors = ["a": "anchor-a", removed.id: "removed-anchor", "missing": "missing-anchor"]
    window.selectedSectionID = "removed-section"
    window.isEditing = true
    window.query = "retained query"
    window.searchState = .ready(.init(hits: [try navigationHit(removed)], totalCount: 1))
    let searchGeneration = window.searchGeneration
    let staleNavigation = window.beginNavigation()

    window.applyFileChanges(replacements: [:], removedIDs: [removed.id])
    window.reconcileDocuments(try ["a", "b", "c", "d"].map { try navigationDocument($0) }, preservingFileChanges: true)

    #expect(window.selectedDocumentID == nil)
    #expect(window.selectedSectionID == nil)
    #expect(!window.isEditing)
    #expect(window.readingAnchors == ["a": "anchor-a"])
    #expect(window.query == "retained query")
    #expect(window.hits.isEmpty)
    #expect(window.searchGeneration > searchGeneration)
    #expect(!window.completeNavigation(staleNavigation, documentID: removed.id, sectionID: "stale"))
    #expect(window.reconcileNavigationPath(["a", removed.id, "missing", "c"]) == ["a", "c"])

    for expected in ["b", "a"] {
      window.goBack()
      #expect(window.selectedDocumentID == expected)
    }
    #expect(!window.canGoBack)
    #expect(window.selectedSectionID == "anchor-a")
    for expected in ["b", "c", "d"] {
      window.goForward()
      #expect(window.selectedDocumentID == expected)
    }
    #expect(!window.canGoForward)
  }

  @Test func movingAPathBasedDocumentRemapsSelectionHistoryAndNestedNavigation() throws {
    let window = WikiWindowState()
    let old = try navigationDocument("path:notes/old.md", path: "notes/old.md")
    let renamed = try navigationDocument("path:notes/folder/renamed.md", path: "notes/folder/renamed.md")
    for id in ["a", old.id, "b", old.id, "c", old.id, "d"] { window.selectedDocumentID = id }
    window.goBack(); window.goBack(); window.goBack()
    window.readingAnchors = [old.id: "old-path-section", "a": "anchor-a"]
    window.selectedSectionID = "old-path-section"
    window.isEditing = true
    window.searchState = .ready(.init(hits: [try navigationHit(old)], totalCount: 1))

    window.applyFileChanges(replacements: [old.id: renamed.id], removedIDs: [])
    let retained = try ["a", "b", "c", "d"].map { try navigationDocument($0) }
    window.reconcileDocuments(retained + [renamed], preservingFileChanges: true)

    #expect(window.selectedDocumentID == renamed.id)
    #expect(window.selectedSectionID == nil)
    #expect(!window.isEditing)
    #expect(window.hits.isEmpty)
    #expect(window.readingAnchors == ["a": "anchor-a"])
    #expect(window.reconcileNavigationPath(["a", old.id, "missing", "c", old.id])
      == ["a", renamed.id, "c", renamed.id])

    for expected in ["b", renamed.id, "a"] {
      window.goBack()
      #expect(window.selectedDocumentID == expected)
    }
    #expect(!window.canGoBack)
    for expected in [renamed.id, "b", renamed.id, "c", renamed.id, "d"] {
      window.goForward()
      #expect(window.selectedDocumentID == expected)
    }
    #expect(!window.canGoForward)
  }

  @Test func stableIDMoveEndsEditingEvenWhenSelectionIDDoesNotChange() throws {
    let window = WikiWindowState()
    let moved = try navigationDocument("stable-note", path: "notes/new-folder/note.md", stableID: "stable-note")
    window.selectedDocumentID = moved.id
    window.readingAnchors[moved.id] = "previous-section"
    window.selectedSectionID = "previous-section"
    window.isEditing = true
    window.searchState = .ready(.init(hits: [try navigationHit(moved)], totalCount: 1))
    let staleNavigation = window.beginNavigation()
    let searchGeneration = window.searchGeneration

    window.applyFileChanges(replacements: [moved.id: moved.id], removedIDs: [])
    window.reconcileDocuments([moved], preservingFileChanges: true)

    #expect(window.selectedDocumentID == moved.id)
    #expect(!window.isEditing)
    #expect(window.selectedSectionID == nil)
    #expect(window.readingAnchors[moved.id] == nil)
    #expect(window.hits.isEmpty)
    #expect(window.searchGeneration > searchGeneration)
    #expect(!window.completeNavigation(staleNavigation, documentID: moved.id, sectionID: "previous-section"))
    #expect(window.reconcileNavigationPath([moved.id]) == [moved.id])
  }

  @Test func stableIDChangePreservesAnotherWindowsReadingPositionAndHistory() throws {
    let affected = WikiWindowState()
    let unaffected = WikiWindowState()
    let changed = try navigationDocument("changed", path: "notes/moved/changed.md", stableID: "changed")
    let current = try navigationDocument("other")
    let previous = try navigationDocument("previous")
    let next = try navigationDocument("next")

    affected.selectedDocumentID = changed.id
    affected.readingAnchors[changed.id] = "changed-old-section"
    affected.selectedSectionID = "changed-old-section"
    affected.isEditing = true

    for id in [previous.id, current.id, next.id] { unaffected.selectedDocumentID = id }
    unaffected.goBack()
    unaffected.readingAnchors = [previous.id: "previous-section", current.id: "other-section", next.id: "next-section"]
    unaffected.selectedSectionID = "other-section"
    let preservedAnchors = unaffected.readingAnchors
    #expect(unaffected.canGoBack && unaffected.canGoForward)

    for window in [affected, unaffected] {
      window.applyFileChanges(replacements: [changed.id: changed.id], removedIDs: [])
      window.reconcileDocuments([changed, current, previous, next], preservingFileChanges: true)
    }

    #expect(affected.selectedDocumentID == changed.id)
    #expect(affected.selectedSectionID == nil)
    #expect(affected.readingAnchors[changed.id] == nil)
    #expect(!affected.isEditing)
    #expect(unaffected.selectedDocumentID == current.id)
    #expect(unaffected.selectedSectionID == "other-section")
    #expect(unaffected.readingAnchors == preservedAnchors)
    #expect(unaffected.canGoBack && unaffected.canGoForward)

    unaffected.goBack()
    #expect(unaffected.selectedDocumentID == previous.id)
    #expect(unaffected.selectedSectionID == "previous-section")
    #expect(!unaffected.canGoBack)
    unaffected.goForward()
    #expect(unaffected.selectedDocumentID == current.id)
    #expect(unaffected.selectedSectionID == "other-section")
    unaffected.goForward()
    #expect(unaffected.selectedDocumentID == next.id)
    #expect(unaffected.selectedSectionID == "next-section")
    #expect(!unaffected.canGoForward)
  }

  @Test func refreshPrunesExternallyRemovedDocumentsWithoutRecordingAnotherHistoryEntry() throws {
    let window = WikiWindowState()
    for id in ["a", "removed", "b", "removed", "c", "removed", "d"] { window.selectedDocumentID = id }
    window.goBack(); window.goBack(); window.goBack()
    window.readingAnchors = ["a": "anchor-a", "removed": "removed-anchor"]
    window.selectedSectionID = "removed-anchor"
    window.isEditing = true
    let oldRevision = window.documentCatalogRevision

    window.reconcileDocuments(try ["a", "b", "c", "d"].map { try navigationDocument($0) })

    #expect(window.selectedDocumentID == nil)
    #expect(window.selectedSectionID == nil)
    #expect(!window.isEditing)
    #expect(window.readingAnchors == ["a": "anchor-a"])
    #expect(window.documentCatalogRevision > oldRevision)
    #expect(window.reconcileNavigationPath(["a", "removed", "c", "missing"]) == ["a", "c"])
    window.goBack(); #expect(window.selectedDocumentID == "b")
    window.goBack(); #expect(window.selectedDocumentID == "a")
    #expect(!window.canGoBack)
    for expected in ["b", "c", "d"] {
      window.goForward()
      #expect(window.selectedDocumentID == expected)
    }
    #expect(!window.canGoForward)
  }

  @Test func pendingSourcePreservesSelectionReadingPositionAndHistoryUntilItReturns() throws {
    let window = WikiWindowState()
    let previous = try navigationDocument("previous")
    let pending = try navigationDocument("pending")
    let next = try navigationDocument("next")
    for id in [previous.id, pending.id, next.id] { window.selectedDocumentID = id }
    window.goBack()
    window.readingAnchors = [previous.id: "previous-section", pending.id: "pending-section"]
    window.selectedSectionID = "pending-section"
    window.isEditing = true
    window.query = "MCP"
    window.filter = WikiDocumentFilter(tag: "AI agent")
    let revision = window.documentCatalogRevision
    let path = [previous.id, pending.id]

    window.reconcileDocuments([previous, next], unavailableDocumentIDs: [pending.id])

    #expect(window.selectedDocumentID == pending.id)
    #expect(window.selectedSectionID == "pending-section")
    #expect(window.isEditing)
    #expect(window.readingAnchors[pending.id] == "pending-section")
    #expect(window.canGoBack && window.canGoForward)
    #expect(window.query == "MCP")
    #expect(window.filter == WikiDocumentFilter(tag: "AI agent"))
    #expect(window.documentCatalogRevision > revision)
    #expect(window.navigationPath(selecting: window.selectedDocumentID, in: path) == path)

    window.reconcileDocuments([previous, pending, next])

    #expect(window.selectedDocumentID == pending.id)
    #expect(window.selectedSectionID == "pending-section")
    #expect(window.isEditing)
    #expect(window.navigationPath(selecting: window.selectedDocumentID, in: path) == path)
    window.goBack(); #expect(window.selectedDocumentID == previous.id)
    #expect(!window.canGoBack)
    window.goForward(); #expect(window.selectedDocumentID == pending.id)
    #expect(window.selectedSectionID == "pending-section")
    window.goForward(); #expect(window.selectedDocumentID == next.id)
    #expect(!window.canGoForward)
  }

  @Test func confirmedDeletionAfterPendingSourceStillClearsItsRouteAndEditing() throws {
    let window = WikiWindowState()
    let previous = try navigationDocument("previous")
    let pending = try navigationDocument("pending")
    let next = try navigationDocument("next")
    for id in [previous.id, pending.id, next.id] { window.selectedDocumentID = id }
    window.goBack()
    window.readingAnchors = [previous.id: "previous-section", pending.id: "pending-section"]
    window.selectedSectionID = "pending-section"
    window.isEditing = true
    window.query = "MCP"
    window.reconcileDocuments([previous, next], unavailableDocumentIDs: [pending.id])

    window.reconcileDocuments([previous, next])

    #expect(window.selectedDocumentID == nil)
    #expect(window.selectedSectionID == nil)
    #expect(!window.isEditing)
    #expect(window.readingAnchors == [previous.id: "previous-section"])
    #expect(window.query == "MCP")
    #expect(window.reconcileNavigationPath([previous.id, pending.id, next.id]) == [previous.id, next.id])
    window.goBack(); #expect(window.selectedDocumentID == previous.id)
    #expect(!window.canGoBack)
    window.goForward(); #expect(window.selectedDocumentID == next.id)
    #expect(!window.canGoForward)
  }

  @Test func workspaceResetDoesNotCarryUnavailableRoutesIntoTheNextSnapshot() throws {
    let window = WikiWindowState()
    let previousPending = try navigationDocument("previous-workspace-pending")
    let current = try navigationDocument("current-workspace-document")
    let currentPending = try navigationDocument("current-workspace-pending")
    window.selectedDocumentID = previousPending.id
    window.readingAnchors[previousPending.id] = "previous-section"
    window.selectedSectionID = "previous-section"
    window.isEditing = true
    window.reconcileDocuments([], unavailableDocumentIDs: [previousPending.id])
    let previousNavigation = window.beginNavigation()

    window.resetNavigation()
    window.reconcileDocuments([current], unavailableDocumentIDs: [currentPending.id])

    let acceptedPreviousNavigation = window.completeNavigation(previousNavigation,
      documentID: previousPending.id, sectionID: "previous-section")
    #expect(!acceptedPreviousNavigation)
    #expect(window.selectedDocumentID == nil)
    #expect(window.readingAnchors.isEmpty)
    #expect(!window.isEditing)
    #expect(!window.canGoBack && !window.canGoForward)
    #expect(window.reconcileNavigationPath([previousPending.id, current.id, currentPending.id])
      == [current.id, currentPending.id])

    window.reconcileDocuments([current])

    #expect(window.reconcileNavigationPath([previousPending.id, current.id, currentPending.id]) == [current.id])
  }

  @Test func ordinaryRefreshDoesNotRemapANewDocumentAtThePreviousPath() throws {
    let window = WikiWindowState()
    let old = try navigationDocument("path:notes/original.md", path: "notes/original.md")
    let moved = try navigationDocument("path:notes/moved.md", path: "notes/moved.md")
    window.selectedDocumentID = old.id
    window.applyFileChanges(replacements: [old.id: moved.id], removedIDs: [])
    window.reconcileDocuments([moved], preservingFileChanges: true)
    #expect(window.reconcileNavigationPath([old.id]) == [moved.id])

    window.reconcileDocuments([old, moved])
    #expect(window.reconcileNavigationPath([old.id, moved.id]) == [old.id, moved.id])
    #expect(window.selectedDocumentID == moved.id)
  }

  @Test(arguments: [true, false])
  func renameObserversConvergeWithoutPushingTheMovedDocumentTwice(selectionObserverFirst: Bool) throws {
    let window = WikiWindowState()
    let root = try navigationDocument("root")
    let parent = try navigationDocument("parent")
    let old = try navigationDocument("path:notes/old.md", path: "notes/old.md")
    let moved = try navigationDocument("path:notes/folder/new.md", path: "notes/folder/new.md")
    window.reconcileDocuments([root, parent, old])
    window.selectedDocumentID = old.id
    var path = [root.id, parent.id, old.id]

    window.applyFileChanges(replacements: [old.id: moved.id], removedIDs: [])
    window.reconcileDocuments([root, parent, moved], preservingFileChanges: true)
    #expect(window.selectedDocumentID == moved.id)

    // SwiftUI can deliver the selected-ID and catalog observers in either order.
    // Their inputs differ, but both use the production path integration function.
    if selectionObserverFirst {
      path = window.navigationPath(selecting: moved.id, in: path)
      path = window.navigationPath(selecting: window.selectedDocumentID, in: path)
    } else {
      path = window.navigationPath(selecting: window.selectedDocumentID, in: path)
      path = window.navigationPath(selecting: moved.id, in: path)
    }
    let expected = [root.id, parent.id, moved.id]
    #expect(path == expected)
    #expect(path.filter { $0 == moved.id }.count == 1)

    let afterSelection = window.navigationPath(selecting: moved.id, in: path)
    let afterCatalog = window.navigationPath(selecting: window.selectedDocumentID, in: afterSelection)
    #expect(afterSelection == expected)
    #expect(afterCatalog == expected)
    #expect(window.navigationPath(selecting: moved.id, in: afterCatalog) == expected)
  }

  @Test func resettingNavigationInvalidatesFilePresentationAndPendingNavigation() throws {
    let window = WikiWindowState()
    let context = FolioDocumentContext(root: URL(fileURLWithPath: "/FolioNavigationFixture"), generation: 3)
    window.fileBrowserContext = context
    window.fileAction = WikiFileAction(kind: .rename(path: "notes/old.md"), context: context)
    window.selectedDocumentID = "a"; window.selectedDocumentID = "b"; window.goBack()
    window.readingAnchors = ["a": "anchor"]
    window.selectedSectionID = "anchor"
    window.isEditing = true
    window.applyFileChanges(replacements: ["a": "moved"], removedIDs: [])
    window.reconcileDocuments([try navigationDocument("moved")], preservingFileChanges: true)
    let staleNavigation = window.beginNavigation()

    window.resetNavigation()

    #expect(window.selectedDocumentID == nil)
    #expect(window.selectedSectionID == nil)
    #expect(!window.isEditing)
    #expect(!window.canGoBack && !window.canGoForward)
    #expect(window.readingAnchors.isEmpty)
    #expect(window.fileBrowserContext == nil)
    #expect(window.fileAction == nil)
    #expect(window.reconcileNavigationPath(["a", "moved"]).isEmpty)
    #expect(!window.completeNavigation(staleNavigation, documentID: "a", sectionID: "anchor"))
  }

  @Test func resetInvalidatesARequestBeforeItsFirstSelectionArrives() {
    let window = WikiWindowState()
    let staleNavigation = window.beginNavigation()

    window.resetNavigation()

    #expect(!window.completeNavigation(staleNavigation, documentID: "previous-workspace", sectionID: nil))
    #expect(window.selectedDocumentID == nil)
  }

  @Test(arguments: [nil, "기존 상태 메시지"] as [String?])
  func disabledNearbyNeverRegainsAdmissionThroughLifecycleCalls(_ message: String?) async {
    // ready/start/loadConnection/allowAccess all reject the disabled capability
    // before any Keychain call or Acornry service construction.
    let nearby = FolioNearbyModel(enabled: false)
    nearby.message = message
    nearby.allowAccess()
    nearby.loadConnection()
    await nearby.ready()
    await nearby.start()
    nearby.restrict()
    nearby.allowAccess()
    nearby.loadConnection()
    await nearby.ready()
    await nearby.start()
    nearby.cancelPreparation()
    await nearby.reject(.init())
    await nearby.cancel(.init())
    await nearby.retryStorage(.init())
    await nearby.moveReceived(.init(), toArchive: true)
    await nearby.moveReceived(.init(), toArchive: false)
    await nearby.stop()

    #expect(nearby.snapshot == nil)
    #expect(!nearby.isRunning && !nearby.isStarting && !nearby.isWorking)
    #expect(nearby.received.isEmpty && nearby.archived.isEmpty)
    #expect(nearby.activeTransfers.isEmpty)
    #expect(!nearby.canSend && !nearby.canCancelPreparation && !nearby.needsDeliveryReview)
    #expect(nearby.message == message)
  }
}

// Codable fixtures exercise UI state without opening workspaces, indexes or files.
private func navigationDocument(_ id: String, path: String? = nil, stableID: String? = nil) throws -> WikiDocument {
  var fields: [String: Any] = ["id": id, "relativePath": path ?? "notes/\(id).md", "title": id,
    "aliases": [String](), "revision": "fixture-revision", "sections": [Any](), "declarations": [Any]()]
  if let stableID { fields["stableID"] = stableID }
  return try JSONDecoder().decode(WikiDocument.self, from: JSONSerialization.data(withJSONObject: fields))
}

private func navigationHit(_ document: WikiDocument) throws -> WikiSearchHit {
  let fields: [String: Any] = ["title": document.title, "breadcrumb": [String](), "snippet": "old search result",
    "provenance": ["fts"], "fusedRank": 1,
    "reference": ["workspaceID": "AE805E59-81C2-475A-8416-ED1E17DDFAE1", "documentID": document.id,
      "sectionID": "fixture-section", "relativePath": document.relativePath, "sourceRevision": document.revision,
      "range": ["lowerBound": 0, "upperBound": 1, "startLine": 1, "endLine": 1], "excerptSHA256": "fixture-digest"]]
  return try JSONDecoder().decode(WikiSearchHit.self, from: JSONSerialization.data(withJSONObject: fields))
}
