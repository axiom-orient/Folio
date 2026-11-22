import Foundation
import FolioKnowledge
import FolioKnowledgeApple

extension WikiAppModel {
  public func importWorkspace(_ url: URL) async {
    guard hasStorageAccess else { return }
    guard preserveDraftsForWorkspaceChange() else { return }
    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do { await open(try await session.access.importLocal(from: url)) }
    catch { message = error.localizedDescription }
  }

  /// An explicit Files/share import uses the same source owners as direct edits.
  @discardableResult public func importSource(_ url: URL, in window: WikiWindowState) async -> Bool {
    await importSource(url, in: window, expectedTarget: nil)
  }

  /// The workspace picker may create a new local library, never import into
  /// whichever library happens to be open when that picker returns.
  @discardableResult func importWorkspaceSource(_ url: URL, in window: WikiWindowState) async -> Bool {
    await importSource(url, in: window, expectedTarget: nil, workspaceOnly: true)
  }

  /// A document picker carries the exact location it displayed before opening.
  @discardableResult func importSource(_ url: URL, in window: WikiWindowState,
    expectedTarget: FolioReceivedTarget?, workspaceOnly: Bool = false, sourceIdentity: URL? = nil
  ) async -> Bool {
    guard hasStorageAccess, protectedDataAvailable, !isBusy else {
      message = "자료함이 준비되면 파일을 다시 선택해 주세요."; return false
    }
    guard expectedTarget == nil || (hasOpenWorkspace && receivedFileTarget == expectedTarget) else {
      message = "자료함이 바뀌었습니다. 추가할 자료함에서 파일을 다시 선택하세요."; return false
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let importGeneration = workspaceGeneration
    do {
      // Result observation must still work when a selected file or the last
      // received-file staging copy is no longer available.
      let isPendingDocument = !workspaceOnly && (hasPendingMarkdownImport(sourceIdentity ?? url)
        || fileIntake.hasPendingCapture(sourceIdentity ?? url))
      if !isPendingDocument, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        guard expectedTarget == nil else { message = "선택한 파일은 문서가 아닙니다."; return false }
        let previous = session.location
        await importWorkspace(url); return hasOpenWorkspace && session.location != previous
      }
      if url.pathExtension.lowercased() == "zip" {
        guard expectedTarget == nil else { message = "선택한 파일은 문서가 아닙니다."; return false }
        guard preserveDraftsForWorkspaceChange() else { return false }
        let generation = workspaceGeneration
        isBusy = true
        defer { if generation == workspaceGeneration { isBusy = false } }
        let imported = try await session.access.importArchive(from: url)
        guard generation == workspaceGeneration, protectedDataAvailable else { return false }
        isBusy = false
        await open(imported)
        if case .localManaged(let id) = imported { return hasOpenWorkspace && snapshot?.workspace.id == id }
        return false
      }
      guard !workspaceOnly else {
        message = "자료함 폴더 또는 ZIP 파일을 다시 선택해 주세요."
        return false
      }
      guard hasOpenWorkspace, let workspace, let recoveryScope = draftStore.recoveryScopeURL else {
        message = "자료를 넣을 자료함을 먼저 열거나 만들어 주세요."; return false
      }
      let generation = workspaceGeneration
      isBusy = true
      defer { if generation == workspaceGeneration { isBusy = false } }
      if url.pathExtension.lowercased() == "pdf" {
        return await fileIntake.capture(url, expectedTarget: expectedTarget, sourceIdentity: sourceIdentity,
          didLink: attachmentPresentation(in: window))
      }
      let key = FolioMarkdownImports.Key(source: sourceIdentity ?? url, workspace: workspace, recoveryScope: recoveryScope)
      let submission = try await submitMarkdownImport(url, key: key, workspace: workspace,
        generation: generation, expectedTarget: expectedTarget)
      guard let submission else { return false }
      guard generation == workspaceGeneration, hasOpenWorkspace,
        expectedTarget == nil || receivedFileTarget == expectedTarget else {
        message = "문서는 원래 자료함에 추가됐습니다. 자료함이 바뀌어 문서를 선택하지 않았습니다."
        return false
      }
      await refresh()
      guard generation == workspaceGeneration, hasOpenWorkspace,
        expectedTarget == nil || receivedFileTarget == expectedTarget else {
        message = "문서는 원래 자료함에 추가됐습니다. 자료함이 바뀌어 문서를 선택하지 않았습니다."
        return false
      }
      guard snapshot?.documents.contains(where: { $0.id == submission.id && $0.relativePath == submission.path }) == true else {
        message = "문서는 추가됐지만 목록에서 확인하지 못했습니다. 같은 요청의 결과를 다시 확인해 주세요."
        return false
      }
      window.query = ""; window.selectedSectionID = nil
      window.selectedDocumentID = submission.id; window.isEditing = false
      await loadSelection(window)
      guard generation == workspaceGeneration, hasOpenWorkspace,
        expectedTarget == nil || receivedFileTarget == expectedTarget else {
        message = "문서는 원래 자료함에 추가됐습니다. 자료함이 바뀌어 문서를 선택하지 않았습니다."
        return false
      }
      markdownImports.finish(submission, for: key)
      message = nil
      return true
    } catch {
      if importGeneration == workspaceGeneration {
        if let sourceError = error as? WikiError, case .invalidSource(let reason) = sourceError,
          reason == "Edit introduces an invalid ID, type, or relation." {
          message = "문서를 추가할 수 없습니다. 이미 추가한 문서인지 확인하거나 원문의 ID·유형·연결을 확인하세요."
        } else { message = "가져오기를 완료하지 못했습니다. " + error.localizedDescription }
      }
    }
    return false
  }

