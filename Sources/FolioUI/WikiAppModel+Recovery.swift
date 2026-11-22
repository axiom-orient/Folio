import Foundation
import FolioKnowledge
import FolioKnowledgeApple

extension WikiAppModel {
  struct ConflictSelection: Identifiable {
    let id = UUID(); let path: String; let versions: [WikiConflictVersion]
    let sourceRoot: URL; let workspaceID: UUID
  }
  typealias RepairSelection = FolioSourceRepair

  func showDraftRecovery(id: String) async {
    guard !documentLibrary.phase.isApplying, hasOpenWorkspace, let draft = drafts[id], let workspace else { return }
    let generation = workspaceGeneration
    let editor = editorGeneration
    do {
      let observedBytes: Data?
      do { observedBytes = try await workspace.source(relativePath: draft.path) }
      catch is CancellationError { return }
      catch {
        // Opening a private draft must not depend on a remote source arriving.
        // Cloud absence/unavailability is read-only recovery, never creation authority.
        guard isCloudWorkspace || isMissingRecoverySource(error) else { throw error }
        observedBytes = nil
      }
      guard editor == editorGeneration, generation == workspaceGeneration, hasOpenWorkspace,
        let current = drafts[id], current.path == draft.path else { return }
      let selection = try RepairSelection.recoveringDraft(id: id, draft: current, observedBytes: observedBytes,
        sourceRoot: workspace.root, workspaceID: workspace.workspaceID, isCloudWorkspace: isCloudWorkspace,
        documentGeneration: documentContextGeneration)
      repairSelection = selection
      if repairSelection?.id == selection.id { message = nil }
    } catch { if generation == workspaceGeneration { message = error.localizedDescription } }
  }

  func removeDraft(id: String) {
    guard hasOpenWorkspace else { return }
    draftStore.remove(id: id); persistDrafts()
  }

  func showConflict(path: String) async {
    guard !documentLibrary.phase.isApplying, hasOpenWorkspace, let workspace else { return }
    let generation = workspaceGeneration
    let editor = editorGeneration
    do {
      let versions = try await workspace.conflictVersions(relativePath: path)
      guard editor == editorGeneration, generation == workspaceGeneration else { return }
      conflictSelection = ConflictSelection(path: path, versions: versions, sourceRoot: workspace.root, workspaceID: workspace.workspaceID)
    }
    catch { message = error.localizedDescription }
  }

  func resolveConflict(_ selection: ConflictSelection, version: WikiConflictVersion) async {
    guard !isBusy, hasOpenWorkspace, let workspace, let current = selection.versions.first else { return }
    let generation = workspaceGeneration
    isBusy = true
    defer { if generation == workspaceGeneration { isBusy = false } }
    do {
      guard selection.sourceRoot == workspace.root, selection.workspaceID == workspace.workspaceID else { throw WikiError.changedSource }
      let receipt = try await workspace.resolveConflict(relativePath: selection.path,
        expectedCurrentRevision: current.id, chosenRevision: version.id)
      guard generation == workspaceGeneration else { return }
      conflictSelection = nil; message = receipt.diagnostic
      await refresh()
    } catch { message = error.localizedDescription }
  }

  func showOntology() async {
    guard !documentLibrary.phase.isApplying, hasOpenWorkspace, let workspace else { return }
    let generation = workspaceGeneration
    let editor = editorGeneration
    do {
      let bytes = try await workspace.source(relativePath: "_ontology.md")
      guard editor == editorGeneration, generation == workspaceGeneration else { return }
      repairSelection = RepairSelection(path: "_ontology.md", revision: SourceDigest.sha256(bytes),
        text: String(decoding: bytes, as: UTF8.self), sourceRoot: workspace.root, workspaceID: workspace.workspaceID,
        documentGeneration: documentContextGeneration)
    } catch {
      guard editor == editorGeneration, generation == workspaceGeneration else { return }
      if isMissingRecoverySource(error) {
        if snapshot?.ontologyUnavailable == true || snapshot?.diagnostics.contains(where: { $0.path == "_ontology.md" }) == true {
          message = "관계 규칙 원문을 먼저 다운로드하거나 버전을 확인해 주세요. 미수신 원문을 새 규칙으로 덮어쓰지 않습니다."
          return
        }
        if isCloudWorkspace, cloudLibrary.isGathering || cloudLibrary.problem != nil
          || cloudStatus?.gatheringComplete != true || (cloudStatus?.pendingDownloads ?? 1) > 0 {
          message = "iCloud의 관계 규칙 수신 여부를 확인 중입니다. 원문이 준비된 뒤 다시 열어 주세요."
          return
        }
        repairSelection = RepairSelection(path: "_ontology.md", revision: nil,
          text: "---\nkind: ontology\ntypes: {}\nrelations: {}\n---\n\n# 관계 규칙\n",
          sourceRoot: workspace.root, workspaceID: workspace.workspaceID, documentGeneration: documentContextGeneration)
      } else { message = error.localizedDescription }
    }
  }

