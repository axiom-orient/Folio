import Foundation
import FolioNearbyTransport
import FolioKnowledge
import FolioKnowledgeApple
import Testing
@testable import FolioUI

@Test @MainActor func workspaceIndexAdmissionAndDrainWaitForTheCancelledJobToFinish() async throws {
  let jobs = FolioWorkspaceJobs()
  let gate = WorkspaceJobGate()
  var runs = 0
  var observedCancellation = false
  #expect(jobs.scheduleIndex {
    runs += 1
    await gate.wait()
    observedCancellation = Task.isCancelled
  })
  #expect(!jobs.scheduleIndex { runs += 1 })
  #expect(try await waitForWorkspaceCondition { runs == 1 })
  jobs.cancel()
  #expect(jobs.isIndexing)

  var drained = false
  let drain = Task { await jobs.drainIndex(); drained = true }
  await Task.yield()
  #expect(!drained)
  await gate.release()
  await drain.value
  #expect(observedCancellation)
  #expect(runs == 1)
  #expect(!jobs.isIndexing)
  #expect(jobs.scheduleIndex {})
  await jobs.drainIndex()
}

@Test @MainActor func workspaceIndexRequestsDuringAnIndexCoalesceIntoOneFollowup() async throws {
  let jobs = FolioWorkspaceJobs()
  let first = WorkspaceJobGate()
  let second = WorkspaceJobGate()
  var runs = 0
  let operation: @MainActor () async -> Void = {
    runs += 1
    if runs == 1 { await first.wait() }
    else { await second.wait() }
  }
  #expect(jobs.scheduleIndex(operation: operation))
  #expect(await first.waitUntilEntered())
  #expect(!jobs.scheduleIndex(operation: operation))
  #expect(!jobs.scheduleIndex(operation: operation))
  await first.release()
  #expect(await second.waitUntilEntered())
  #expect(runs == 2)
  await second.release()
  #expect(try await waitForWorkspaceCondition { !jobs.isIndexing })
  #expect(runs == 2)
}

@Test @MainActor func workspaceRefreshRequestsDuringARefreshCoalesceIntoOneFollowup() async throws {
  let jobs = FolioWorkspaceJobs()
  let first = WorkspaceJobGate()
  let second = WorkspaceJobGate()
  var runs = 0
  let operation: @MainActor () async -> Void = {
    runs += 1
    if runs == 1 { await first.wait() }
    else { await second.wait() }
  }
  jobs.requestRefresh(operation: operation)
  let firstEntered = await first.waitUntilEntered()
  #expect(firstEntered, "The first refresh must enter its held operation before more requests are submitted.")
  guard firstEntered else {
    jobs.cancel()
    await first.release(); await second.release(); await jobs.drainRefresh()
    return
  }
  #expect(runs == 1)
  jobs.requestRefresh(operation: operation)
  jobs.requestRefresh(operation: operation)
  jobs.requestRefresh(operation: operation)
  await first.release()
  let secondEntered = await second.waitUntilEntered()
  #expect(secondEntered, "The coalesced follow-up must enter its held operation.")
  guard secondEntered else {
    jobs.cancel()
    await second.release(); await jobs.drainRefresh()
    return
  }
  #expect(runs == 2)

  let drain = Task { await jobs.drainRefresh() }
  await second.release()
  await drain.value
  #expect(runs == 2)
  #expect(!jobs.isRefreshing)
}

@Test @MainActor func synchronousWorkspaceRevocationPreventsAPendingRefreshFromRunning() async {
  let jobs = FolioWorkspaceJobs()
  var runs = 0
  jobs.requestRefresh { runs += 1 }
  jobs.cancel()
  await jobs.drainRefresh()
  #expect(runs == 0)
  #expect(!jobs.isRefreshing)
}

