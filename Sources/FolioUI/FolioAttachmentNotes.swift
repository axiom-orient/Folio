import Foundation
import FolioKnowledge
import FolioKnowledgeApple

@MainActor enum FolioAttachmentNotes {
  /// Only the untouched, generated PDF companion gets the single source action.
  /// A note containing a user's own text or links stays a normal Markdown reader.
  static func originalPDF(in document: WikiDocument) -> String? {
    guard document.declarations.count == 1, let declaration = document.declarations.first,
      declaration.origin == .markdownLink,
      let path = WikiPath.resolveLink(declaration.target, from: document.relativePath),
      path.hasPrefix("attachments/"),
      URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" else { return nil }
    let name = URL(fileURLWithPath: path).lastPathComponent
    let prefix = document.id + "-"
    guard UUID(uuidString: document.id) != nil, name.hasPrefix(prefix) else { return nil }
    let original = FolioInput.attachmentSource(id: document.id,
      filename: String(name.dropFirst(prefix.count)), link: declaration.target)
    return SourceDigest.sha256(original) == document.revision ? path : nil
  }

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
      var allowed = CharacterSet.urlPathAllowed
      allowed.remove(charactersIn: "#?%()[]<>")
      let link = "../" + (record.relativePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? record.relativePath)
      let plan = try await workspace.prepareEdit(relativePath: record.notePath, expectedRevision: nil, range: nil,
        replacement: FolioInput.attachmentSource(id: record.noteID, filename: record.filename, link: link), operationID: record.id)
      receipt = try await workspace.execute(plan)
    }
    try await workspace.finishAttachmentImport(record, noteReceipt: receipt)
  }
}
