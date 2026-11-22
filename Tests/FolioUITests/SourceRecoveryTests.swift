#if os(macOS)
import Foundation
import FolioKnowledge
@testable import FolioKnowledgeApple
import Testing
@testable import FolioUI

@Test @MainActor func markdownImportRetryObservesPublishedSourceWithoutRecreatingIt() async throws {
  let fixture = try await SourceRecoveryFixture()
  defer { fixture.cleanup() }
  let base = fixture.base, root = fixture.root, model = fixture.model
  do {
    let workspace = try #require(model.workspace)
    let target = try #require(model.receivedFileTarget)
    let incoming = base.appending(path: "incoming.md")
    try Data("# Imported without an ID\n".utf8).write(to: incoming)
    let plan = try await workspace.prepareMarkdownImport(fromSelectedURL: incoming, operationID: UUID())
    let document = try WikiMarkdownParser.document(relativePath: plan.relativePath, bytes: plan.replacementBytes)
    let submitted = FolioSubmittedDocument(id: document.id, plan: plan, sourceRoot: workspace.root)
    let recoveryScope = try #require(model.draftStore.recoveryScopeURL)
    let key = FolioMarkdownImports.Key(source: incoming, workspace: workspace, recoveryScope: recoveryScope)
    model.markdownImports.retain(submitted, for: key)
    _ = try await workspace.execute(plan)
    // Model the durable state left by publication followed by a failed receipt:
    // the writer's source and intent exist, but its receipt is unavailable.
    let receipts = await workspace.receiptDirectory
    try FileManager.default.removeItem(at: receipts.appending(path: plan.operationID.uuidString + ".json"))
    #expect(try await workspace.operationStatus(plan.operationID).state == .uncertain)

    // An externally changed published file must remain uncertain, not be
    // replaced or imported again under a fresh ID/path.
    let published = root.appending(path: plan.relativePath)
    let changed = plan.replacementBytes + Data("\nExternal addition.\n".utf8)
    try changed.write(to: published)
    #expect(!(await model.importSource(incoming, in: WikiWindowState(), expectedTarget: target)))
    #expect(try Data(contentsOf: published) == changed)
    #expect(model.hasPendingMarkdownImport(incoming))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "notes").path).count == 1)

    try plan.replacementBytes.write(to: published)
    try FileManager.default.removeItem(at: incoming)
    // Nearby retries use a fresh staging URL but the same original file identity.
    let newStaging = base.appending(path: "another-staging/incoming.md")
    let window = WikiWindowState()
    #expect(await model.importSource(newStaging, in: window, expectedTarget: target, sourceIdentity: incoming))
    #expect(window.selectedDocumentID == document.id)
    #expect(try Data(contentsOf: published) == plan.replacementBytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "notes").path).count == 1)
    #expect(!model.hasPendingMarkdownImport(incoming))

    // Result checking is read-only even when absence becomes certain. A new
    // source effect requires the next explicit Add, not the Check Result action.
    let unsubmitted = base.appending(path: "unsubmitted.md")
    try Data("# Not submitted\n".utf8).write(to: unsubmitted)
    let absent = try await workspace.prepareMarkdownImport(fromSelectedURL: unsubmitted, operationID: UUID())
    let absentDocument = try WikiMarkdownParser.document(relativePath: absent.relativePath, bytes: absent.replacementBytes)
    let pending = FolioSubmittedDocument(id: absentDocument.id, plan: absent, sourceRoot: workspace.root)
    model.markdownImports.retain(pending, for: .init(source: unsubmitted, workspace: workspace, recoveryScope: recoveryScope))
    #expect(!(await model.importSource(unsubmitted, in: window, expectedTarget: target)))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: absent.relativePath).path))
    #expect(!model.hasPendingMarkdownImport(unsubmitted))
    #expect(await model.importSource(unsubmitted, in: window, expectedTarget: target))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "notes").path).count == 2)
  } catch {
    await model.close()
    throw error
  }
  await model.close()
}

@Test(arguments: [false, true]) @MainActor
func terminationKeepsRawInputUntilExplicitlyDiscardedOrSaved(save: Bool) async throws {
  let fixture = try await SourceRecoveryFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    await model.showOntology()
    let selection = try #require(model.repairSelection)
    let edited = selection.text + "\n<!-- Private unsaved raw edit -->\n"
    selection.edit(edited)
    // Losing the window/presentation must not release the only input owner.
    model.repairSelection = nil
    await #expect(throws: WikiError.self) { try await model.closeForTermination() }
    #expect(!model.terminationRequested)
    #expect(model.draftStore.acceptsPrivateInput)
    #expect(model.repairSelection === selection)
    #expect(selection.editedText == edited)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "_ontology.md").path))

    // Another source presentation may not replace the protected buffer.
    model.repairSelection = .init(path: "notes/other.md", revision: nil, text: "other",
      sourceRoot: selection.sourceRoot, workspaceID: selection.workspaceID)
    #expect(model.repairSelection === selection)
    if save {
      let newer = edited + "New input after pressing Save.\n"
      selection.edit(newer)
      await model.repairSource(selection, text: edited)
      #expect(try String(contentsOf: fixture.root.appending(path: "_ontology.md"), encoding: .utf8) == edited)
      #expect(model.repairSelection === selection)
      #expect(selection.editedText == newer)
      #expect(selection.text == edited)
      #expect(selection.revision == SourceDigest.sha256(edited))
      await #expect(throws: WikiError.self) { try await model.closeForTermination() }
      await model.repairSource(selection, text: newer)
      #expect(try String(contentsOf: fixture.root.appending(path: "_ontology.md"), encoding: .utf8) == newer)
    } else {
      let confirmedText = selection.editedText
      let newer = confirmedText + "New input while discard confirmation is open.\n"
      selection.edit(newer)
      #expect(!selection.discardChanges(matching: confirmedText))
      #expect(selection.editedText == newer)
      await #expect(throws: WikiError.self) { try await model.closeForTermination() }
      #expect(selection.discardChanges(matching: newer))
      model.repairSelection = nil
      #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "_ontology.md").path))
    }
    try await model.closeForTermination()
    #expect(model.terminationRequested)
  } catch {
    await model.close()
    throw error
  }
}