@Test @MainActor func drainingAnOlderRefreshCannotClearAReplacementRefreshRegistration() async throws {
  let jobs = FolioWorkspaceJobs()
  let first = WorkspaceJobGate()
  let second = WorkspaceJobGate()
  var runs = 0
  jobs.requestRefresh { runs += 1; await first.wait() }
  #expect(try await waitForWorkspaceCondition { runs == 1 })
  let previousDrain = Task { await jobs.drainRefresh() }
  #expect(try await waitForWorkspaceCondition { !jobs.isRefreshing })
  jobs.requestRefresh { runs += 1; await second.wait() }
  #expect(try await waitForWorkspaceCondition { runs == 2 })

  await first.release()
  await previousDrain.value
  #expect(jobs.isRefreshing)
  let finalDrain = Task { await jobs.drainRefresh() }
  await second.release()
  await finalDrain.value
  #expect(!jobs.isRefreshing)
}

@MainActor private func waitForWorkspaceCondition(_ condition: @MainActor () -> Bool) async throws -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(2))
  while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
  return condition()
}

/// Holds a real production job across cancellation until the test explicitly releases it.
private actor WorkspaceJobGate {
  private var released = false
  private var workWaiter: CheckedContinuation<Void, Never>?
  private let entry = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

  func wait() async {
    entry.continuation.yield(())
    entry.continuation.finish()
    guard !released else { return }
    await withCheckedContinuation { workWaiter = $0 }
  }

  /// Observe actual job admission, independently of MainActor polling deadlines.
  /// Both branches terminate on cancellation, so a missing entry cannot hang the test.
  func waitUntilEntered() async -> Bool {
    let signals = entry.stream
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in signals { return true }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(10))
        return false
      }
      let entered = await group.next() ?? false
      group.cancelAll()
      return entered
    }
  }

  func release() {
    released = true
    workWaiter?.resume()
    workWaiter = nil
  }
}

private enum WorkspaceJobTestError: Error, LocalizedError {
  case expected
  var errorDescription: String? { "Expected workspace job failure" }
}

#if os(macOS)
@Test @MainActor func workspaceSessionOpenAndCoalescedCloseRetainOneResourceLifetime() async throws {
  let fixture = try SessionFixture()
  defer { fixture.cleanup() }
  let disconnectGate = WorkspaceJobGate()
  var disconnects = 0
  var blockDisconnect = false
  var prepares = 0
  let session = FolioWorkspaceSession(defaults: fixture.defaults, stateRoot: { fixture.state },
    disconnectProvider: {
      disconnects += 1
      if blockDisconnect { await disconnectGate.wait() }
    }, applyIndex: { _ in })
  let opened = try await openSession(session, fixture: fixture)
  let generation = try #require(opened)
  let workspace = try #require(session.workspace)
  #expect(session.isCurrent(generation))
  #expect(session.hasOpenWorkspace)
  #expect(session.snapshot?.workspace.id == fixture.workspaceID)
  #expect(session.restoredLocation == fixture.location)
  #expect(!session.isBusy)
  blockDisconnect = true

  let firstClose = Task { await session.close { prepares += 1 } }
  let enteredClose = try await waitForWorkspaceCondition { disconnects == 2 }
  #expect(enteredClose)
  if !enteredClose { await disconnectGate.release() }
  let secondClose = Task { await session.close { prepares += 1 } }
  await Task.yield()
  #expect(prepares == 1)
  await disconnectGate.release()
  await firstClose.value
  await secondClose.value
  #expect(prepares == 1)
  #expect(disconnects == 2)
  #expect(!session.isCurrent(generation))
  #expect(!session.hasOpenWorkspace)
  #expect(session.workspace == nil)
  #expect(session.service == nil)
  #expect(session.snapshot == nil)
  await #expect(throws: (any Error).self) { try await workspace.source(relativePath: "_workspace.md") }
}

