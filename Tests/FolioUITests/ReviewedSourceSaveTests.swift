#if os(macOS)
import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import Testing
@testable import FolioUI

/// These tests exercise the app's actual save lane with isolated source,
/// projection and recovery files; no installed workspace or defaults are used.
@Suite @MainActor struct ReviewedSourceSaveTests {
  @Test(arguments: [false, true], [false, true])
  func aReviewedSourceCannotBeReplacedByALaterChange(snapshotUpdated: Bool, sourceReverted: Bool) async throws {
    let fixture = try await ReviewedSaveFixture()
    do {
      fixture.model.draftStore.edit(fixture.phone, id: fixture.documentID)
      try fixture.model.draftStore.checkpoint()
      let originalDraft = try #require(fixture.model.drafts[fixture.documentID])
      let recovery = try Data(contentsOf: fixture.repository.url)

      try fixture.writeSource(fixture.received)
      _ = try await fixture.session.refreshSnapshot()
      let reviewed = try fixture.reviewCurrentSource()
      #expect(reviewed.revision == SourceDigest.sha256(fixture.received))

      // A reversion to A is also a change from the explicitly reviewed C.
      let changedSource = sourceReverted ? fixture.baseSource : fixture.later
      try fixture.writeSource(changedSource)
      if snapshotUpdated { _ = try await fixture.session.refreshSnapshot() }
      else {
        try #require(fixture.session.document(id: fixture.documentID)?.revision == reviewed.revision)
      }
      // The public entry point must continue to use the earlier reviewed C even
      // when the shared snapshot has already advanced to C2.
      await fixture.model.save(fixture.window)
      #expect(try fixture.readSource() == changedSource)
      #expect(fixture.model.drafts[fixture.documentID] == originalDraft)
      #expect(try Data(contentsOf: fixture.repository.url) == recovery)
      #expect(try fixture.repository.load()[fixture.documentID] == originalDraft)
      let stillCurrentDocument = try #require(fixture.session.document(id: fixture.documentID))
      let context = try #require(fixture.model.documentContext)
      #expect(fixture.model.captureSaveExpectation(for: stillCurrentDocument, context: context) == reviewed)
      #expect(fixture.model.message?.contains("저장하지 않았습니다") == true)

      // A new explicit review admits the new source, while preserving both
      // independent additions and removing only the saved recovery draft.
      _ = try await fixture.session.refreshSnapshot()
      let rereviewed = try fixture.reviewCurrentSource()
      #expect(rereviewed.revision == SourceDigest.sha256(changedSource))
      await fixture.model.save(fixture.window)
      #expect(try fixture.readSource() == changedSource + fixture.phoneAddition)
      #expect(fixture.model.drafts[fixture.documentID]?.isDirty != true)
      #expect(try fixture.repository.load()[fixture.documentID] == nil)
      let savedDocument = try #require(fixture.session.document(id: fixture.documentID))
      let savedContext = try #require(fixture.model.documentContext)
      let savedExpectation = try #require(fixture.model.captureSaveExpectation(for: savedDocument, context: savedContext))
      #expect(savedExpectation.id != rereviewed.id)
    } catch {
      await fixture.close()
      fixture.cleanup()
      throw error
    }
    await fixture.close()
    fixture.cleanup()
  }

