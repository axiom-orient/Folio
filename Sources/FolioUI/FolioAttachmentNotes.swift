import FolioKnowledge
import FolioKnowledgeApple

@MainActor enum FolioAttachmentNotes {
  static func link(_ record: WikiAttachmentImport, in workspace: WikiWorkspace) async throws {
    guard record.workspaceID == workspace.workspaceID else { throw WikiError.changedSource }
    let status = try await workspace.operationStatus(record.id)
    let receipt: WikiWriteReceipt
    if let committed = status.receipt { receipt = committed }
    else {
      guard status.state == .notObserved else {
        throw WikiError.unavailable("연결 노트의 저장 결과가 불확실합니다. 원문과 작업 기록을 확인해 주세요. 첨부를 다시 복사하지 않습니다.")
      }
      try await workspace.verifyAttachmentImport(record)
      let link = try WikiPath.linkFromNotesDirectory(to: record.relativePath)
      let plan = try await workspace.prepareEdit(relativePath: record.notePath, expectedRevision: nil, range: nil,
        replacement: WikiAttachmentImport.noteSource(id: record.noteID, filename: record.filename, link: link), operationID: record.id)
      receipt = try await workspace.execute(plan)
    }
    try await workspace.finishAttachmentImport(record, noteReceipt: receipt)
  }
}
