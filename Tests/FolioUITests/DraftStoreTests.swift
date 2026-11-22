import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import Testing
@testable import FolioUI

@Test @MainActor func draftsWithTheSameWorkspaceIDRemainSeparatedByLocation() throws {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioDraftLocations-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  let id = UUID()
  let localRoot = base.appendingPathComponent("local", isDirectory: true)
  let cloudRoot = base.appendingPathComponent("cloud", isDirectory: true)
  try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
  let localSource = localRoot.appendingPathComponent("source.md")
  let cloudSource = cloudRoot.appendingPathComponent("source.md")
  try Data("local original".utf8).write(to: localSource)
  try Data("cloud original".utf8).write(to: cloudSource)
  let local = try FolioDraftRepository.workspace(id, location: .localManaged(workspaceID: id), directory: base)
  let cloudLocation = WikiWorkspaceLocation.managedCloud(containerIdentifier: "iCloud.example", workspaceID: id)
  let cloud = try FolioDraftRepository.workspace(id, location: cloudLocation, accountID: UUID(), directory: base)
  let otherAccount = try FolioDraftRepository.workspace(id, location: cloudLocation, accountID: UUID(), directory: base)
  #expect(throws: (any Error).self) { try FolioDraftRepository.workspace(id, location: cloudLocation, directory: base) }
  let legacy = FolioDraftRepository(url: base.appendingPathComponent(id.uuidString.lowercased() + ".json"))
  let old = draft(text: "Legacy unassigned edit", original: "Original")
  try legacy.write(["document": old])
  let oldBytes = try Data(contentsOf: legacy.url)
  let accountlessURL = try #require(cloud.accountlessURL)
  struct PreviousScope: Encodable { let kind: String; let workspaceID: UUID; let container: String? }
  let previousEncoder = JSONEncoder()
  previousEncoder.outputFormatting = [.sortedKeys]
  let previousKey = SourceDigest.sha256(try previousEncoder.encode(PreviousScope(kind: "cloud", workspaceID: id, container: "iCloud.example")))
  #expect(accountlessURL.lastPathComponent == "location-" + previousKey + ".json")
  let accountless = FolioDraftRepository(url: accountlessURL)
  let previousCloud = draft(text: "Cloud edit with unknown account", original: "Original")
  try accountless.write(["document": previousCloud])
  let accountlessBytes = try Data(contentsOf: accountlessURL)
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }

  try store.bind(local)
  #expect(store.drafts.isEmpty)
  #expect(store.legacyDrafts["workspace:document"] == old)
  store.load(draft(text: "Original", original: "Original"), id: "document")
  store.edit("Local private edit", id: "document")
  try store.checkpoint()
  try store.bind(cloud)
  #expect(store.drafts.isEmpty)
  store.load(draft(text: "Original", original: "Original"), id: "document")
  store.edit("Cloud private edit", id: "document")
  try store.checkpoint()
  #expect(store.legacyDrafts["workspace:document"] == old)
  #expect(store.legacyDrafts["accountless:document"] == previousCloud)
  try store.bind(otherAccount)
  #expect(store.drafts.isEmpty)
  store.load(draft(text: "Original", original: "Original"), id: "document")
  store.edit("Other account edit", id: "document")
  try store.checkpoint()

  let reopened = FolioDraftStore()
  defer { reopened.cancelPendingWrite() }
  try reopened.bind(local)
  #expect(reopened.drafts["document"]?.text == "Local private edit")
  try reopened.bind(cloud)
  #expect(reopened.drafts["document"]?.text == "Cloud private edit")
  #expect(reopened.legacyDrafts["workspace:document"] == old)
  #expect(reopened.legacyDrafts["accountless:document"] == previousCloud)
  try reopened.bind(otherAccount)
  #expect(reopened.drafts["document"]?.text == "Other account edit")
  reopened.clear()
  #expect(reopened.legacyDrafts["workspace:document"] == old)
  #expect(reopened.legacyDrafts["accountless:document"] == previousCloud)
  #expect(try Data(contentsOf: legacy.url) == oldBytes)
  #expect(try Data(contentsOf: accountlessURL) == accountlessBytes)
  #expect(try Data(contentsOf: localSource) == Data("local original".utf8))
  #expect(try Data(contentsOf: cloudSource) == Data("cloud original".utf8))
}

@Test @MainActor func unreadableLegacyDraftDoesNotBindOrOverwriteEitherRecoveryFile() throws {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioDraftLegacy-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  let id = UUID()
  let repository = try FolioDraftRepository.workspace(id, location: .localManaged(workspaceID: id), directory: base)
  try repository.write(["document": draft(text: "Existing scoped edit")])
  let scopedBytes = try Data(contentsOf: repository.url)
  let legacyURL = try #require(repository.legacyURL)
  let invalid = Data("unreadable old recovery".utf8)
  try invalid.write(to: legacyURL)
  let store = FolioDraftStore()
  #expect(throws: (any Error).self) { try store.bind(repository) }
  #expect(!store.isBound)
  #expect(try Data(contentsOf: repository.url) == scopedBytes)
  #expect(try Data(contentsOf: legacyURL) == invalid)
}