  @Test(arguments: ["another-window", "return-to-document"])
  func aReviewedDirtyDraftRemainsPinnedAcrossWindowsAndNavigation(route: String) async throws {
    let fixture = try await ReviewedSaveFixture()
    do {
      if route == "return-to-document" {
        let other = fixture.source.deletingLastPathComponent().appending(path: "other.md")
        try Data("---\nid: other-note\n---\n\n# Other note\n".utf8).write(to: other, options: .atomic)
        _ = try await fixture.session.refreshSnapshot()
      }
      fixture.model.draftStore.edit(fixture.phone, id: fixture.documentID)
      try fixture.model.draftStore.checkpoint()
      let originalDraft = try #require(fixture.model.drafts[fixture.documentID])
      try fixture.writeSource(fixture.received)
      _ = try await fixture.session.refreshSnapshot()
      let reviewed = try fixture.reviewCurrentSource()
      try fixture.writeSource(fixture.later)
      _ = try await fixture.session.refreshSnapshot()

      let saveWindow: WikiWindowState
      if route == "another-window" {
        let otherWindow = WikiWindowState()
        await fixture.model.attach(otherWindow)
        otherWindow.selectedDocumentID = fixture.documentID
        await fixture.model.loadSelection(otherWindow)
        saveWindow = otherWindow
      } else {
        fixture.window.selectedDocumentID = "other-note"
        await fixture.model.loadSelection(fixture.window)
        fixture.window.selectedDocumentID = fixture.documentID
        await fixture.model.loadSelection(fixture.window)
        saveWindow = fixture.window
      }
      let current = try #require(fixture.session.document(id: fixture.documentID))
      let context = try #require(fixture.model.documentContext)
      #expect(fixture.model.captureSaveExpectation(for: current, context: context) == reviewed)
      await fixture.model.save(saveWindow)
      #expect(try fixture.readSource() == fixture.later)
      #expect(fixture.model.drafts[fixture.documentID] == originalDraft)
      #expect(try fixture.repository.load()[fixture.documentID] == originalDraft)
      #expect(fixture.model.message?.contains("저장하지 않았습니다") == true)
    } catch {
      await fixture.close()
      fixture.cleanup()
      throw error
    }
    await fixture.close()
    fixture.cleanup()
  }

  @Test func anUnreviewedStaleDraftRequiresReviewBeforeMerging() async throws {
    let fixture = try await ReviewedSaveFixture()
    do {
      fixture.model.draftStore.edit(fixture.phone, id: fixture.documentID)
      try fixture.model.draftStore.checkpoint()
      let originalDraft = try #require(fixture.model.drafts[fixture.documentID])
      try fixture.writeSource(fixture.received)
      _ = try await fixture.session.refreshSnapshot()
      await fixture.model.save(fixture.window)
      #expect(try fixture.readSource() == fixture.received)
      #expect(fixture.model.drafts[fixture.documentID] == originalDraft)
      #expect(try fixture.repository.load()[fixture.documentID] == originalDraft)
      #expect(fixture.model.message?.contains("문서 정보") == true)
    } catch {
      await fixture.close()
      fixture.cleanup()
      throw error
    }
    await fixture.close()
    fixture.cleanup()
  }

  @Test func reviewingACleanDocumentDoesNotPinALaterFreshEdit() async throws {
    let fixture = try await ReviewedSaveFixture()
    do {
      let original = try #require(fixture.session.document(id: fixture.documentID))
      let context = try #require(fixture.model.documentContext)
      fixture.model.reviewSource(original, in: fixture.window, context: context)
      try fixture.writeSource(fixture.later)
      _ = try await fixture.session.refreshSnapshot()
      try #require(fixture.model.drafts[fixture.documentID]?.original == fixture.later)
      fixture.model.draftStore.edit(fixture.later + fixture.phoneAddition, id: fixture.documentID)
      try fixture.model.draftStore.checkpoint()
      await fixture.model.save(fixture.window)
      #expect(try fixture.readSource() == fixture.later + fixture.phoneAddition)
      #expect(fixture.model.drafts[fixture.documentID]?.isDirty != true)
      #expect(try fixture.repository.load()[fixture.documentID] == nil)
    } catch {
      await fixture.close()
      fixture.cleanup()
      throw error
    }
    await fixture.close()
    fixture.cleanup()
  }

  @Test func anUnreviewedUnchangedSourceStillSavesNormally() async throws {
    let fixture = try await ReviewedSaveFixture()
    do {
      fixture.model.draftStore.edit(fixture.phone, id: fixture.documentID)
      try fixture.model.draftStore.checkpoint()
      await fixture.model.save(fixture.window)
      #expect(try fixture.readSource() == fixture.phone)
      #expect(fixture.model.drafts[fixture.documentID]?.isDirty != true)
      #expect(try fixture.repository.load()[fixture.documentID] == nil)
    } catch {
      await fixture.close()
      fixture.cleanup()
      throw error
    }
    await fixture.close()
    fixture.cleanup()
  }

