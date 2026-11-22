import Foundation
import FolioKnowledge
import FolioKnowledgeApple

extension WikiAppModel {
  typealias CreatedDocument = FolioSubmittedDocument
  func editText(_ text: String, documentID id: String, generation: Int) {
    guard !documentLibrary.phase.isApplying, canAcceptPrivateEdits, generation == editorGeneration else { return }
    draftStore.edit(text, id: id)
  }
  func discardDraft(_ window: WikiWindowState) {
    guard hasOpenWorkspace, let id = window.selectedDocumentID, drafts[id] != nil else { return }
    draftStore.discard(id: id)
    persistDrafts()
  }

  public func persistDrafts() {
    do { try draftStore.checkpoint() }
    catch { message = "편집 복구본을 보존하지 못했습니다: \(error.localizedDescription)" }
  }

  public func save(_ window: WikiWindowState) async {
    guard let context = documentContext, let document = session.document(id: window.selectedDocumentID) else { return }
    guard let expectation = captureSaveExpectation(for: document, context: context) else { return }
    await save(window, expectation: expectation)
  }

  func reviewSource(_ document: WikiDocument, in window: WikiWindowState, context: FolioDocumentContext) {
    guard hasOpenWorkspace, documentContext == context, window.selectedDocumentID == document.id else { return }
    draftStore.reviewSource(document, context: context, workspaceGeneration: workspaceGeneration)
  }

  func captureSaveExpectation(for document: WikiDocument, context: FolioDocumentContext) -> FolioDraftStore.ReviewedSource? {
    guard let expected = draftStore.sourceExpectation(for: document, context: context, workspaceGeneration: workspaceGeneration) else {
      message = "저장하기 전에 문서 정보에서 현재 원문 버전을 확인해 주세요. 편집 내용은 보존했습니다."
      session.requestRefresh()
      return nil
    }
    return expected
  }

  /// Both the direct write and a merge must use the source revision captured
  /// before the asynchronous Save begins, including an explicitly reviewed one.
  func save(_ window: WikiWindowState, expectation: FolioDraftStore.ReviewedSource) async {
    guard !documentLibrary.phase.isApplying, hasOpenWorkspace,
      let document = session.document(id: window.selectedDocumentID), let draft = drafts[document.id], let workspace,
      documentContext == expectation.context, document.id == expectation.documentID,
      draftStore.beginSaving(id: document.id) else { return }
    let generation = workspaceGeneration
    defer { draftStore.endSaving(id: document.id) }
    guard expectation.workspaceGeneration == generation,
      document.relativePath == expectation.path, draft.path == expectation.path,
      document.revision == expectation.revision else {
      reportDocumentSaveFailure(WikiError.changedSource)
      session.requestRefresh()
      return
    }
    do {
      if draft.revision == expectation.revision {
        try await commitDocumentDraft(draft, id: document.id, in: window, workspace: workspace, generation: generation,
          expectation: expectation)
      } else {
        await combineReceivedChanges(draft: draft, document: document, window: window, generation: generation,
          expectation: expectation)
      }
    } catch {
      guard generation == workspaceGeneration else { return }
      if case .conflict = error as? WikiError {
        await showConflict(path: draft.path)
      } else {
        reportDocumentSaveFailure(error)
        if (error as? WikiError) == .changedSource { session.requestRefresh() }
      }
    }
  }

  func commitDocumentDraft(_ draft: Draft, id: String, in window: WikiWindowState,
    workspace: WikiWorkspace, generation: Int, expectation: FolioDraftStore.ReviewedSource,
    alreadyPresentSource: String? = nil
  ) async throws {
      let plan = try await workspace.prepareRawSave(relativePath: draft.path,
        expectedRevision: alreadyPresentSource == nil ? draft.revision : expectation.revision,
        replacement: alreadyPresentSource ?? draft.text, operationID: UUID())
      guard generation == workspaceGeneration, hasOpenWorkspace, documentContext == expectation.context else {
        throw WikiError.changedSource
      }
      let receipt = try await workspace.execute(plan)
      guard generation == workspaceGeneration, hasOpenWorkspace, documentContext == expectation.context else {
        if generation == workspaceGeneration {
          message = "원래 자료함의 저장 결과를 확인해 주세요. 편집 복구본은 보존했습니다."
        }
        return
      }
      if alreadyPresentSource != nil { draftStore.completeAlreadyPresent(id: id, expected: draft) }
      else { draftStore.completeSave(id: id, path: draft.path, submittedText: draft.text, revision: receipt.sourceRevision) }
      draftStore.clearReviewedSource(matching: expectation)
      if drafts[id] == nil {
        if window.selectedDocumentID == id { window.isEditing = false }
      }
      persistDrafts()
      if let diagnostic = receipt.diagnostic { message = diagnostic }
      await refresh(); await loadSelection(window)
      guard generation == workspaceGeneration else { return }
      if window.selectedDocumentID == id,
        let saved = snapshot?.documents.first(where: { $0.relativePath == draft.path }), saved.id != id {
        window.selectedDocumentID = saved.id; await loadSelection(window)
      }
      if snapshot?.documents.contains(where: { $0.relativePath == draft.path }) != true {
        message = "원문을 저장했습니다. 메타데이터 오류를 고치면 검색과 연결을 다시 사용할 수 있습니다."
        await showSourceRepair(path: draft.path)
      }
  }

  public func createNote(in window: WikiWindowState, title: String = "새 문서", body: String = "") async {
    _ = await createDocument(in: window, title: title, body: body)
  }