  func hasPendingMarkdownImport(_ url: URL) -> Bool {
    guard let workspace, let recoveryScope = draftStore.recoveryScopeURL else { return false }
    return markdownImports.submission(for: .init(source: url, workspace: workspace, recoveryScope: recoveryScope)) != nil
  }

  private func submitMarkdownImport(_ url: URL, key: FolioMarkdownImports.Key, workspace: WikiWorkspace,
    generation: Int, expectedTarget: FolioReceivedTarget?
  ) async throws -> FolioSubmittedDocument? {
    if let previous = markdownImports.submission(for: key) {
      switch await previous.observe(in: workspace) {
      case .committed: return previous.confirmed()
      case .notObserved:
        markdownImports.finish(previous, for: key)
        if generation == workspaceGeneration {
          message = "이전 가져오기가 반영되지 않은 것을 확인했습니다. ‘추가’를 눌러 다시 가져오세요."
        }
        return nil
      case .uncertain(let diagnostic):
        if generation == workspaceGeneration {
          message = "가져오기 결과를 확정하지 못했습니다. 다시 추가하지 않고 같은 요청의 결과를 확인합니다. " + diagnostic
        }
        return nil
      }
    }
    let plan = try await workspace.prepareMarkdownImport(fromSelectedURL: url, operationID: UUID())
    guard generation == workspaceGeneration, hasOpenWorkspace,
      expectedTarget == nil || receivedFileTarget == expectedTarget else {
      message = "자료함이 바뀌었습니다. 추가할 자료함에서 파일을 다시 선택하세요."
      return nil
    }
    let document = try WikiMarkdownParser.document(relativePath: plan.relativePath, bytes: plan.replacementBytes)
    let submitted = FolioSubmittedDocument(id: document.id, plan: plan, sourceRoot: workspace.root)
    markdownImports.retain(submitted, for: key)
    do {
      _ = try await workspace.execute(plan)
      let confirmed = submitted.confirmed()
      markdownImports.retain(confirmed, for: key)
      return confirmed
    } catch {
      switch await submitted.observe(in: workspace) {
      case .committed:
        let confirmed = submitted.confirmed()
        markdownImports.retain(confirmed, for: key)
        return confirmed
      case .notObserved:
        markdownImports.finish(submitted, for: key)
        throw error
      case .uncertain(let diagnostic):
        if generation == workspaceGeneration {
          message = "가져오기 결과를 확정하지 못했습니다. 원본은 유지했고 같은 요청의 결과를 다시 확인합니다. " + diagnostic
        }
        return nil
      }
    }
  }
}