@Test func draftRepositoryPreservesTheFourFieldSchemaAndWritesOnlyDirtyDrafts() throws {
  let fixture = try DraftFixture()
  defer { fixture.cleanup() }
  let dirty = draft(text: "Edited text", original: "Original text", revision: "source-revision")
  let clean = draft(text: "Unchanged", original: "Unchanged")
  try fixture.repository.write(["dirty": dirty, "clean": clean])

  let data = try Data(contentsOf: fixture.url)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
  #expect(Set(object.keys) == ["dirty"])
  let record = try #require(object["dirty"])
  #expect(Set(record.keys) == ["path", "text", "original", "revision"])
  #expect(record["path"] as? String == dirty.path)
  #expect(record["text"] as? String == dirty.text)
  #expect(record["original"] as? String == dirty.original)
  #expect(record["revision"] as? String == dirty.revision)
  let loaded = try fixture.repository.load()
  #expect(loaded.count == 1)
  #expect(loaded["dirty"]?.path == dirty.path)
  #expect(loaded["dirty"]?.text == dirty.text)
  #expect(loaded["dirty"]?.original == dirty.original)
  #expect(loaded["dirty"]?.revision == dirty.revision)
  #expect(loaded["dirty"]?.isDirty == true)
}

@Test func aMissingDraftRecoveryFileLoadsAsAnEmptyCollection() throws {
  let fixture = try DraftFixture()
  defer { fixture.cleanup() }
  #expect(try fixture.repository.load().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
}

@Test func anOversizedDraftCheckpointPreservesTheLastRecoveryFile() throws {
  let fixture = try DraftFixture()
  defer { fixture.cleanup() }
  try fixture.repository.write(["document": draft(text: "Last safe checkpoint")])
  let original = try Data(contentsOf: fixture.url)
  let oversized = draft(text: String(repeating: "x", count: 16 * 1024 * 1024))

  #expect(throws: (any Error).self) { try fixture.repository.write(["document": oversized]) }
  #expect(try Data(contentsOf: fixture.url) == original)
  #expect(try fixture.repository.load()["document"]?.text == "Last safe checkpoint")
}

@Test @MainActor func aFailedDraftBindNeverOverwritesTheUnknownRecoveryFile() throws {
  let fixture = try DraftFixture()
  defer { fixture.cleanup() }
  let damaged = Data("{ \"document\": invalid recovery JSON".utf8)
  try damaged.write(to: fixture.url)
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }

  #expect(throws: (any Error).self) { try store.bind(fixture.repository) }
  store.load(draft(text: "Original", original: "Original"), id: "document")
  store.edit("New typing must remain in memory.", id: "document")
  #expect(throws: (any Error).self) { try store.checkpoint() }
  #expect(try Data(contentsOf: fixture.url) == damaged)
  #expect(store.drafts["document"]?.text == "New typing must remain in memory.")
}

@Test @MainActor func aFailedRebindDisablesThePreviouslyBoundDraftRepository() throws {
  let original = try DraftFixture()
  let damaged = try DraftFixture()
  defer { original.cleanup(); damaged.cleanup() }
  try original.repository.write(["document": draft(text: "Old recovery")])
  let originalBytes = try Data(contentsOf: original.url)
  let invalidBytes = Data("not JSON".utf8)
  try invalidBytes.write(to: damaged.url)
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }
  try store.bind(original.repository)

  #expect(throws: (any Error).self) { try store.bind(damaged.repository) }
  store.load(draft(text: "Clean baseline", original: "Clean baseline"), id: "new-document")
  store.edit("Unsaved replacement", id: "new-document")
  #expect(throws: (any Error).self) { try store.checkpoint() }
  #expect(try Data(contentsOf: original.url) == originalBytes)
  #expect(try Data(contentsOf: damaged.url) == invalidBytes)
}

@Test @MainActor func lateSourceLoadingCannotReplaceADirtyDraftBaseline() {
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }
  store.load(draft(text: "Original", original: "Original", revision: "revision-one"), id: "document")
  store.edit("Typing in progress", id: "document")
  store.load(draft(text: "Refreshed source", original: "Refreshed source", revision: "revision-two"), id: "document")

  #expect(store.drafts["document"]?.text == "Typing in progress")
  #expect(store.drafts["document"]?.original == "Original")
  #expect(store.drafts["document"]?.revision == "revision-one")
}

@Test @MainActor func completingASaveRebasesNewerTypingOntoTheSubmittedText() {
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }
  let submitted = draft(text: "Submitted edit", original: "Original", revision: "revision-one")
  store.load(submitted, id: "document")
  store.edit("Submitted edit plus newer typing", id: "document")

  store.completeSave(id: "document", path: submitted.path, submittedText: submitted.text, revision: "revision-two")
  #expect(store.drafts["document"]?.text == "Submitted edit plus newer typing")
  #expect(store.drafts["document"]?.original == "Submitted edit")
  #expect(store.drafts["document"]?.revision == "revision-two")
  #expect(store.drafts["document"]?.isDirty == true)
}

