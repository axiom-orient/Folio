import Darwin
import Foundation
import Observation
import FolioKnowledge
import FolioKnowledgeApple

/// One host-owned editing session. Source writes are exclusively KnowledgeKit CAS
/// operations; recovery writes never touch source. Initialization has no effects.
@MainActor @Observable
public final class FolioSession {
  public private(set) var snapshot: FolioWorkspaceSnapshot?
  public private(set) var selectedDocument: FolioDocument?
  public private(set) var isBusy = false
  public var documents: [FolioDocument] { snapshot?.documents ?? [] }
  public var draftText: String { selection?.text ?? "" }
  public var sourceText: String { selection?.original ?? "" }
  public var isDirty: Bool { selection?.isDirty ?? false }
  public var editingTarget: FolioEditingTarget? {
    selection.map { .init(documentID: $0.id, contextID: editingContextID, selectionID: selectionID) }
  }
  public var pendingOperationID: UUID? { selection?.pending?.operationID }
  public var recoverableDrafts: [FolioDocument] { drafts.values.map(\.document).sorted { $0.relativePath < $1.relativePath } }

  public let configuration: FolioConfiguration
  @ObservationIgnored private var workspace: WikiWorkspace?
  @ObservationIgnored private var knowledge: WikiKnowledgeQuery?
  @ObservationIgnored private var recovery: FolioRecoveryStore?
  @ObservationIgnored private var admission: FolioSourceAdmission?
  @ObservationIgnored private var openedState: URL?
  private var drafts: [String: SDKDraft] = [:]
  private var selection: SDKDraft?
  private var isSaving = false
  private var selectionID = UUID()
  public private(set) var editingContextID = UUID()

  public init(configuration: FolioConfiguration) { self.configuration = configuration }

  /// Creates only a previously absent directory. A failure leaves any partially
  /// created source intact for inspection; it never merges or removes host files.
  public static func createWorkspace(at root: URL, name: String) throws {
    guard root.isFileURL, root.path.hasPrefix("/"), !name.isEmpty else { throw FolioError.invalidConfiguration }
    guard mkdir(root.path, mode_t(0o700)) == 0 else { throw FolioError.changedSource }
    try WikiWorkspace.create(at: root, name: name)
  }

  public func openWorkspace(at source: URL, location: FolioSourceLocation = .local) async throws {
    try beginOperation()
    defer { isBusy = false }
    guard source.isFileURL, source.path.hasPrefix("/") else { throw FolioError.invalidConfiguration }
    let root = source.standardizedFileURL.resolvingSymlinksInPath()
    let paths = try FolioStatePaths(configuration: configuration, sourceRoot: root)
    let host = paths.hostDirectory
    let check = try FolioSourceAdmission(location: location, root: root, stateDirectory: host, hostAccess: configuration.sourceAccess)
    let scopeIdentity = FolioRecoveryScope(namespace: configuration.namespace, path: root.path,
      location: location, account: check.accountID)
    let scope = try scopeIdentity.digest
    let sourceID = try WikiWorkspace.identity(at: root, validateSourceAccess: { try check.validate() })
    let state = try paths.workspaceDirectory(scope: scope, workspaceID: sourceID)
    try paths.recordScope(scopeIdentity)
    if openedState?.path == state.path, let workspace {
      let next = try await workspace.refresh()
      try check.validate(); publish(next)
      return
    }
    // Lock the entire ID/location/account scope before opening its derived index.
    let store = try FolioRecoveryStore(directory: state, scope: scope)
    let restored = try store.load()
    let candidate = try WikiWorkspace(root: root, localStateDirectory: state.appendingPathComponent("Index"),
      validateSourceAccess: { try check.validate() })
    do {
      guard candidate.workspaceID == sourceID else { throw FolioError.changedSource }
      let next = try await candidate.refresh()
      try check.validate(); try Task.checkCancellation()
      try recovery?.write(drafts)
      if let workspace { await workspace.close() }
      workspace = candidate; recovery = store; admission = check; openedState = state
      knowledge = WikiKnowledgeQuery(workspace: candidate)
      editingContextID = UUID()
      drafts = restored; selection = nil; selectedDocument = nil
      publish(next)
    } catch { await candidate.close(); throw error }
  }