  @Test(arguments: [false, true])
  func anAlreadyPresentEditKeepsItsRecoveryUntilTheSourceCASCompletes(sourceChanged: Bool) async throws {
    let fixture = try await ReviewedSaveFixture()
    do {
      fixture.model.draftStore.edit(fixture.phone, id: fixture.documentID)
      try fixture.model.draftStore.checkpoint()
      let originalDraft = try #require(fixture.model.drafts[fixture.documentID])
      let recovery = try Data(contentsOf: fixture.repository.url)
      // The received source already contains precisely the private edit, so a
      // rebase to that source would become clean and drop its recovery file.
      try fixture.writeSource(fixture.phone)
      _ = try await fixture.session.refreshSnapshot()
      let reviewed = try fixture.reviewCurrentSource()
      let plan = try #require(FolioDocumentMerge.plan(base: fixture.baseSource,
        edited: fixture.phone, received: fixture.phone))
      #expect(plan.automaticallyMergedSource == fixture.phone)
      if sourceChanged {
        // Exercise the actual already-present commit boundary with C2 in place
        // of the confirmed C. No product-only scheduling hook is installed.
        try fixture.writeSource(fixture.later)
        let workspace = try #require(fixture.session.workspace)
        await #expect(throws: WikiError.changedSource) {
          try await fixture.model.commitDocumentDraft(originalDraft, id: fixture.documentID,
            in: fixture.window, workspace: workspace, generation: fixture.model.workspaceGeneration,
            expectation: reviewed, alreadyPresentSource: fixture.phone)
        }
        #expect(try fixture.readSource() == fixture.later)
        #expect(fixture.model.drafts[fixture.documentID] == originalDraft)
        #expect(try Data(contentsOf: fixture.repository.url) == recovery)
        #expect(try fixture.repository.load()[fixture.documentID] == originalDraft)
      } else {
        // The production save must select the already-present path and retire
        // the recovery copy only after the matching receipt is observed.
        await fixture.model.save(fixture.window)
        #expect(try fixture.readSource() == fixture.phone)
        #expect(fixture.model.drafts[fixture.documentID]?.isDirty != true)
        #expect(try fixture.repository.load()[fixture.documentID] == nil)
      }
    } catch {
      await fixture.close()
      fixture.cleanup()
      throw error
    }
    await fixture.close()
    fixture.cleanup()
  }

  @Test func newerTypingIsNotRetiredWithAnAlreadyPresentEdit() async throws {
    let fixture = try await ReviewedSaveFixture()
    do {
      fixture.model.draftStore.edit(fixture.phone, id: fixture.documentID)
      let submitted = try #require(fixture.model.drafts[fixture.documentID])
      let newer = fixture.phone + "Newer typing.\n"
      fixture.model.draftStore.edit(newer, id: fixture.documentID)
      try fixture.model.draftStore.checkpoint()
      fixture.model.draftStore.completeAlreadyPresent(id: fixture.documentID, expected: submitted)
      #expect(fixture.model.drafts[fixture.documentID]?.text == newer)
      #expect(try fixture.repository.load()[fixture.documentID]?.text == newer)
    } catch {
      await fixture.close()
      fixture.cleanup()
      throw error
    }
    await fixture.close()
    fixture.cleanup()
  }

  @Test func aChangedSourceAfterPreparingTheWriteIsNeverOverwritten() async throws {
    let fixture = try await ReviewedSaveFixture()
    do {
      fixture.model.draftStore.edit(fixture.phone, id: fixture.documentID)
      try fixture.model.draftStore.checkpoint()
      let originalDraft = try #require(fixture.model.drafts[fixture.documentID])
      let workspace = try #require(fixture.session.workspace)
      let plan = try await workspace.prepareRawSave(relativePath: fixture.path,
        expectedRevision: SourceDigest.sha256(fixture.baseSource), replacement: fixture.phone, operationID: UUID())
      try fixture.writeSource(fixture.later)
      await #expect(throws: WikiError.changedSource) { try await workspace.execute(plan) }
      #expect(try fixture.readSource() == fixture.later)
      #expect(fixture.model.drafts[fixture.documentID] == originalDraft)
      #expect(try fixture.repository.load()[fixture.documentID] == originalDraft)
    } catch {
      await fixture.close()
      fixture.cleanup()
      throw error
    }
    await fixture.close()
    fixture.cleanup()
  }
}