  func showSourceRepair(path: String) async {
    guard !documentLibrary.phase.isApplying, hasOpenWorkspace, let workspace, path.hasPrefix("notes/") || path == "_ontology.md" else { return }
    let generation = workspaceGeneration
    let editor = editorGeneration
    do {
      let bytes = try await workspace.source(relativePath: path)
      guard editor == editorGeneration, generation == workspaceGeneration else { return }
      guard bytes.count <= 256 * 1024 else { throw WikiError.unavailable("문서가 256 KiB를 넘습니다. 원문 폴더에서 외부 편집기로 열어 주세요.") }
      guard let text = String(data: bytes, encoding: .utf8) else { throw WikiError.invalidSource("UTF-8 원문이 필요합니다.") }
      repairSelection = RepairSelection(path: path, revision: SourceDigest.sha256(bytes), text: text,
        sourceRoot: workspace.root, workspaceID: workspace.workspaceID, documentGeneration: documentContextGeneration)
    } catch { message = error.localizedDescription }
  }

  func requestDownload(path: String) async {
    guard hasOpenWorkspace, let workspace else { return }
    do { try await workspace.requestSourceDownload(relativePath: path); message = "다운로드를 요청했습니다. 원문이 도착하면 다시 읽습니다." }
    catch { message = error.localizedDescription }
  }

  func repairSource(_ selection: RepairSelection, text: String) async {
    guard !isBusy, hasOpenWorkspace, selection.documentGeneration == documentContextGeneration, let workspace else { return }
    let generation = workspaceGeneration
    isBusy = true
    defer { if generation == workspaceGeneration { isBusy = false } }
    do {
      let plan = try await selection.prepareSave(replacement: text, in: workspace)
      guard generation == workspaceGeneration, hasOpenWorkspace,
        selection.sourceRoot == workspace.root, selection.workspaceID == workspace.workspaceID else { throw WikiError.changedSource }
      let receipt = try await workspace.execute(plan)
      guard generation == workspaceGeneration, hasOpenWorkspace,
        selection.sourceRoot == workspace.root, selection.workspaceID == workspace.workspaceID else {
        if generation == workspaceGeneration {
          message = "원래 자료함의 저장 결과를 확인해 주세요. 편집 복구본은 보존했습니다."
        }
        return
      }
      if let id = selection.draftID {
        draftStore.completeSave(id: id, path: selection.path, submittedText: text, revision: receipt.sourceRevision)
        persistDrafts()
      }
      selection.completeSave(text, revision: receipt.sourceRevision)
      if !selection.hasUnsavedInput, repairSelection?.id == selection.id { repairSelection = nil }
      message = selection.hasUnsavedInput
        ? "제출한 원문은 저장했습니다. 그 뒤 입력한 내용은 아직 저장하지 않았습니다." : receipt.diagnostic
      await refresh()
    } catch {
      if generation == workspaceGeneration {
        message = (error as? WikiError) == .changedSource
          ? "원문이 바뀌어 저장하지 않았습니다. 편집 내용은 유지했습니다. 현재 원문을 다시 확인해 주세요."
          : error.localizedDescription
      }
    }
  }
}

private func isMissingRecoverySource(_ error: any Error) -> Bool {
  let cocoa = (error as? CocoaError)?.code
  return cocoa == .fileNoSuchFile || cocoa == .fileReadNoSuchFile || (error as? POSIXError)?.code == .ENOENT
}