@Test @MainActor func quickComposeCreatesOnceAndRetainsAnEarlierDirtyDraft() async throws {
  let f = try await SourceRecoveryFixture(); defer { f.cleanup() }
  let window = WikiWindowState()
  let first = Task { await f.model.quickCreateDocument(in: window) }
  await Task.yield()
  await f.model.quickCreateDocument(in: window)
  await first.value
  let id = try #require(window.selectedDocumentID)
  let draft = try #require(f.model.drafts[id])
  #expect(window.isEditing)
  #expect(f.model.snapshot?.documents.count == 1)
  #expect(!window.isCreatingDocument)
  f.model.draftStore.edit(draft.text + "\n이어 쓸 내용\n", id: id)
  f.model.persistDrafts()
  await f.model.quickCreateDocument(in: window)
  #expect(window.selectedDocumentID != id && window.isEditing)
  #expect(f.model.snapshot?.documents.count == 2)
  #expect(f.model.drafts[id]?.text.hasSuffix("이어 쓸 내용\n") == true)
  #expect(f.model.drafts[id]?.isDirty == true)
  await f.model.close()
}

@Test @MainActor func quickComposeChecksAnUnconfirmedAttemptWithoutReplayingIt() async throws {
  let f = try await SourceRecoveryFixture(); defer { f.cleanup() }
  let workspace = try #require(f.model.workspace)
  let plan = try await workspace.prepareEdit(relativePath: "notes/pending.md", expectedRevision: nil, range: nil,
    replacement: FolioInput.documentSource(id: "pending", title: "확인할 문서", body: "원문 보존"), operationID: UUID())
  let submitted = FolioSubmittedDocument(id: "pending", plan: plan, sourceRoot: workspace.root)
  let window = WikiWindowState()
  window.quickCreation = .awaitingResult(submitted)
  for _ in 0..<2 { await f.model.quickCreateDocument(in: window) }
  #expect(!FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent(plan.relativePath).path))
  #expect(f.model.snapshot?.documents.isEmpty == true)
  guard case .awaitingResult(let retained) = window.quickCreation else { Issue.record("Unconfirmed creation must remain observable."); return }
  #expect(retained.operationID == plan.operationID)
  _ = try await workspace.execute(plan)
  let location = try #require(f.model.session.location)
  _ = try await f.model.session.open(location, preserveNavigation: true, willReplace: {}, didLoad: { _ in })
  await f.model.quickCreateDocument(in: window)
  #expect(window.selectedDocumentID == "pending" && window.isEditing)
  #expect(f.model.snapshot?.documents.count == 1)
  #expect(try Data(contentsOf: workspace.root.appendingPathComponent(plan.relativePath)) == plan.replacementBytes)
  await f.model.close()
}

@MainActor private struct SourceRecoveryFixture {
  let base: URL
  let root: URL
  let model: WikiAppModel
  let defaults: UserDefaults
  let defaultsName: String

  init() async throws {
    base = FileManager.default.temporaryDirectory.appending(path: "FolioSourceRecovery-" + UUID().uuidString)
    root = base.appending(path: "Source")
    defaultsName = "FolioSourceRecovery-" + UUID().uuidString
    defaults = try #require(UserDefaults(suiteName: defaultsName))
    try WikiWorkspace.create(at: root, name: "Source recovery")
    let storage = FolioStorageAccess()
    let state = base.appending(path: "State")
    let session = FolioWorkspaceSession(defaults: defaults, storageAccess: storage,
      stateRoot: { state }, applyIndex: { _ in })
    let model = WikiAppModel(session: session, storageAccess: storage, history: FolioLibraryHistory(defaults: defaults),
      nearbyEnabled: false, migrateLegacyStorage: false)
    self.model = model
    let repository = FolioDraftRepository(url: base.appending(path: "drafts.json"))
    let location = WikiWorkspaceLocation.externalMac(bookmark: try WikiWorkspaceAccess.bookmark(for: root))
    _ = try await session.open(location, preserveNavigation: false, willReplace: {}, didLoad: { _ in
      try model.draftStore.bind(repository)
    })
  }

  func cleanup() {
    defaults.removePersistentDomain(forName: defaultsName)
    try? FileManager.default.removeItem(at: base)
  }
}
#endif
