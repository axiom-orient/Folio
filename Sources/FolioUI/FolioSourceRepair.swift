import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import Observation

/// Captured source contract and one shared raw-input lifetime. Draft document
/// text stays in FolioDraftStore; non-draft text remains here until resolved.
@MainActor @Observable
final class FolioSourceRepair: Identifiable {
  enum SourceAvailability: Equatable {
    case observed, missingLocal, unavailableCloud
    var allowsSave: Bool { self != .unavailableCloud }
  }
  let id = UUID(); let path: String; let draftID: String?
  private(set) var revision: String?
  private(set) var text: String
  let sourceRoot: URL; let workspaceID: UUID
  let documentGeneration: Int?
  let observedSourceText: String?
  let sourceAvailability: SourceAvailability
  private(set) var editedText: String
  private(set) var isResolved = false
  var hasUnsavedInput: Bool { draftID == nil && !isResolved && editedText != text }
  init(path: String, revision: String?, text: String, sourceRoot: URL, workspaceID: UUID, draftID: String? = nil,
    observedSourceText: String? = nil, sourceAvailability: SourceAvailability = .observed, documentGeneration: Int? = nil) {
    self.path = path; self.revision = revision; self.text = text; self.sourceRoot = sourceRoot
    self.workspaceID = workspaceID; self.draftID = draftID; self.observedSourceText = observedSourceText
    self.sourceAvailability = sourceAvailability
    self.documentGeneration = documentGeneration
    editedText = text
  }
  func edit(_ value: String) { if draftID == nil, !isResolved { editedText = value } }
  @discardableResult
  func discardChanges(matching expectedText: String) -> Bool {
    guard editedText.utf8.elementsEqual(expectedText.utf8) else { return false }
    editedText = text; isResolved = true
    return true
  }
  func completeSave(_ submittedText: String, revision: String) {
    guard draftID == nil else { return }
    // Only a confirmed own write advances this baseline. Newer input remains
    // dirty and can use the new CAS revision for its next explicit Save.
    self.revision = revision; text = submittedText
    isResolved = editedText == submittedText
  }
  static func recoveringDraft(id: String, draft: FolioDraft, observedBytes: Data?, sourceRoot: URL, workspaceID: UUID,
    isCloudWorkspace: Bool = false, documentGeneration: Int? = nil) throws -> Self {
    let observed: String?
    if let observedBytes {
      guard observedBytes.count <= 256 * 1024, let decoded = String(data: observedBytes, encoding: .utf8) else {
        throw WikiError.unavailable("현재 원문을 비교하려면 256 KiB 이하의 UTF-8 문서가 필요합니다. 원문 폴더에서 확인해 주세요.")
      }
      observed = decoded
    } else { observed = nil }
    return Self(path: draft.path, revision: observedBytes.map(SourceDigest.sha256), text: draft.text,
      sourceRoot: sourceRoot, workspaceID: workspaceID, draftID: id, observedSourceText: observed,
      sourceAvailability: observedBytes != nil ? .observed : isCloudWorkspace ? .unavailableCloud : .missingLocal,
      documentGeneration: documentGeneration)
  }

  func prepareSave(replacement: String, in workspace: WikiWorkspace) async throws -> WikiPreparedEdit {
    guard sourceRoot == workspace.root, workspaceID == workspace.workspaceID else { throw WikiError.changedSource }
    guard sourceAvailability.allowsSave else {
      throw WikiError.unavailable("iCloud 원문을 확인할 수 없습니다. 초안은 유지했습니다. 원문을 받은 뒤 다시 확인해 주세요.")
    }
    return try await workspace.prepareRawSave(relativePath: path, expectedRevision: revision,
      replacement: replacement, operationID: UUID())
  }
}
