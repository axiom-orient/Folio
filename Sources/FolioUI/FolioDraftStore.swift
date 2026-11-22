import Foundation
import FolioKnowledge
import Observation

@MainActor @Observable
final class FolioDraftStore {
  struct ReviewedSource: Equatable {
    let id = UUID()
    let documentID: String
    let path: String
    let revision: String
    let context: FolioDocumentContext
    let workspaceGeneration: Int

    init(document: WikiDocument, context: FolioDocumentContext, workspaceGeneration: Int) {
      documentID = document.id; path = document.relativePath; revision = document.revision
      self.context = context; self.workspaceGeneration = workspaceGeneration
    }
  }

  private(set) var drafts: [String: FolioDraft] = [:]
  private(set) var legacyDrafts: [String: FolioDraft] = [:]
  private(set) var savingDocuments: Set<String> = []
  private(set) var editingGeneration = 0
  @ObservationIgnored var onFailure: (@MainActor (String) -> Void)?
  @ObservationIgnored private var repository: FolioDraftRepository?
  @ObservationIgnored private var reviewedSources: [String: ReviewedSource] = [:]
  @ObservationIgnored private var pendingWrite: Task<Void, Never>?
  @ObservationIgnored private var writeGeneration = 0
  var isBound: Bool { repository != nil }
  var recoveryScopeURL: URL? { repository?.url }
  private(set) var acceptsPrivateInput = false

  func bind(_ repository: FolioDraftRepository) throws {
    detach()
    let restored = try repository.load()
    let legacy = try repository.loadLegacy()
    drafts = restored
    legacyDrafts = legacy
    self.repository = repository
    acceptsPrivateInput = true
  }

  func detach() {
    cancelPendingWrite()
    repository = nil
    acceptsPrivateInput = false
    reviewedSources = [:]
    legacyDrafts = [:]
  }

  func clear() { drafts = [:]; reviewedSources = [:] }

  /// An explicit source review applies to the shared dirty draft across windows.
  func reviewSource(_ document: WikiDocument, context: FolioDocumentContext, workspaceGeneration: Int) {
    guard drafts[document.id]?.isDirty == true else { return }
    reviewedSources[document.id] = ReviewedSource(document: document, context: context, workspaceGeneration: workspaceGeneration)
  }

  func sourceExpectation(for document: WikiDocument, context: FolioDocumentContext,
    workspaceGeneration: Int
  ) -> ReviewedSource? {
    if let reviewed = reviewedSources[document.id] { return reviewed }
    guard let draft = drafts[document.id], draft.path == document.relativePath,
      !draft.isDirty || draft.revision == document.revision else { return nil }
    return ReviewedSource(document: document, context: context, workspaceGeneration: workspaceGeneration)
  }

  func clearReviewedSource(matching expectation: ReviewedSource) {
    if drafts[expectation.documentID]?.isDirty != true || reviewedSources[expectation.documentID] == expectation {
      reviewedSources.removeValue(forKey: expectation.documentID)
    }
  }

  /// Retires editor bindings when their source or file context changes.
  func invalidateEditing() { editingGeneration += 1 }
  func stopPrivateInput() { acceptsPrivateInput = false; invalidateEditing() }

  func load(_ draft: FolioDraft, id: String) {
    guard drafts[id]?.isDirty != true else { return }
    drafts[id] = draft
  }

  func edit(_ text: String, id: String) {
    guard var draft = drafts[id] else { return }
    draft.text = text
    drafts[id] = draft
    if !draft.isDirty { reviewedSources.removeValue(forKey: id) }
    cancelPendingWrite()
    let generation = writeGeneration
    pendingWrite = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(300))
        guard let self, self.writeGeneration == generation else { return }
        self.pendingWrite = nil
        do { try self.checkpoint() }
        catch { self.onFailure?("편집 복구본을 보존하지 못했습니다: \(error.localizedDescription)") }
      } catch is CancellationError {}
      catch { self?.onFailure?(error.localizedDescription) }
    }
  }

  func discard(id: String) {
    guard let draft = drafts[id] else { return }
    drafts[id] = FolioDraft(path: draft.path, text: draft.original, original: draft.original, revision: draft.revision)
    reviewedSources.removeValue(forKey: id)
  }

  func remove(id: String) { drafts.removeValue(forKey: id); reviewedSources.removeValue(forKey: id) }
  func beginSaving(id: String) -> Bool { savingDocuments.insert(id).inserted }
  func endSaving(id: String) { savingDocuments.remove(id) }

  func completeSave(id: String, path: String, submittedText: String, revision: String) {
    drafts[id] = drafts[id]?.afterSaving(path: path, submittedText: submittedText, revision: revision)
    if drafts[id]?.isDirty != true { reviewedSources.removeValue(forKey: id) }
  }

  /// If the received source already contains this edit, keep the original
  /// recovery copy until the source CAS and durable receipt have succeeded.
  /// Newer typing remains based on the old source and will be reviewed again.
  func completeAlreadyPresent(id: String, expected: FolioDraft) {
    guard let current = drafts[id], current.matchesBytes(of: expected) else { return }
    drafts.removeValue(forKey: id)
  }

  /// A merge may replace only the exact draft it reviewed, and must survive a checkpoint before saving source.
  @discardableResult
  func rebase(id: String, expected: FolioDraft, receivedSource: String, mergedSource: String) throws -> Bool {
    guard let current = drafts[id], current.matchesBytes(of: expected),
      SourceDigest.sha256(expected.original).utf8.elementsEqual(expected.revision.utf8) else { return false }
    drafts[id] = FolioDraft(path: expected.path, text: mergedSource, original: receivedSource,
      revision: SourceDigest.sha256(receivedSource))
    do { try checkpoint() }
    catch { drafts[id] = expected; throw error }
    cancelPendingWrite()
    return true
  }

  func checkpoint() throws {
    guard let repository else {
      guard !drafts.values.contains(where: \.isDirty) else {
        throw WikiError.unavailable("원문을 저장하거나 편집 복사본을 공유해 주세요.")
      }
      return
    }
    try repository.write(drafts)
  }

  func cancelPendingWrite() { writeGeneration += 1; pendingWrite?.cancel(); pendingWrite = nil }
}