  public func openDocument(id: String) async throws {
    try beginOperation()
    defer { isBusy = false }
    guard let workspace else { throw FolioError.noWorkspace }
    try admission?.validate()
    if let restored = drafts[id] {
      selectionID = UUID()
      selection = restored; selectedDocument = restored.document
      return
    }
    guard let document = documents.first(where: { $0.id == id }) else { throw FolioError.noDocument }
    let bytes = try await workspace.source(relativePath: document.relativePath)
    try admission?.validate()
    guard SourceDigest.sha256(bytes) == document.revision, let text = String(data: bytes, encoding: .utf8) else {
      throw FolioError.changedSource
    }
    selectionID = UUID()
    selection = SDKDraft(id: id, title: document.title, path: document.relativePath,
      text: text, original: text, revision: document.revision)
    selectedDocument = document
  }

  /// Checkpoint before publishing the edit. A host must surface a thrown error
  /// and keep its native editor text; do not replace it with an older binding.
  public func updateDraft(_ text: String) throws {
    guard !isBusy || isSaving else { throw FolioError.busy }
    guard var next = selection else { throw FolioError.noDocument }
    next.text = text
    try store(next)
  }

  /// UI-bound variant rejects callbacks from a previous document or account.
  public func updateDraft(_ text: String, target: FolioEditingTarget) throws {
    try validate(target)
    try updateDraft(text)
  }

  private func validate(_ target: FolioEditingTarget) throws {
    guard target == editingTarget else { throw FolioError.changedSource }
  }

  @discardableResult public func save(target: FolioEditingTarget? = nil) async throws -> FolioSaveReceipt {
    if let target { try validate(target) }
    try beginOperation(); isSaving = true
    defer { isBusy = false; isSaving = false }
    guard let workspace, let draft = selection else { throw FolioError.noDocument }
    if let pending = draft.pending { throw FolioError.pendingSave(pending.operationID) }
    guard draft.isDirty else { throw FolioError.noChanges }
    let submitted = try WikiMarkdownParser.document(relativePath: draft.path, bytes: Data(draft.text.utf8))
    guard submitted.id == draft.id else { throw FolioError.documentIdentityChanged }
    try admission?.validate()
    let pending = SDKPendingSave(operationID: UUID(), text: draft.text,
      resultRevision: SourceDigest.sha256(Data(draft.text.utf8)))
    var staged = draft; staged.pending = pending
    try store(staged)
    do {
      let plan = try await workspace.prepareRawSave(relativePath: draft.path,
        expectedRevision: draft.revision, replacement: draft.text, operationID: pending.operationID)
      try admission?.validate()
      let receipt = try await workspace.execute(plan)
      try complete(receipt, pending: pending)
      // Successful source commit remains successful even if projection refresh is unavailable.
      if let next = try? await workspace.refresh() { publish(next) }
      return receiptValue(receipt)
    } catch {
      // A failed preparation has no durable intent. An uncertain execute keeps
      // its operation ID until the host explicitly asks to inspect its status.
      if let status = try? await workspace.operationStatus(pending.operationID), status.state == .notObserved,
        var current = selection, current.pending == pending {
        current.pending = nil
        try? store(current)
      }
      throw error
    }
  }

  /// Query-only reconciliation. No path here executes or retries a source write.
  @discardableResult public func resolvePendingSave(target: FolioEditingTarget? = nil) async throws -> FolioSaveOutcome {
    if let target { try validate(target) }
    try beginOperation()
    defer { isBusy = false }
    guard let workspace, let draft = selection else { throw FolioError.noDocument }
    guard let pending = draft.pending else { throw FolioError.noChanges }
    try admission?.validate()
    let status = try await workspace.operationStatus(pending.operationID)
    try admission?.validate()
    switch status.state {
    case .uncertain: return .uncertain
    case .notObserved:
      var current = draft; current.pending = nil; try store(current)
      return .notObserved
    case .committed:
      guard let receipt = status.receipt else { return .uncertain }
      try complete(receipt, pending: pending)
      return .committed(receiptValue(receipt))
    }
  }

