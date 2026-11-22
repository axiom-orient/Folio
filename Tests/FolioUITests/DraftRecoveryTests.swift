import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import Testing
@testable import FolioUI

@Test @MainActor func reviewedDraftRecoversChangedSourceAndRejectsAnotherChange() async throws {
  let fixture = try recoveryFixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let path = "notes/recovered.md"
  let file = fixture.workspace.root.appendingPathComponent(path)
  let original = "---\nid: recovered\n---\n# Original\n\nOriginal text\n"
  let replacement = original + "\nPreserved draft\n"
  let external = Data("---\nid: [\n---\nExternal change\n".utf8)
  try external.write(to: file)
  let draft = WikiAppModel.Draft(path: path, text: replacement, original: original, revision: SourceDigest.sha256(original))
  let selection = try WikiAppModel.RepairSelection.recoveringDraft(id: "recovered", draft: draft,
    observedBytes: external, sourceRoot: fixture.workspace.root, workspaceID: fixture.workspace.workspaceID)
  #expect(selection.observedSourceText == String(decoding: external, as: UTF8.self))
  let plan = try await selection.prepareSave(replacement: selection.text, in: fixture.workspace)
  _ = try await fixture.workspace.execute(plan)
  #expect(try Data(contentsOf: file) == Data(replacement.utf8))

  let rereview = try WikiAppModel.RepairSelection.recoveringDraft(id: "recovered", draft: draft,
    observedBytes: Data(replacement.utf8), sourceRoot: fixture.workspace.root, workspaceID: fixture.workspace.workspaceID)
  let pending = try await rereview.prepareSave(replacement: replacement + "More draft text\n", in: fixture.workspace)
  let later = Data((original + "A later external change\n").utf8)
  try later.write(to: file)
  do {
    _ = try await fixture.workspace.execute(pending)
    Issue.record("A later source change must reject the approved recovery.")
  } catch { #expect(error as? WikiError == .changedSource) }
  #expect(try Data(contentsOf: file) == later)
  await fixture.workspace.close()
}

@Test @MainActor func missingLocalSourceCanBeRecreatedWithoutOverwritingAnArrivingFile() async throws {
  let fixture = try recoveryFixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let source = "---\nid: recovered\n---\n# Restored\n\nPreserved draft\n"
  let draft = WikiAppModel.Draft(path: "notes/missing.md", text: source, original: "Old original", revision: "old-revision")
  let selection = try WikiAppModel.RepairSelection.recoveringDraft(id: "recovered", draft: draft,
    observedBytes: nil, sourceRoot: fixture.workspace.root, workspaceID: fixture.workspace.workspaceID)
  #expect(selection.sourceAvailability == .missingLocal)
  let plan = try await selection.prepareSave(replacement: selection.text, in: fixture.workspace)
  _ = try await fixture.workspace.execute(plan)
  #expect(try Data(contentsOf: fixture.workspace.root.appendingPathComponent(selection.path)) == Data(source.utf8))

  let path = "notes/arriving.md"
  let pending = try await fixture.workspace.prepareRawSave(relativePath: path, expectedRevision: nil,
    replacement: source, operationID: UUID())
  let arriving = Data("---\nid: arriving\n---\n# Arriving original\n".utf8)
  try arriving.write(to: fixture.workspace.root.appendingPathComponent(path))
  do {
    _ = try await fixture.workspace.execute(pending)
    Issue.record("Recovery must not overwrite a file arriving after absence was observed.")
  } catch { #expect(error as? WikiError == .changedSource) }
  #expect(try Data(contentsOf: fixture.workspace.root.appendingPathComponent(path)) == arriving)
  await fixture.workspace.close()
}

@Test @MainActor func missingCloudDraftStaysReachableWithoutRecreationAndCanReleaseTheRestoreLane() async throws {
  let fixture = try recoveryFixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let path = "notes/recovered.md"
  let file = fixture.workspace.root.appendingPathComponent(path)
  let original = "---\nid: recovered\n---\n# Original\n\nOriginal text\n"
  try Data(original.utf8).write(to: file)
  let snapshot = try await fixture.workspace.refresh()
  let document = try #require(snapshot.documents.first { $0.id == "recovered" })
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }
  let repository = FolioDraftRepository(url: fixture.base.appendingPathComponent("drafts.json"))
  try store.bind(repository)
  store.load(.init(path: path, text: original, original: original, revision: document.revision), id: document.id)
  store.edit(original + "\nPrivate editing must survive remote deletion.\n", id: document.id)
  try store.checkpoint()
  let preserved = try #require(store.drafts[document.id])
  let window = WikiWindowState()
  window.reconcileDocuments(snapshot.documents)
  window.selectedDocumentID = document.id
  window.isEditing = true

  // The separate source operation represents a remote deletion; it bypasses
  // the local app's correctly retained prohibition on trashing dirty drafts.
  let deletion = try await fixture.workspace.performFileOperation(.trash(path: path), expectedRevision: document.revision)
  let trashID = try #require(deletion.trashID)
  window.reconcileDocuments(try await fixture.workspace.refresh().documents)
  #expect(window.selectedDocumentID == nil)
  #expect(!window.isEditing)
  #expect(store.drafts.values.contains { $0.isDirty })

  let recovery = try WikiAppModel.RepairSelection.recoveringDraft(id: document.id, draft: preserved,
    observedBytes: nil, sourceRoot: fixture.workspace.root, workspaceID: fixture.workspace.workspaceID, isCloudWorkspace: true)
  #expect(recovery.sourceAvailability == .unavailableCloud)
  #expect(!recovery.sourceAvailability.allowsSave)
  #expect(recovery.text == preserved.text)
  #expect(recovery.draftID == document.id)
  await #expect(throws: WikiError.self) {
    try await recovery.prepareSave(replacement: recovery.text, in: fixture.workspace)
  }
  #expect(!FileManager.default.fileExists(atPath: file.path))
  #expect(store.drafts[document.id] == preserved)
  #expect(try repository.load()[document.id] == preserved)
  let trash = try #require(try await fixture.workspace.trashEntries().first { $0.id == trashID })

  // Read/share uses that same preserved text. Only explicit discard removes it
  // and releases the existing dirty-draft barrier before restoration.
  store.remove(id: document.id)
  try store.checkpoint()
  #expect(!store.drafts.values.contains { $0.isDirty })
  #expect(try repository.load().isEmpty)
  _ = try await fixture.workspace.performFileOperation(.restore(id: trashID), expectedRevision: trash.revision)
  #expect(try Data(contentsOf: file) == Data(original.utf8))
  #expect(try await fixture.workspace.refresh().documents.contains { $0.id == document.id })
  await fixture.workspace.close()
}