@Test @MainActor func aSupersededOpenCannotReplaceTheNewWorkspaceOrItsProviderStatus() async throws {
  let first = try SessionFixture()
  let second = try SessionFixture()
  defer { first.cleanup(); second.cleanup() }
  let disconnectGate = WorkspaceJobGate()
  var disconnects = 0
  var obsoleteLoadCalls = 0
  let session = FolioWorkspaceSession(defaults: first.defaults, stateRoot: { first.state },
    connectProvider: { _, callback in callback("Connected to current workspace") },
    disconnectProvider: {
      disconnects += 1
      if disconnects == 1 { await disconnectGate.wait() }
    }, applyIndex: { _ in })
  let obsoleteOpen = Task {
    try await session.open(first.location, preserveNavigation: false, willReplace: {}, didLoad: { _ in obsoleteLoadCalls += 1 })
  }
  let enteredDisconnect = try await waitForWorkspaceCondition { disconnects == 1 }
  #expect(enteredDisconnect)
  if !enteredDisconnect { await disconnectGate.release() }
  let current = try await openSession(session, fixture: second)
  await session.connect()
  await disconnectGate.release()
  let discarded = try await obsoleteOpen.value

  #expect(discarded == nil)
  #expect(current == session.generation)
  #expect(session.workspace?.workspaceID == second.workspaceID)
  #expect(session.snapshot?.workspace.id == second.workspaceID)
  #expect(session.connectionMessage == "Connected to current workspace")
  #expect(obsoleteLoadCalls == 0)
  await session.close(prepare: {})
}

@Test @MainActor func lateProviderCallbacksAreDroppedAfterWorkspaceRevocation() async throws {
  let fixture = try SessionFixture()
  defer { fixture.cleanup() }
  var callback: (@MainActor (String) -> Void)?
  let session = FolioWorkspaceSession(defaults: fixture.defaults, stateRoot: { fixture.state },
    connectProvider: { _, status in callback = status }, applyIndex: { _ in })
  _ = try await openSession(session, fixture: fixture)
  await session.connect()
  let providerStatus = try #require(callback)
  providerStatus("Connected")
  #expect(session.connectionMessage == "Connected")

  let generation = session.generation
  session.restrictMobileAccess(protectedDataAvailable: false, checkpoint: {})
  session.connectionMessage = "Access suspended"
  providerStatus("Obsolete connected status")
  #expect(!session.isCurrent(generation))
  #expect(session.connectionMessage == "Access suspended")
  await session.close(prepare: {})
}

@Test @MainActor func workspaceIndexFailuresAreReportedOnlyForTheCurrentGeneration() async throws {
  let fixture = try SessionFixture()
  defer { fixture.cleanup() }
  var messages: [String] = []
  let session = FolioWorkspaceSession(defaults: fixture.defaults, stateRoot: { fixture.state },
    applyIndex: { _ in throw WorkspaceJobTestError.expected })
  session.onMessage = { messages.append($0) }
  _ = try await openSession(session, fixture: fixture)

  #expect(try await waitForWorkspaceCondition { !messages.isEmpty })
  #expect(messages.count == 1)
  #expect(messages.first?.contains("Expected workspace job failure") == true)
  await session.close(prepare: {})
}

@Test @MainActor func revokedWorkspaceJobsCannotReportLateFailuresIntoTheNextLifetime() async throws {
  let fixture = try SessionFixture()
  defer { fixture.cleanup() }
  let gate = WorkspaceJobGate()
  var indexStarted = false
  var messages: [String] = []
  let session = FolioWorkspaceSession(defaults: fixture.defaults, stateRoot: { fixture.state },
    applyIndex: { _ in
      indexStarted = true
      await gate.wait()
      throw WorkspaceJobTestError.expected
    })
  session.onMessage = { messages.append($0) }
  _ = try await openSession(session, fixture: fixture)
  #expect(try await waitForWorkspaceCondition { indexStarted })

  session.restrictMobileAccess(protectedDataAvailable: false, checkpoint: {})
  await gate.release()
  await session.close(prepare: {})
  #expect(messages.isEmpty)
}