  /// Reads current source without changing a private draft or its baseline.
  public func readCurrentSource(target: FolioEditingTarget? = nil) async throws -> FolioSourceReview {
    if let target { try validate(target) }
    try beginOperation()
    defer { isBusy = false }
    guard let workspace, let draft = selection else { throw FolioError.noDocument }
    try admission?.validate()
    let bytes = try await workspace.source(relativePath: draft.path)
    try admission?.validate()
    guard let text = String(data: bytes, encoding: .utf8) else { throw FolioError.changedSource }
    let document = try WikiMarkdownParser.document(relativePath: draft.path, bytes: bytes)
    guard document.id == draft.id else { throw FolioError.changedSource }
    return .init(documentID: draft.id, relativePath: draft.path,
      revision: SourceDigest.sha256(bytes), text: text, contextID: editingContextID, selectionID: selectionID)
  }

  /// Explicit host/user conflict choice; this never writes source. Saving still
  /// uses CAS, so a source change after review or adoption cannot be overwritten.
  public func adoptReviewedSource(_ review: FolioSourceReview, mergedText: String,
    resolvingPendingSave operationID: UUID? = nil
  ) async throws {
    try beginOperation()
    defer { isBusy = false }
    guard let workspace, var draft = selection else { throw FolioError.noDocument }
    if let pending = draft.pending {
      guard operationID == pending.operationID else { throw FolioError.pendingSave(pending.operationID) }
      // A known commit must be reconciled from its receipt, never abandoned.
      let status = try await workspace.operationStatus(pending.operationID)
      guard status.state != .committed else { throw FolioError.pendingSave(pending.operationID) }
    } else if operationID != nil { throw FolioError.changedSource }
    guard review.contextID == editingContextID, review.selectionID == selectionID, review.documentID == draft.id,
      review.relativePath == draft.path else { throw FolioError.changedSource }
    try admission?.validate()
    let bytes = try await workspace.source(relativePath: draft.path)
    try admission?.validate()
    guard SourceDigest.sha256(bytes) == review.revision else { throw FolioError.changedSource }
    if draft.pending != nil {
      guard let recovery else { throw FolioError.noWorkspace }
      try recovery.archivePending(draft)
      draft.pending = nil
    }
    draft.original = review.text; draft.revision = review.revision; draft.text = mergedText
    try store(draft)
    selectedDocument = draft.document
  }

  /// Convenience for the first 50 results. Use searchPage for complete traversal.
  public func search(_ query: String) async throws -> [FolioSearchResult] {
    try await searchPage(query).results
  }

  public func searchPage(_ query: String,
    continuation: FolioSearchContinuation? = nil
  ) async throws -> FolioSearchPage {
    try beginOperation()
    defer { isBusy = false }
    guard let workspace else { throw FolioError.noWorkspace }
    if let continuation, continuation.contextID != editingContextID { throw FolioError.changedSource }
    try admission?.validate()
    // The existing cursor checks query, source revision, ranking and page size.
    // No Spotlight registration, global search or network service is activated.
    let page = try await workspace.localSearchPage(query, cursor: continuation?.cursor, pageSize: 50)
    try admission?.validate()
    if let current = try await workspace.projection.snapshot() { publish(current) }
    return .init(results: page.hits.map {
      .init(documentID: $0.reference.documentID, sectionID: $0.reference.sectionID,
        title: $0.title, excerpt: $0.snippet)
    }, totalCount: page.totalCount,
      nextContinuation: page.nextCursor.map { .init(contextID: editingContextID, cursor: $0) },
      coverageComplete: page.coverageComplete,
      diagnostics: page.diagnostics.map { $0.path + ": " + $0.reason })
  }