@MainActor private struct ReviewedSaveFixture {
  let directory: URL
  let source: URL
  let repository: FolioDraftRepository
  let session: FolioWorkspaceSession
  let model: WikiAppModel
  let window: WikiWindowState
  let defaults: UserDefaults
  let defaultsName: String

  let documentID = "reviewed-note"
  let path = "notes/reviewed.md"
  let baseSource = "---\nid: reviewed-note\n---\n\n# Reviewed note\n\nThe shared baseline.\n"
  let phoneAddition = "\nThe phone addition.\n"
  var phone: String { baseSource + phoneAddition }
  var received: String { baseSource + "\nThe first Mac addition.\n" }
  var later: String { baseSource + "\nThe later Mac addition.\n" }

  init() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "FolioReviewedSave-" + UUID().uuidString, directoryHint: .isDirectory)
    let root = directory.appending(path: "Source", directoryHint: .isDirectory)
    let state = directory.appending(path: "State", directoryHint: .isDirectory)
    let repository = FolioDraftRepository(url: directory.appending(path: "drafts.json"))
    let defaultsName = "FolioReviewedSaveTests-" + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: defaultsName) else { throw WikiError.unavailable("Could not create isolated defaults.") }
    try WikiWorkspace.create(at: root, name: "Reviewed save fixture", workspaceID: UUID())
    let source = root.appending(path: "notes/reviewed.md")
    try Data("---\nid: reviewed-note\n---\n\n# Reviewed note\n\nThe shared baseline.\n".utf8).write(to: source, options: .atomic)
    let storage = FolioStorageAccess()
    let session = FolioWorkspaceSession(defaults: defaults, storageAccess: storage, stateRoot: { state }, applyIndex: { _ in })
    let model = WikiAppModel(session: session, storageAccess: storage, history: FolioLibraryHistory(defaults: defaults),
      nearbyEnabled: false, migrateLegacyStorage: false)
    let window = WikiWindowState()
    self.directory = directory; self.source = source; self.repository = repository; self.session = session
    self.model = model; self.window = window; self.defaults = defaults; self.defaultsName = defaultsName
    let location = WikiWorkspaceLocation.externalMac(bookmark: try WikiWorkspaceAccess.bookmark(for: root))
    _ = try await session.open(location, preserveNavigation: false, willReplace: {}, didLoad: { _ in
      try model.draftStore.bind(repository)
    })
    await model.attach(window)
    guard window.selectedDocumentID == documentID, model.drafts[documentID]?.original == baseSource else {
      await model.close()
      cleanup()
      throw WikiError.unavailable("The isolated workspace did not load its initial draft.")
    }
  }

  func reviewCurrentSource() throws -> FolioDraftStore.ReviewedSource {
    let document = try #require(session.document(id: documentID))
    let context = try #require(model.documentContext)
    model.reviewSource(document, in: window, context: context)
    return try #require(model.captureSaveExpectation(for: document, context: context))
  }

  func writeSource(_ value: String) throws { try Data(value.utf8).write(to: source, options: .atomic) }
  func readSource() throws -> String { try String(contentsOf: source, encoding: .utf8) }
  func close() async { await model.close() }
  func cleanup() {
    defaults.removePersistentDomain(forName: defaultsName)
    try? FileManager.default.removeItem(at: directory)
  }
}
#endif