@Test @MainActor func mobileRevocationInvalidatesSynchronouslyAndCheckpointsDraftsBeforeDrain() async throws {
  let fixture = try SessionFixture()
  defer { fixture.cleanup() }
  let repository = FolioDraftRepository(url: fixture.base.appending(path: "drafts.json"))
  let drafts = FolioDraftStore()
  defer { drafts.cancelPendingWrite() }
  try drafts.bind(repository)
  drafts.load(FolioDraft(path: "notes/document.md", text: "Original", original: "Original", revision: "revision"), id: "document")
  drafts.edit("Typing preserved across revocation", id: "document")
  let session = FolioWorkspaceSession(defaults: fixture.defaults, stateRoot: { fixture.state }, applyIndex: { _ in })
  let generation = session.generation
  session.isBusy = true
  var checkpointFailure: (any Error)?
  var checkpointGeneration: Int?
  var checkpointSawRevokedAccess = false

  session.restrictMobileAccess(protectedDataAvailable: false) {
    checkpointGeneration = session.generation
    checkpointSawRevokedAccess = session.isSuspended && !session.protectedDataAvailable
    do { try drafts.checkpoint() } catch { checkpointFailure = error }
    drafts.cancelPendingWrite()
  }
  #expect(checkpointFailure == nil)
  #expect(checkpointGeneration == generation + 1)
  #expect(checkpointSawRevokedAccess)
  #expect(!session.isCurrent(generation))
  #expect(!session.isBusy)
  #expect(!session.hasOpenWorkspace)
  #expect(drafts.drafts["document"]?.text == "Typing preserved across revocation")
  #expect(try repository.load()["document"]?.text == "Typing preserved across revocation")
}

@Test @MainActor func receivedFileRejectsAnotherLocationAndReopenedWorkspaceBeforeAnyImport() async throws {
  let fixture = try SessionFixture()
  defer { fixture.cleanup() }
  let session = FolioWorkspaceSession(defaults: fixture.defaults, stateRoot: { fixture.state }, applyIndex: { _ in })
  _ = try await openSession(session, fixture: fixture)
  let displayed = try #require(FolioReceivedTarget.current(in: session))
  let sameIDCloud = FolioReceivedTarget(location: .managedCloud(containerIdentifier: "iCloud.example", workspaceID: displayed.workspaceID),
    root: displayed.root, workspaceID: displayed.workspaceID, generation: displayed.generation)
  let source = fixture.root.appending(path: "_workspace.md")
  let sourceBefore = try Data(contentsOf: source)
  let received = fixture.base.appending(path: "received.md")
  let receivedBytes = Data("# Received source\n".utf8)
  try receivedBytes.write(to: received)
  let file = AcornrySavedFile(relativePath: "received.md", fileURL: received,
    byteCount: Int64(receivedBytes.count), checksumSHA256: "unused")
  let receipt = AcornryImportReceipt(transferID: AcornryTransferID(), displayName: "received.md", state: .completed,
    files: [.init(relativePath: file.relativePath, outcome: .saved(file, alreadyPresent: false))],
    stagingRemoved: true, cleanupError: nil)
  let intake = FolioFileIntake(session: session, documentLibrary: FolioDocumentLibrary(), nearby: FolioNearbyModel(enabled: false))
  intake.canWriteSource = { true }
  var message: String?
  var imported = false
  intake.onMessage = { message = $0 }
  let importSource: FolioFileIntake.ImportSource = { _ in imported = true; return true }
  let didLink: FolioFileIntake.DidLink = { _, _ in imported = true; return true }

  #expect(!(await intake.importReceived(file, receipt: receipt, target: sameIDCloud,
    importSource: importSource, didLink: didLink)))
  #expect(message == "자료함이 바뀌었습니다. 받은 파일을 다시 선택해 주세요.")
  #expect(!imported)

  intake.canWriteSource = { false }
  #expect(!(await intake.importReceived(file, receipt: receipt, target: displayed,
    importSource: importSource, didLink: didLink)))
  #expect(!imported)
  intake.canWriteSource = { true }

  _ = try await openSession(session, fixture: fixture)
  #expect(FolioReceivedTarget.current(in: session)?.workspaceID == displayed.workspaceID)
  #expect(!(await intake.importReceived(file, receipt: receipt, target: displayed,
    importSource: importSource, didLink: didLink)))
  #expect(!imported)
  #expect(try Data(contentsOf: source) == sourceBefore)
  #expect(try Data(contentsOf: received) == receivedBytes)
  #expect(receipt.savedFiles == [file])
  await session.close {}
}

