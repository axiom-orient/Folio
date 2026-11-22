import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import Testing
@testable import FolioUI

@Suite struct DocumentResumeTests {
  private let first = WikiWorkspaceLocation.localManaged(workspaceID: UUID(uuidString: "A3C07691-9867-4238-85EC-1C49D5164815")!)
  private let second = WikiWorkspaceLocation.localManaged(workspaceID: UUID(uuidString: "EC7B3283-6766-499F-B142-3AEFB56A739F")!)

  @Test(arguments: [false, true])
  func sameWorkspaceResumePreservesCapturedFormsAndDocumentContext(hasPendingLocation: Bool) throws {
    let opening = FolioWorkspaceOpening.resolve(intent: .lifecycleResume, requested: first, current: first,
      pending: hasPendingLocation ? first : nil, hasSnapshot: true, isSuspended: true)
    #expect(opening == .resume)
    #expect(opening.preservesNavigation)
    let root = URL(fileURLWithPath: "/fixture/source")
    let captured = FolioDocumentContext(root: root, generation: 4)
    let resumed = FolioDocumentContext(root: root, generation: opening.nextDocumentGeneration(after: 4))
    #expect(resumed == captured)
    var checkpointed = false
    try opening.checkpoint(hasMetadataEditor: true, isSaving: false, isLinking: false,
      isApplyingDocumentChanges: false) { checkpointed = true }
    #expect(checkpointed)
  }

  @Test func userReopenStillRequiresFinishingTheMetadataForm() {
    let opening = FolioWorkspaceOpening.resolve(intent: .user, requested: first, current: first,
      pending: first, hasSnapshot: true, isSuspended: true)
    #expect(opening == .reopen)
    #expect(opening.preservesNavigation)
    var checkpointed = false
    #expect(throws: FolioWorkspaceOpening.AdmissionError.metadataEditing) {
      try opening.checkpoint(hasMetadataEditor: true, isSaving: false, isLinking: false,
        isApplyingDocumentChanges: false) { checkpointed = true }
    }
    #expect(!checkpointed)
  }

  @Test func resumeCannotAuthorizeAnotherWorkspaceOrAnUnrelatedPendingOpen() {
    let different = FolioWorkspaceOpening.resolve(intent: .lifecycleResume, requested: second, current: first,
      pending: second, hasSnapshot: true, isSuspended: true)
    let unrelatedPending = FolioWorkspaceOpening.resolve(intent: .lifecycleResume, requested: first, current: first,
      pending: second, hasSnapshot: true, isSuspended: true)
    let active = FolioWorkspaceOpening.resolve(intent: .lifecycleResume, requested: first, current: first,
      pending: nil, hasSnapshot: true, isSuspended: false)
    let noSnapshot = FolioWorkspaceOpening.resolve(intent: .lifecycleResume, requested: first, current: first,
      pending: nil, hasSnapshot: false, isSuspended: true)
    #expect(different == .replace)
    #expect(unrelatedPending == .reopen)
    #expect(active == .reopen)
    #expect(noSnapshot == .replace)
    for opening in [different, unrelatedPending, active, noSnapshot] {
      #expect(throws: FolioWorkspaceOpening.AdmissionError.metadataEditing) {
        try opening.checkpoint(hasMetadataEditor: true, isSaving: false, isLinking: false,
          isApplyingDocumentChanges: false) {}
      }
    }
  }

  @Test func switchingAwayAndBackInvalidatesTheEarlierDocumentContext() {
    let initial = FolioWorkspaceOpening.resolve(intent: .user, requested: first, current: nil,
      pending: nil, hasSnapshot: false, isSuspended: false)
    let firstGeneration = initial.nextDocumentGeneration(after: 0)
    let away = FolioWorkspaceOpening.resolve(intent: .user, requested: second, current: first,
      pending: nil, hasSnapshot: true, isSuspended: false)
    let awayGeneration = away.nextDocumentGeneration(after: firstGeneration)
    let back = FolioWorkspaceOpening.resolve(intent: .user, requested: first, current: second,
      pending: nil, hasSnapshot: true, isSuspended: false)
    let returnedGeneration = back.nextDocumentGeneration(after: awayGeneration)
    #expect(firstGeneration == 1)
    #expect(awayGeneration == 2)
    #expect(returnedGeneration == 3)
    let root = URL(fileURLWithPath: "/fixture/source")
    #expect(FolioDocumentContext(root: root, generation: firstGeneration)
      != FolioDocumentContext(root: root, generation: returnedGeneration))
  }

  @MainActor @Test func failedDirtyDraftCheckpointRejectsResumeAndPreservesTheDraft() {
    let store = FolioDraftStore()
    store.load(FolioDraft(path: "notes/document.md", text: "Unsaved", original: "Saved", revision: "original-revision"), id: "document")
    let opening = FolioWorkspaceOpening.resume
    #expect(throws: WikiError.self) {
      try opening.checkpoint(hasMetadataEditor: true, isSaving: false, isLinking: false,
        isApplyingDocumentChanges: false) { try store.checkpoint() }
    }
    #expect(store.drafts["document"]?.text == "Unsaved")
    #expect(store.drafts["document"]?.revision == "original-revision")
    #expect(store.drafts["document"]?.isDirty == true)
  }

  @Test(arguments: [BusyOperation.saving, .linking, .documentMutation])
  func lifecycleResumeCannotBypassAdmittedSourceOperations(operation: BusyOperation) {
    var checkpointed = false
    let expected: FolioWorkspaceOpening.AdmissionError = operation == .documentMutation ? .documentMutation : .sourceWrite
    #expect(throws: expected) {
      try FolioWorkspaceOpening.resume.checkpoint(hasMetadataEditor: true, isSaving: operation == .saving,
        isLinking: operation == .linking, isApplyingDocumentChanges: operation == .documentMutation) { checkpointed = true }
    }
    #expect(!checkpointed)
  }

  @MainActor @Test func documentDrainWaitsForTheEffectConsumerAndReleasesEveryWaiterOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolioResumeTests-" + UUID().uuidString)
    let source = root.appendingPathComponent("Source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try WikiWorkspace.create(at: source, name: "Resume fixture")
    let workspace = try WikiWorkspace(root: source, localStateDirectory: root.appendingPathComponent("State"))
    let library = FolioDocumentLibrary()
    let context = FolioDocumentContext(root: source, generation: 1)
    _ = try await library.apply(.createFolder(path: "notes/created"), expectedRevision: nil,
      workspace: workspace, context: context)
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("notes/created").path))
    #expect(library.phase.isApplying)
    library.reset()
    #expect(library.phase.isApplying)
    #expect(library.context == context)

    var entered = 0
    var completions = 0
    let firstDrain = Task { entered += 1; await library.drain(); completions += 1 }
    let secondDrain = Task { entered += 1; await library.drain(); completions += 1 }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while entered < 2, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(entered == 2)
    #expect(completions == 0)
    library.finish()
    await firstDrain.value; await secondDrain.value
    #expect(completions == 2)
    #expect(library.phase == .ready)
    library.finish()
    await library.drain()
    #expect(completions == 2)
    await workspace.close()
  }

  enum BusyOperation: Sendable { case saving, linking, documentMutation }
}
