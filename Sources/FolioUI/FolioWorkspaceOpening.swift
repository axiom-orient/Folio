import FolioKnowledgeApple

/// Logical document identity survives an iOS source lease suspension. Only an
/// internal resume of the same admitted workspace may retain an open form.
enum FolioWorkspaceOpening: Equatable, Sendable {
  enum Intent: Sendable { case user, lifecycleResume }
  enum AdmissionError: Error, Equatable { case documentMutation, metadataEditing, sourceWrite }
  case replace, reopen, resume

  static func resolve(intent: Intent, requested: WikiWorkspaceLocation, current: WikiWorkspaceLocation?,
    pending: WikiWorkspaceLocation?, hasSnapshot: Bool, isSuspended: Bool
  ) -> Self {
    guard requested == current, hasSnapshot else { return .replace }
    if case .lifecycleResume = intent, isSuspended, requested == (pending ?? current) { return .resume }
    return .reopen
  }

  var preservesNavigation: Bool { self != .replace }
  func nextDocumentGeneration(after current: Int) -> Int { preservesNavigation ? current : current + 1 }

  func checkpoint(hasMetadataEditor: Bool, isSaving: Bool, isLinking: Bool, isApplyingDocumentChanges: Bool,
    operation: () throws -> Void
  ) throws {
    guard !isApplyingDocumentChanges else { throw AdmissionError.documentMutation }
    guard !hasMetadataEditor || self == .resume else { throw AdmissionError.metadataEditing }
    guard !isSaving, !isLinking else { throw AdmissionError.sourceWrite }
    try operation()
  }
}
