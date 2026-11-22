import Foundation
import FolioKnowledge
import FolioKnowledgeApple

extension WikiAppModel {
  var documentContext: FolioDocumentContext? {
    guard hasOpenWorkspace, let root = openedSourceRoot else { return nil }
    return .init(root: root, generation: documentContextGeneration)
  }

  func reloadDocumentLibrary(context: FolioDocumentContext) async {
    guard context == documentContext, let workspace else { return }
    // Passive catalog readiness belongs to browsing; it must not cover an unrelated reader.
    // The catalog retains a context-bound issue and clears only that issue after a successful reload.
    try? await documentLibrary.reload(workspace: workspace, context: context)
  }

  func loadVisibleTrash(context: FolioDocumentContext) async {
    guard context == documentContext, let workspace else { return }
    for _ in 0..<15 {
      guard !Task.isCancelled, context == documentContext,
        documentLibrary.trash.contains(where: { $0.state == .downloading }) else { return }
      do {
        try await Task.sleep(for: .seconds(2))
        try await documentLibrary.refreshTrash(workspace: workspace, context: context)
      } catch { return }
    }
  }

  func requestTrashDownload(id: UUID, context: FolioDocumentContext) async {
    guard context == documentContext, let workspace else { return }
    do { try await workspace.requestTrashDownload(id: id) }
    catch { message = "아직 문서를 가져오지 못했어요. 잠시 후 다시 불러와 주세요." }
  }

  @discardableResult
  func performFileAction(_ action: WikiFileAction, name: String, destination: String) async -> Bool {
    guard let workspace = admittedDocumentWorkspace(context: action.context) else { return false }
    return await performDocumentMutation(context: action.context, workspace: workspace, prepare: {
      let command = try action.command(name: name, destination: destination)
      if case .createFolder = action.kind {} else {
        guard action.revision != nil else { throw WikiError.changedSource }
      }
      let removedIDs: Set<String>
      if case .trash = action.kind {
        removedIDs = Set((snapshot?.documents ?? []).filter {
          $0.relativePath == action.path || $0.relativePath.hasPrefix(action.path + "/")
        }.map(\.id))
      } else { removedIDs = [] }
      return (command, removedIDs)
    }, apply: { input in
      let (command, removedIDs) = input
      let change = try await documentLibrary.apply(command, expectedRevision: action.revision,
        workspace: workspace, context: action.context)
      let replacements = Dictionary(change.documentMoves.map { ($0.oldID, $0.newID) }, uniquingKeysWith: { _, latest in latest })
      return DocumentMutationResult(replacements: replacements, removedIDs: removedIDs, diagnostic: change.diagnostic)
    })
  }

  struct DocumentMutationResult {
    let replacements: [String: String]
    let removedIDs: Set<String>
    let diagnostic: String?
  }

  /// The receipt is retained even if refreshing the application projection fails.
  func performDocumentMutation<Input>(context: FolioDocumentContext, workspace: WikiWorkspace,
    prepare: () throws -> Input, apply: (Input) async throws -> DocumentMutationResult
  ) async -> Bool {
    let generation = workspaceGeneration
    var committed = false
    do {
      try draftStore.checkpoint()
      let input = try prepare()
      beginDocumentMutation()
      defer { documentLibrary.finish() }
      let result = try await apply(input)
      committed = true
      guard generation == workspaceGeneration, context == documentContext else { return true }
      try await finishDocumentMutation(context: context, generation: generation, workspace: workspace,
        replacements: result.replacements, removedIDs: result.removedIDs)
      guard generation == workspaceGeneration, context == documentContext else { return true }
      message = result.diagnostic
      return true
    } catch {
      await failedDocumentMutation(error, context: context, generation: generation, committed: committed)
      return committed
    }
  }

  func admittedDocumentWorkspace(context: FolioDocumentContext, metadataSelectionID: UUID? = nil) -> WikiWorkspace? {
    guard context == documentContext, let workspace else {
      message = "자료함이 바뀌었습니다. 현재 대상에서 작업을 다시 선택해 주세요."; return nil
    }
    guard !isBusy, !documentLibrary.phase.isBusy, savingDocuments.isEmpty,
      linkingAttachments.isEmpty, pendingAttachments.isEmpty else {
      message = "현재 저장·첨부 연결이 끝나면 다시 시도해 주세요."; return nil
    }
    guard !drafts.values.contains(where: \.isDirty) else {
      message = "저장하지 않은 초안이 있습니다. 편집을 저장하거나 초안을 버린 뒤 문서를 정리해 주세요."; return nil
    }
    guard !windows.values.contains(where: \.isEditing), repairSelection == nil, conflictSelection == nil, mergeSelection == nil else {
      message = "열린 편집·복구·버전 비교를 마친 뒤 문서를 정리해 주세요."; return nil
    }
    guard !windows.values.contains(where: { $0.metadataSelection != nil && $0.metadataSelection?.id != metadataSelectionID }) else {
      message = "다른 창의 제목·태그 편집을 마친 뒤 다시 시도해 주세요."; return nil
    }
    return workspace
  }

  func beginDocumentMutation() {
    draftStore.invalidateEditing()
    for window in windows.values { _ = window.beginNavigation(); window.invalidateSearch() }
    conflictSelection = nil; repairSelection = nil; mergeSelection = nil; previewURL = nil
  }

  func finishDocumentMutation(context: FolioDocumentContext, generation: Int, workspace: WikiWorkspace,
    replacements: [String: String], removedIDs: Set<String>
  ) async throws {
    guard generation == workspaceGeneration, context == documentContext else { return }
    draftStore.invalidateEditing(); draftStore.clear()
    for window in windows.values { window.applyFileChanges(replacements: replacements, removedIDs: removedIDs) }
    let refreshed = try await session.refreshSnapshot()
    guard generation == workspaceGeneration, context == documentContext, let refreshed else { return }
    for window in windows.values {
      window.reconcileDocuments(refreshed.documents,
        unavailableDocumentIDs: Set(refreshed.staleDocuments.map(\.id)), preservingFileChanges: true)
    }
    reconcileRecentFiles(replacements: replacements, removedIDs: removedIDs)
    try await documentLibrary.reload(workspace: workspace, context: context, afterMutation: true)
  }

  func failedDocumentMutation(_ error: any Error, context: FolioDocumentContext, generation: Int, committed: Bool) async {
    guard generation == workspaceGeneration, context == documentContext else { return }
    message = committed ? "변경은 원문에 반영됐습니다. 목록을 다시 확인해 주세요. " + error.localizedDescription : error.localizedDescription
    await refresh()
    guard generation == workspaceGeneration, context == documentContext else { return }
    await reloadDocumentLibrary(context: context)
  }


}