@Test @MainActor func unavailableCloudRecoveryRequiresFreshSourceReviewAndKeepsTheRevisionGuard() async throws {
  let fixture = try recoveryFixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let path = "notes/returning.md"
  let file = fixture.workspace.root.appendingPathComponent(path)
  let original = "---\nid: returning\n---\n# Returning document\n\nSaved original\n"
  let edited = original + "\nPreserved private edit\n"
  let draft = FolioDraft(path: path, text: edited, original: original, revision: SourceDigest.sha256(original))
  let unavailable = try WikiAppModel.RepairSelection.recoveringDraft(id: "returning", draft: draft,
    observedBytes: nil, sourceRoot: fixture.workspace.root, workspaceID: fixture.workspace.workspaceID, isCloudWorkspace: true)
  try Data(original.utf8).write(to: file)
  await #expect(throws: WikiError.self) {
    try await unavailable.prepareSave(replacement: edited, in: fixture.workspace)
  }
  #expect(try Data(contentsOf: file) == Data(original.utf8))

  let reviewed = try WikiAppModel.RepairSelection.recoveringDraft(id: "returning", draft: draft,
    observedBytes: try await fixture.workspace.source(relativePath: path), sourceRoot: fixture.workspace.root,
    workspaceID: fixture.workspace.workspaceID, isCloudWorkspace: true)
  #expect(reviewed.sourceAvailability == .observed)
  #expect(reviewed.sourceAvailability.allowsSave)
  let plan = try await reviewed.prepareSave(replacement: edited, in: fixture.workspace)
  let newer = Data((original + "\nA newer external edit\n").utf8)
  try newer.write(to: file)
  do {
    _ = try await fixture.workspace.execute(plan)
    Issue.record("A reviewed cloud recovery must not overwrite a later source change.")
  } catch { #expect(error as? WikiError == .changedSource) }
  #expect(try Data(contentsOf: file) == newer)
  await fixture.workspace.close()
}

private func recoveryFixture() throws -> (base: URL, workspace: WikiWorkspace) {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioRecovery-" + UUID().uuidString, isDirectory: true)
  let root = base.appendingPathComponent("Source", isDirectory: true)
  try WikiWorkspace.create(at: root, name: "Recovery guard")
  return (base, try WikiWorkspace(root: root, localStateDirectory: base.appendingPathComponent("State", isDirectory: true)))
}