@Test @MainActor func completingASaveWithoutNewTypingRemovesTheRecoveryDraft() {
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }
  let submitted = draft(text: "Submitted edit")
  store.load(submitted, id: "document")

  store.completeSave(id: "document", path: submitted.path, submittedText: submitted.text, revision: "revision-two")
  #expect(store.drafts["document"] == nil)
}

@Test @MainActor func completingAnEarlierSaveCannotResurrectARemovedDraft() {
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }
  let submitted = draft(text: "Submitted edit")
  store.load(submitted, id: "document")
  store.remove(id: "document")

  store.completeSave(id: "document", path: submitted.path, submittedText: submitted.text, revision: "revision-two")
  #expect(store.drafts["document"] == nil)
}

@Test @MainActor func discardingAnEditKeepsTheBaselineAndRemovesItsRecoveryRecord() throws {
  let fixture = try DraftFixture()
  defer { fixture.cleanup() }
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }
  try store.bind(fixture.repository)
  store.load(draft(text: "Original", original: "Original", revision: "source-revision"), id: "document")
  store.edit("Draft edit", id: "document")
  try store.checkpoint()
  #expect(try fixture.repository.load()["document"]?.text == "Draft edit")

  store.discard(id: "document")
  try store.checkpoint()
  #expect(store.drafts["document"]?.text == "Original")
  #expect(store.drafts["document"]?.revision == "source-revision")
  #expect(store.drafts["document"]?.isDirty == false)
  #expect(try fixture.repository.load().isEmpty)
}

@Test @MainActor func unboundDirtyDraftsCannotBeReportedAsCheckpointed() throws {
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }
  store.load(draft(text: "Original", original: "Original"), id: "document")
  try store.checkpoint()

  store.edit("Unbound edit", id: "document")
  #expect(throws: (any Error).self) { try store.checkpoint() }
  #expect(store.drafts["document"]?.text == "Unbound edit")
}

@Test @MainActor func documentSavesExcludeOnlyTheSameDocumentUntilCompletion() {
  let store = FolioDraftStore()
  #expect(store.beginSaving(id: "first"))
  #expect(!store.beginSaving(id: "first"))
  #expect(store.beginSaving(id: "second"))
  #expect(store.savingDocuments == ["first", "second"])
  store.endSaving(id: "first")
  #expect(store.savingDocuments == ["second"])
  #expect(store.beginSaving(id: "first"))
}

@Test @MainActor func editDebouncingPersistsAndDetachingCancelsTheNextPendingWrite() async throws {
  let fixture = try DraftFixture()
  defer { fixture.cleanup() }
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }
  var failures: [String] = []
  store.onFailure = { failures.append($0) }
  try store.bind(fixture.repository)
  store.load(draft(text: "Original", original: "Original"), id: "document")
  store.edit("First edit", id: "document")
  // Parallel tests can occupy MainActor before the debounce task even starts.
  // Observe the real checkpoint with a deadline rather than treating 450 ms
  // of elapsed wall time as evidence that the queued write has completed.
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(3))
  var recovered = try fixture.repository.load()["document"]
  while recovered?.text != "First edit", clock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
    recovered = try fixture.repository.load()["document"]
  }
  try #require(recovered?.text == "First edit")

  store.edit("Second edit retained in memory", id: "document")
  store.detach()
  try await Task.sleep(for: .milliseconds(450))
  #expect(try fixture.repository.load()["document"]?.text == "First edit")
  #expect(store.drafts["document"]?.text == "Second edit retained in memory")
  #expect(throws: (any Error).self) { try store.checkpoint() }
  #expect(failures.isEmpty)
}

@Test @MainActor func bindingAnotherRepositoryCancelsThePreviousDocumentsPendingWrite() async throws {
  let original = try DraftFixture()
  let replacement = try DraftFixture()
  defer { original.cleanup(); replacement.cleanup() }
  let store = FolioDraftStore()
  defer { store.cancelPendingWrite() }
  try store.bind(original.repository)
  store.load(draft(text: "Original", original: "Original"), id: "document")
  store.edit("Pending edit from the original workspace", id: "document")

  try store.bind(replacement.repository)
  try await Task.sleep(for: .milliseconds(450))
  #expect(store.drafts.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: original.url.path))
  #expect(!FileManager.default.fileExists(atPath: replacement.url.path))
}

private func draft(text: String, original: String = "Original", revision: String = "revision-one") -> FolioDraft {
  FolioDraft(path: "notes/document.md", text: text, original: original, revision: revision)
}

private struct DraftFixture {
  let base: URL
  let url: URL
  let repository: FolioDraftRepository

  init() throws {
    base = FileManager.default.temporaryDirectory.appending(path: "FolioDrafts-" + UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    url = base.appending(path: "drafts.json")
    repository = FolioDraftRepository(url: url)
  }

  func cleanup() { try? FileManager.default.removeItem(at: base) }
}
