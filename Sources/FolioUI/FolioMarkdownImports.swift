import Foundation
import Observation
import FolioKnowledgeApple

/// Pending results survive picker dismissal and workspace changes. A retry
/// observes the original submission before it may prepare another document.
@MainActor @Observable
final class FolioMarkdownImports {
  struct Key: Hashable {
    let source: URL
    let root: URL
    let workspaceID: UUID
    let recoveryScope: URL

    init(source: URL, workspace: WikiWorkspace, recoveryScope: URL) {
      self.source = source.standardizedFileURL
      root = workspace.root; workspaceID = workspace.workspaceID
      self.recoveryScope = recoveryScope
    }
  }

  private var submissions: [Key: FolioSubmittedDocument] = [:]

  func submission(for key: Key) -> FolioSubmittedDocument? { submissions[key] }
  func retain(_ submission: FolioSubmittedDocument, for key: Key) { submissions[key] = submission }
  func finish(_ submission: FolioSubmittedDocument, for key: Key) {
    guard submissions[key]?.operationID == submission.operationID else { return }
    submissions.removeValue(forKey: key)
  }
}