  /// Complete lexical corpus, without loading a model or registering system search.
  public func prepareKnowledgeIndex() async throws -> WikiKnowledgeCoverage {
    try beginOperation(); defer { isBusy = false }
    guard let knowledge else { throw FolioError.noWorkspace }
    try admission?.validate()
    let result = try await knowledge.prepare()
    try admission?.validate(); try Task.checkCancellation()
    return result
  }

  /// Exact current-source quotations, not a generated factual answer.
  public func knowledgeAnswer(_ question: String, documentID: String? = nil) async throws -> WikiKnowledgeAnswer {
    try beginOperation(); defer { isBusy = false }
    guard let knowledge else { throw FolioError.noWorkspace }
    try admission?.validate()
    let result = try await knowledge.answer(question, documentID: documentID)
    try admission?.validate(); try Task.checkCancellation()
    return result
  }

  public func readKnowledgeEvidence(_ evidence: WikiKnowledgeEvidence) async throws -> String {
    try beginOperation(); defer { isBusy = false }
    guard let workspace else { throw FolioError.noWorkspace }
    try admission?.validate()
    let text = try await workspace.readKnowledgeEvidence(evidence)
    try admission?.validate(); try Task.checkCancellation()
    return text
  }

  public func previewKnowledgePDF(_ evidence: WikiKnowledgeEvidence) async throws -> WikiKnowledgePDFPreview {
    try beginOperation(); defer { isBusy = false }
    guard let workspace else { throw FolioError.noWorkspace }
    try admission?.validate()
    let preview = try await workspace.previewKnowledgePDF(evidence)
    try admission?.validate(); try Task.checkCancellation()
    return preview
  }

  /// The host awaits this before releasing security-scoped URLs, changing its
  /// account or protected-data access. Drafts remain on disk after close.
  public func close() async throws {
    try beginOperation()
    defer { isBusy = false }
    try recovery?.write(drafts)
    if let workspace { await workspace.close() }
    workspace = nil; knowledge = nil; recovery = nil; admission = nil; openedState = nil
    editingContextID = UUID()
    selection = nil; selectedDocument = nil; snapshot = nil; drafts = [:]
  }

  private func beginOperation() throws {
    guard !isBusy else { throw FolioError.busy }
    isBusy = true
  }
  private func store(_ draft: SDKDraft) throws {
    guard let recovery else { throw FolioError.noWorkspace }
    var updated = drafts
    if draft.isDirty || draft.pending != nil { updated[draft.id] = draft }
    else { updated.removeValue(forKey: draft.id) }
    try recovery.write(updated)
    drafts = updated; selection = draft
  }
  private func complete(_ receipt: WikiWriteReceipt, pending: SDKPendingSave) throws {
    guard var current = selection, current.pending == pending,
      receipt.operationID == pending.operationID, receipt.relativePath == current.path,
      receipt.sourceRevision == pending.resultRevision else { throw FolioError.changedSource }
    current.original = pending.text; current.revision = receipt.sourceRevision; current.pending = nil
    if let source = try? WikiMarkdownParser.document(relativePath: current.path, bytes: Data(pending.text.utf8)),
      source.id == current.id { current.title = source.title }
    try store(current)
    selectedDocument = current.document
  }
  private func receiptValue(_ receipt: WikiWriteReceipt) -> FolioSaveReceipt {
    .init(operationID: receipt.operationID, sourceRevision: receipt.sourceRevision, diagnostic: receipt.diagnostic)
  }
  private func publish(_ source: WikiSnapshot) {
    snapshot = .init(id: source.workspace.id, name: source.workspace.name,
      documents: source.documents.map { .init(id: $0.id, title: $0.title, relativePath: $0.relativePath, revision: $0.revision) },
      diagnostics: source.diagnostics.map { $0.path + ": " + $0.reason }, coverageComplete: source.coverageComplete)
  }
}