@Test @MainActor func selectedFileAndPhotoRejectDifferentLocationBeforeSourceEffects() async throws {
  let fixture = try SessionFixture()
  defer { fixture.cleanup() }
  let storage = FolioStorageAccess()
  let session = FolioWorkspaceSession(defaults: fixture.defaults, storageAccess: storage,
    stateRoot: { fixture.state }, applyIndex: { _ in })
  let model = WikiAppModel(session: session, storageAccess: storage, history: FolioLibraryHistory(defaults: fixture.defaults),
    nearbyEnabled: false, migrateLegacyStorage: false)
  let recovery = FolioDraftRepository(url: fixture.base.appendingPathComponent("target-drafts.json"))
  _ = try await session.open(fixture.location, preserveNavigation: false, willReplace: {}, didLoad: { _ in
    try model.draftStore.bind(recovery)
  })
  let actual = try #require(model.receivedFileTarget)
  let other = FolioReceivedTarget(location: .managedCloud(containerIdentifier: "iCloud.example", workspaceID: actual.workspaceID),
    root: actual.root, workspaceID: actual.workspaceID, generation: actual.generation)
  let incoming = fixture.base.appendingPathComponent("incoming.md")
  let incomingBytes = Data("---\nid: incoming\n---\n# Incoming\n".utf8)
  try incomingBytes.write(to: incoming)
  let source = fixture.root.appendingPathComponent("_workspace.md")
  let sourceBytes = try Data(contentsOf: source)
  let workspace = try #require(session.workspace)
  let before = try await workspace.refresh()
  let window = WikiWindowState()

  #expect(!(await model.importSource(incoming, in: window, expectedTarget: other)))
  await model.captureAttachment(incoming, in: window, expectedTarget: other)
  #expect(model.message == "자료함이 바뀌었습니다. 추가할 자료함에서 파일을 다시 선택하세요.")
  let after = try await workspace.refresh()
  #expect(after.documents.map(\.id) == before.documents.map(\.id))
  #expect(try Data(contentsOf: source) == sourceBytes)
  #expect(try Data(contentsOf: incoming) == incomingBytes)
  #expect(try recovery.load().isEmpty)
  await session.close {}
}

@Test @MainActor func failedDraftRecoveryBindingBlocksSourceAdmissionAndProviderConnection() async throws {
  let fixture = try SessionFixture()
  defer { fixture.cleanup() }
  let storage = FolioStorageAccess()
  var connected = false
  let session = FolioWorkspaceSession(defaults: fixture.defaults, storageAccess: storage,
    stateRoot: { fixture.state }, connectProvider: { _, _ in connected = true }, applyIndex: { _ in })
  let model = WikiAppModel(session: session, storageAccess: storage, history: FolioLibraryHistory(defaults: fixture.defaults),
    nearbyEnabled: false, migrateLegacyStorage: false)
  let oldURL = fixture.base.appendingPathComponent("old-recovery.json")
  let invalid = Data("unreadable old recovery".utf8)
  try invalid.write(to: oldURL)
  let repository = FolioDraftRepository(url: fixture.base.appendingPathComponent("new-recovery.json"), legacyURL: oldURL)
  let original = fixture.root.appendingPathComponent("_workspace.md")
  let originalBytes = try Data(contentsOf: original)

  await #expect(throws: (any Error).self) {
    try await session.open(fixture.location, preserveNavigation: false, willReplace: {}, didLoad: { _ in
      try model.draftStore.bind(repository)
    })
  }
  #expect(session.hasOpenWorkspace)
  #expect(!model.hasOpenWorkspace)
  #expect(model.receivedFileTarget == nil)
  await model.connectSEMI()
  #expect(!connected)
  #expect(try Data(contentsOf: oldURL) == invalid)
  #expect(try Data(contentsOf: original) == originalBytes)
  #expect(!FileManager.default.fileExists(atPath: repository.url.path))
  await session.close {}
}

