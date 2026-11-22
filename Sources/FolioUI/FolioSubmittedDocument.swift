import Foundation
import FolioKnowledge
import FolioKnowledgeApple

/// Retains the identity of one submitted document. Rechecking its outcome never
/// executes another edit, even when publication succeeded without a receipt.
struct FolioSubmittedDocument: Sendable {
  enum Observation: Sendable {
    case committed, notObserved
    case uncertain(String)
  }

  let id: String
  let workspaceID: UUID
  let sourceRoot: URL
  let path: String
  let operationID: UUID
  let sourceRevision: String
  private(set) var wasObserved = false

  init(id: String, plan: WikiPreparedEdit, sourceRoot: URL) {
    self.id = id; workspaceID = plan.workspaceID; self.sourceRoot = sourceRoot
    path = plan.relativePath; operationID = plan.operationID; sourceRevision = plan.resultRevision
  }

  func confirmed() -> Self {
    var value = self; value.wasObserved = true; return value
  }

  func observe(in workspace: WikiWorkspace) async -> Observation {
    guard workspace.root == sourceRoot, workspace.workspaceID == workspaceID else {
      return .uncertain("원래 자료함에서 문서 추가 결과를 확인해 주세요.")
    }
    let status: WikiOperationStatus?
    do { status = try await workspace.operationStatus(operationID) }
    catch { status = nil }
    if let status, status.state == .committed {
      guard let receipt = status.receipt, receipt.operationID == operationID,
        receipt.relativePath == path, receipt.sourceRevision == sourceRevision else {
        return .uncertain("문서 저장 확인 정보가 요청과 다릅니다. 원문을 확인해 주세요.")
      }
      return .committed
    }
    do {
      let bytes = try await workspace.source(relativePath: path)
      return SourceDigest.sha256(bytes) == sourceRevision
        ? .committed : .uncertain("문서 원문이 저장 요청과 다릅니다. 현재 내용을 확인해 주세요.")
    } catch {
      let missing = (error as? CocoaError)?.code == .fileNoSuchFile
        || (error as? CocoaError)?.code == .fileReadNoSuchFile || (error as? POSIXError)?.code == .ENOENT
      if status?.state == .notObserved, missing { return .notObserved }
      return .uncertain(error.localizedDescription)
    }
  }
}
