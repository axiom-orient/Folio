import Foundation
import FolioKnowledge
import FolioKnowledgeApple

extension WikiAppModel {
  struct MergeSelection: Identifiable {
    let id = UUID()
    let documentID: String
    let title: String
    let path: String
    let expectedDraft: FolioDraft
    let receivedSource: String
    let plan: FolioDocumentMerge.Plan
    let sourceRoot: URL
    let workspaceID: UUID
    let windowID: UUID
    let workspaceGeneration: Int
    let editorGeneration: Int
    let sourceExpectation: FolioDraftStore.ReviewedSource
  }

  /// The existing Save intent may combine independent changes once. The source
  /// owner still admits the resulting write against the newly observed revision.
  func combineReceivedChanges(draft: Draft, document: WikiDocument, window: WikiWindowState,
    generation: Int, expectation: FolioDraftStore.ReviewedSource
  ) async {
    guard let workspace, hasOpenWorkspace else { return }
    let editing = editorGeneration
    do {
      let bytes = try await workspace.source(relativePath: draft.path)
      guard generation == workspaceGeneration, editing == editorGeneration, hasOpenWorkspace,
        window.selectedDocumentID == document.id, draftMatches(draft, id: document.id) else { return }
      guard SourceDigest.sha256(bytes) == expectation.revision else { throw WikiError.changedSource }
      guard bytes.count <= 256 * 1024, let received = String(data: bytes, encoding: .utf8),
        SourceDigest.sha256(Data(draft.original.utf8)) == draft.revision,
        let receivedDocument = try? WikiMarkdownParser.document(relativePath: draft.path, bytes: bytes),
        receivedDocument.id == document.id else {
        message = "문서가 달라져 저장하지 않았어요. 편집한 내용은 이 기기에 남아 있습니다."
        return
      }
      guard let plan = FolioDocumentMerge.plan(base: draft.original, edited: draft.text, received: received) else {
        // Unusual metadata repairs retain the explicit advanced repair path.
        // They never gain authority through a guessed merge.
        await showDraftRecovery(id: document.id)
        return
      }
      if let merged = plan.automaticallyMergedSource {
        message = nil
        if merged.utf8.elementsEqual(received.utf8) {
          // Rebasing to a clean draft would drop its recovery copy before the
          // source CAS and receipt, even if the source changes again.
          try await commitDocumentDraft(draft, id: document.id, in: window, workspace: workspace, generation: generation,
            expectation: expectation, alreadyPresentSource: received)
        } else {
          guard try draftStore.rebase(id: document.id, expected: draft, receivedSource: received, mergedSource: merged),
            let rebased = drafts[document.id] else { return }
          try await commitDocumentDraft(rebased, id: document.id, in: window, workspace: workspace, generation: generation,
            expectation: expectation)
        }
      } else {
        mergeSelection = MergeSelection(documentID: document.id, title: document.title, path: draft.path,
          expectedDraft: draft, receivedSource: received, plan: plan, sourceRoot: workspace.root,
          workspaceID: workspace.workspaceID, windowID: window.id, workspaceGeneration: generation,
          editorGeneration: editing, sourceExpectation: expectation)
        message = nil
      }
    } catch {
      if generation == workspaceGeneration {
        reportDocumentSaveFailure(error)
        if (error as? WikiError) == .changedSource { session.requestRefresh() }
      }
    }
  }

  func saveMergedSelection(_ selection: MergeSelection, choices: [Int: FolioDocumentMerge.Choice]) async {
    guard let workspace, let window = windows[selection.windowID], hasOpenWorkspace,
      !documentLibrary.phase.isApplying, window.selectedDocumentID == selection.documentID,
      selection.workspaceGeneration == workspaceGeneration, selection.editorGeneration == editorGeneration,
      selection.sourceRoot == workspace.root, selection.workspaceID == workspace.workspaceID,
      mergeSelection?.id == selection.id, draftMatches(selection.expectedDraft, id: selection.documentID),
      let source = selection.plan.resolvedSource(choices: choices),
      draftStore.beginSaving(id: selection.documentID) else { return }
    defer { draftStore.endSaving(id: selection.documentID) }
    do {
      message = nil
      if source.utf8.elementsEqual(selection.receivedSource.utf8) {
        try await commitDocumentDraft(selection.expectedDraft, id: selection.documentID, in: window, workspace: workspace,
          generation: selection.workspaceGeneration, expectation: selection.sourceExpectation,
          alreadyPresentSource: selection.receivedSource)
      } else {
        guard try draftStore.rebase(id: selection.documentID, expected: selection.expectedDraft,
          receivedSource: selection.receivedSource, mergedSource: source),
          let rebased = drafts[selection.documentID] else { return }
        try await commitDocumentDraft(rebased, id: selection.documentID, in: window, workspace: workspace,
          generation: selection.workspaceGeneration, expectation: selection.sourceExpectation)
      }
      if mergeSelection?.id == selection.id { mergeSelection = nil }
    } catch {
      guard selection.workspaceGeneration == workspaceGeneration else { return }
      // The chosen content is already retained in the shared draft. A newer
      // source requires another Save, never an unbounded automatic replay.
      if mergeSelection?.id == selection.id { mergeSelection = nil }
      reportDocumentSaveFailure(error)
      if (error as? WikiError) == .changedSource { session.requestRefresh() }
    }
  }

  private func draftMatches(_ expected: Draft, id: String) -> Bool {
    guard let current = drafts[id] else { return false }
    return current.path == expected.path && current.revision == expected.revision
      && current.text.utf8.elementsEqual(expected.text.utf8)
      && current.original.utf8.elementsEqual(expected.original.utf8)
  }

  func reportDocumentSaveFailure(_ error: any Error) {
    if (error as? WikiError) == .changedSource {
      message = "확인한 원문이 다시 바뀌어 저장하지 않았습니다. 편집 내용은 보존했습니다. 문서 정보에서 원문 버전을 다시 확인해 주세요."
    } else if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
      message = "저장 공간이 부족합니다. 공간을 확보한 뒤 다시 저장해 주세요."
    } else {
      message = "저장하지 못했어요. 편집한 내용은 이 기기에 남아 있습니다. 잠시 후 다시 저장해 주세요."
    }
  }
}