  /// The ordinary compose action uses the existing writer and retains an
  /// unconfirmed attempt. A second tap observes that attempt; it never replays it.
  func quickCreateDocument(in window: WikiWindowState) async {
    guard hasOpenWorkspace, !isBusy, !window.isCreatingDocument else { return }
    let generation = workspaceGeneration
    let pending: CreatedDocument?
    if case let .awaitingResult(submitted) = window.quickCreation {
      guard submitted.sourceRoot == openedSourceRoot, submitted.workspaceID == snapshot?.workspace.id else {
        message = "원래 자료함에서 만들던 문서의 결과를 확인해 주세요."; return
      }
      pending = submitted
    } else { pending = nil }
    window.quickCreation = .working
    let created: CreatedDocument?
    if let pending {
      _ = await openCreatedDocument(pending, in: window)
      created = pending
    } else {
      created = await createDocument(in: window, title: "제목 없음", folder: window.filter.folder ?? "notes")
    }
    if let created, generation == workspaceGeneration, window.selectedDocumentID == created.id, window.isEditing {
      window.quickCreation = .idle
    } else if let created {
      window.quickCreation = .awaitingResult(created)
    } else { window.quickCreation = .idle }
  }

  func createDocument(in window: WikiWindowState, title rawTitle: String, body: String = "", folder: String = "notes",
    additionalFrontmatter: String = "", knowledgeEvidence: [WikiKnowledgeEvidence] = []
  ) async -> CreatedDocument? {
    guard let title = FolioInput.name(rawTitle) else { message = "문서 제목을 입력해 주세요."; return nil }
    guard hasOpenWorkspace, let workspace, !isBusy else { return nil }
    let id = UUID().uuidString.lowercased()
    let generation = workspaceGeneration
    isBusy = true
    defer { if generation == workspaceGeneration { isBusy = false } }
    let path = folder + "/" + id + ".md"
    let source = FolioInput.documentSource(id: id, title: title, body: body, additionalFrontmatter: additionalFrontmatter)
    var submitted: CreatedDocument?
    let created: CreatedDocument
    do {
      let plan = try await workspace.prepareEdit(relativePath: path, expectedRevision: nil, range: nil,
        replacement: source, operationID: UUID())
      guard generation == workspaceGeneration, hasOpenWorkspace else { return nil }
      let attempt = CreatedDocument(id: id, plan: plan, sourceRoot: workspace.root)
      submitted = attempt
      if knowledgeEvidence.isEmpty { _ = try await workspace.execute(plan) }
      else { _ = try await workspace.executeKnowledgeNote(plan, evidence: knowledgeEvidence) }
      created = attempt.confirmed()
    } catch {
      guard let submitted else {
        if generation == workspaceGeneration {
          message = !knowledgeEvidence.isEmpty && (error as? WikiError) == .changedSource
            ? "원문이나 자료함이 바뀌었습니다. 근거를 다시 찾은 뒤 저장해 주세요." : error.localizedDescription
        }
        return nil
      }
      switch await submitted.observe(in: workspace) {
      case .committed:
        created = submitted.confirmed()
        if generation == workspaceGeneration { message = "문서 원문은 만들어졌습니다. 저장 확인 중 오류: \(error.localizedDescription)" }
      case .notObserved:
        if generation == workspaceGeneration {
          message = !knowledgeEvidence.isEmpty && (error as? WikiError) == .changedSource
            ? "원문이나 자료함이 바뀌었습니다. 근거를 다시 찾은 뒤 저장해 주세요." : error.localizedDescription
        }
        return nil
      case .uncertain(let diagnostic):
        if generation == workspaceGeneration {
          message = "문서 생성 결과를 확정하지 못했습니다. 다시 만들지 않고 같은 요청의 결과를 확인합니다. \(diagnostic)"
        }
        return submitted
      }
    }
    guard generation == workspaceGeneration else { return created }
    await refresh()
    guard generation == workspaceGeneration else { return created }
    _ = await openCreatedDocument(created, in: window, editing: knowledgeEvidence.isEmpty)
    return created
  }

  func openCreatedDocument(_ created: CreatedDocument, in window: WikiWindowState, editing: Bool = true) async -> Bool {
    guard hasOpenWorkspace, let workspace, openedSourceRoot == created.sourceRoot,
      snapshot?.workspace.id == created.workspaceID else {
      message = "원래 자료함에서 문서 생성 결과를 다시 확인해 주세요."; return false
    }
    let generation = workspaceGeneration
    if !created.wasObserved {
      switch await created.observe(in: workspace) {
      case .committed: break
      case .notObserved, .uncertain:
        if generation == workspaceGeneration {
          message = "문서 생성 결과가 아직 확정되지 않았습니다. 원문과 저장 확인 정보를 확인해 주세요. 같은 요청을 다시 실행하지 않았습니다."
        }
        return false
      }
    }
    guard generation == workspaceGeneration, hasOpenWorkspace, openedSourceRoot == created.sourceRoot else { return false }
    if !created.wasObserved || snapshot?.documents.contains(where: { $0.id == created.id && $0.relativePath == created.path }) != true {
      await refresh()
    }
    guard generation == workspaceGeneration, hasOpenWorkspace, openedSourceRoot == created.sourceRoot,
      snapshot?.documents.contains(where: { $0.id == created.id && $0.relativePath == created.path }) == true else {
      if generation == workspaceGeneration { message = "생성한 문서를 열지 못했습니다. 원래 자료함에서 같은 문서를 다시 확인해 주세요." }
      return false
    }
    window.query = ""; window.selectedDocumentID = created.id
    await loadSelection(window)
    guard generation == workspaceGeneration, hasOpenWorkspace, window.selectedDocumentID == created.id,
      drafts[created.id] != nil else { return false }
    window.editorStartsAtEnd = editing
    window.isEditing = editing
    return true
  }
}