@Test @MainActor func accountRevocationKeepsPrivateInputUntilItsFinalCheckpoint() async throws {
  let fixture = try SessionFixture()
  defer { fixture.cleanup() }
  let storage = FolioStorageAccess()
  let session = FolioWorkspaceSession(defaults: fixture.defaults, storageAccess: storage,
    stateRoot: { fixture.state }, applyIndex: { _ in })
  let model = WikiAppModel(session: session, storageAccess: storage, history: FolioLibraryHistory(defaults: fixture.defaults),
    nearbyEnabled: false, migrateLegacyStorage: false)
  let repository = FolioDraftRepository(url: fixture.base.appendingPathComponent("private-drafts.json"))
  _ = try await session.open(fixture.location, preserveNavigation: false, willReplace: {}, didLoad: { _ in
    try model.draftStore.bind(repository)
  })
  defer { model.draftStore.cancelPendingWrite() }
  let source = fixture.root.appendingPathComponent("_workspace.md")
  let originalSource = try Data(contentsOf: source)
  model.draftStore.load(.init(path: "notes/a.md", text: "Original", original: "Original", revision: "revision"), id: "a")
  let editorGeneration = model.editorGeneration

  session.markSuspended()
  #expect(!model.hasOpenWorkspace)
  #expect(model.canAcceptPrivateEdits)
  model.editText("Input before checkpoint", documentID: "a", generation: editorGeneration)
  model.draftStore.stopPrivateInput()
  try model.draftStore.checkpoint()
  #expect(!model.canAcceptPrivateEdits)
  model.editText("Input after checkpoint", documentID: "a", generation: model.editorGeneration)
  #expect(try repository.load()["a"]?.text == "Input before checkpoint")
  #expect(model.drafts["a"]?.text == "Input before checkpoint")
  #expect(try Data(contentsOf: source) == originalSource)
  await session.close {}
}

@MainActor private func openSession(_ session: FolioWorkspaceSession, fixture: SessionFixture) async throws -> Int? {
  try await session.open(fixture.location, preserveNavigation: false, willReplace: {}, didLoad: { _ in })
}

private struct SessionFixture {
  let base: URL
  let root: URL
  let state: URL
  let location: WikiWorkspaceLocation
  let workspaceID: UUID
  let defaults: UserDefaults
  private let defaultsName: String

  init() throws {
    defaultsName = "FolioWorkspaceSessionTests-" + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: defaultsName) else { throw WikiError.unavailable("Could not create isolated test defaults.") }
    self.defaults = defaults
    base = FileManager.default.temporaryDirectory.appending(path: "FolioSession-" + UUID().uuidString, directoryHint: .isDirectory)
    root = base.appending(path: "Source", directoryHint: .isDirectory)
    state = base.appending(path: "State", directoryHint: .isDirectory)
    workspaceID = UUID()
    try WikiWorkspace.create(at: root, name: "Session regression", workspaceID: workspaceID)
    location = .externalMac(bookmark: try WikiWorkspaceAccess.bookmark(for: root))
  }

  func cleanup() {
    defaults.removePersistentDomain(forName: defaultsName)
    try? FileManager.default.removeItem(at: base)
  }
}
#endif
