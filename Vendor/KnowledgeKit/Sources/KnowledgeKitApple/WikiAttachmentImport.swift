import Foundation
import FolioKnowledge
import Markdown

/// A copied asset and its separately committed note are distinct durable outcomes.
public struct WikiAttachmentImport: Codable, Identifiable, Sendable {
  public let id: UUID
  public let workspaceID: UUID
  public let filename: String
  public let relativePath: String
  public let sourceRevision: String
  // Older ledger entries predate the source scope and are still recoverable
  // where their copied bytes and write receipt match.
  let sourceScopeSHA256: String?
  public var linkedReceipt: WikiWriteReceipt?
  public var noteID: String { id.uuidString.lowercased() }
  public var notePath: String { "notes/" + noteID + ".md" }

  package static func noteSource(id: String, filename: String, link: String) -> String {
    let title = filename.components(separatedBy: .newlines).joined(separator: " ")
    let body = Paragraph(Link(destination: link, Markdown.Text(WikiMarkdownEditor.literalInline(title)))).format()
    return "---\nid: \(id)\n---\n\n" + WikiMarkdownEditor.literalHeading(title) + "\n\n" + body + "\n"
  }

  /// Only the bytes produced by the importer are an attachment-only note.
  package static func unmodifiedPDFPath(in document: WikiDocument) -> String? {
    guard document.declarations.count == 1, let declaration = document.declarations.first,
      declaration.origin == .markdownLink,
      let path = WikiPath.resolveLink(declaration.target, from: document.relativePath),
      path.hasPrefix("attachments/"),
      URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" else { return nil }
    let name = URL(fileURLWithPath: path).lastPathComponent
    let prefix = document.id + "-"
    guard UUID(uuidString: document.id) != nil, name.hasPrefix(prefix) else { return nil }
    let generated = noteSource(id: document.id, filename: String(name.dropFirst(prefix.count)), link: declaration.target)
    return SourceDigest.sha256(generated) == document.revision ? path : nil
  }
}

extension WikiWorkspace {
  private var attachmentLedger: URL { receiptDirectory.appendingPathComponent("AttachmentImports", isDirectory: true) }
  private var attachmentScopeSHA256: String {
    SourceDigest.sha256(root.path + "\0" + workspaceID.uuidString + "\0" + (knowledgeAccountScope?.uuidString ?? ""))
  }

  /// Caller retains security scope; an intent survives a crash between copy and note Save.
  public func importAttachment(fromSelectedURL url: URL) throws -> WikiAttachmentImport {
    try importAttachment(fromSelectedURL: url, operationID: UUID())
  }

  /// The caller retains the operation ID before the first attempt. If its ledger
  /// already exists, recover the copy from original bytes without reading the picker URL.
  public func importAttachment(fromSelectedURL url: URL, operationID: UUID) throws -> WikiAttachmentImport {
    try requireOpen()
    if let stored = try observedAttachmentImport(operationID) { return stored }
    try Task.checkCancellation()
    let filename = url.lastPathComponent
    guard !filename.hasPrefix(".") else { throw WikiError.invalidSource("Expected a named attachment.") }
    let bytes = try CoordinatedFiles.readSelectedFile(at: url, maximumBytes: 50 * 1024 * 1024)
    guard !bytes.isEmpty else { throw WikiError.invalidSource("Empty attachment.") }
    try requireOpen()
    try Task.checkCancellation()
    let record = WikiAttachmentImport(id: operationID, workspaceID: workspaceID, filename: filename,
      relativePath: try WikiPath.validate("attachments/" + operationID.uuidString.lowercased() + "-" + filename),
      sourceRevision: SourceDigest.sha256(bytes), sourceScopeSHA256: attachmentScopeSHA256, linkedReceipt: nil)
    try WikiLocalStorage.createDirectory(attachmentLedger)
    try CoordinatedFiles.write(root: attachmentLedger, path: operationID.uuidString + ".json", expectedRevision: nil,
      bytes: JSONEncoder().encode(record))
    try CoordinatedFiles.write(root: root, path: record.relativePath, expectedRevision: nil, bytes: bytes,
      validateAccess: validateSourceAccess)
    return record
  }

  public func observedAttachmentImport(_ operationID: UUID) throws -> WikiAttachmentImport? {
    try requireOpen()
    guard let stored = try attachmentRecord(operationID) else { return nil }
    try validateAttachmentScope(stored)
    do { try verifyAttachmentBytes(stored) }
    catch where Self.attachmentMissing(error) {
      throw WikiError.unavailable("이전 첨부 복사 결과를 확인할 수 없습니다. 원래 자료함의 첨부를 확인해 주세요.")
    }
    return stored
  }

  public func hasAttachmentImportIntent(_ operationID: UUID) throws -> Bool {
    try requireOpen()
    guard let stored = try attachmentRecord(operationID) else { return false }
    try validateAttachmentScope(stored)
    return true
  }

  /// Verify only the selected import before preparing its note.
  public func verifyAttachmentImport(_ record: WikiAttachmentImport) throws {
    try requireOpen()
    guard let stored = try attachmentRecord(record.id) else { throw WikiError.changedSource }
    try validateAttachmentRecord(stored, matching: record)
    try verifyAttachmentBytes(stored)
  }

  /// Read current bytes; never recopy an asset or re-execute an uncertain note effect.
  public func pendingAttachmentImports() throws -> [WikiAttachmentImport] {
    try requireOpen()
    guard FileManager.default.fileExists(atPath: attachmentLedger.path) else { return [] }
    let files = try FileManager.default.contentsOfDirectory(at: attachmentLedger, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    let sourceScope = attachmentScopeSHA256
    var pending: [WikiAttachmentImport] = []
    for url in files {
      try Task.checkCancellation()
      guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
        throw WikiError.invalidSource("Invalid attachment record name.")
      }
      guard let record = try attachmentRecord(id), record.linkedReceipt == nil,
        record.sourceScopeSHA256 == nil || record.sourceScopeSHA256 == sourceScope else { continue }
      do { try verifyAttachmentBytes(record) }
      catch where Self.attachmentMissing(error) { continue }
      guard pending.count < 2048 else { throw WikiError.unavailable("Too many unfinished attachment imports.") }
      pending.append(record)
    }
    return pending
  }

  public func finishAttachmentImport(_ record: WikiAttachmentImport, noteReceipt: WikiWriteReceipt) throws {
    try requireOpen()
    guard let observed = try operationStatus(record.id).receipt, observed.operationID == noteReceipt.operationID,
      observed.relativePath == record.notePath, observed.relativePath == noteReceipt.relativePath,
      observed.sourceRevision == noteReceipt.sourceRevision, observed.previousRevision == nil else {
      throw WikiError.changedSource
    }
    let path = record.id.uuidString + ".json"
    let original = try CoordinatedFiles.read(root: attachmentLedger, path: path, maximumBytes: 65536)
    let stored = try decodeAttachmentRecord(original, id: record.id)
    try validateAttachmentRecord(stored, matching: record)
    try verifyAttachmentBytes(stored)
    guard SourceDigest.sha256(try source(relativePath: record.notePath)) == observed.sourceRevision else { throw WikiError.changedSource }
    if let completed = stored.linkedReceipt {
      guard completed.operationID == noteReceipt.operationID, completed.relativePath == noteReceipt.relativePath,
        completed.sourceRevision == noteReceipt.sourceRevision else { throw WikiError.changedSource }
      return
    }
    var completed = stored; completed.linkedReceipt = observed
    try CoordinatedFiles.write(root: attachmentLedger, path: path, expectedRevision: SourceDigest.sha256(original),
      bytes: JSONEncoder().encode(completed))
  }

  private func attachmentRecord(_ id: UUID) throws -> WikiAttachmentImport? {
    let filename = id.uuidString + ".json"
    do {
      // A first capture may have no ledger directory. Check existence before
      // coordinating a read so missing parents do not become coordination errors.
      _ = try FileManager.default.attributesOfItem(atPath: attachmentLedger.appendingPathComponent(filename).path)
      return try decodeAttachmentRecord(CoordinatedFiles.read(root: attachmentLedger, path: filename,
        maximumBytes: 65536), id: id)
    } catch where Self.attachmentMissing(error) { return nil }
  }

  private func decodeAttachmentRecord(_ bytes: Data, id: UUID) throws -> WikiAttachmentImport {
    let record = try JSONDecoder().decode(WikiAttachmentImport.self, from: bytes)
    guard record.id == id, record.workspaceID == workspaceID,
      record.filename == URL(fileURLWithPath: record.filename).lastPathComponent,
      !record.filename.hasPrefix("."), record.relativePath == "attachments/" + id.uuidString.lowercased() + "-" + record.filename else {
      throw WikiError.invalidSource("Invalid attachment record.")
    }
    return record
  }

  private func validateAttachmentScope(_ record: WikiAttachmentImport) throws {
    guard record.sourceScopeSHA256 == nil || record.sourceScopeSHA256 == attachmentScopeSHA256 else { throw WikiError.changedSource }
  }

  private func validateAttachmentRecord(_ stored: WikiAttachmentImport, matching record: WikiAttachmentImport) throws {
    try validateAttachmentScope(stored)
    guard stored.id == record.id, stored.workspaceID == record.workspaceID,
      stored.sourceRevision == record.sourceRevision, stored.relativePath == record.relativePath else { throw WikiError.changedSource }
  }

  private func verifyAttachmentBytes(_ record: WikiAttachmentImport) throws {
    guard NSFileVersion.unresolvedConflictVersionsOfItem(at: root.appendingPathComponent(record.relativePath))?.isEmpty != false else {
      throw WikiError.conflict(record.relativePath)
    }
    let bytes = try CoordinatedFiles.read(root: root, path: record.relativePath, maximumBytes: 50 * 1024 * 1024)
    guard SourceDigest.sha256(bytes) == record.sourceRevision else { throw WikiError.changedSource }
  }

  private static func attachmentMissing(_ error: any Error) -> Bool {
    let error = error as NSError
    switch error.domain {
    case NSCocoaErrorDomain:
      return error.code == CocoaError.fileNoSuchFile.rawValue || error.code == CocoaError.fileReadNoSuchFile.rawValue
    case NSPOSIXErrorDomain:
      return error.code == Int(POSIXErrorCode.ENOENT.rawValue)
    default:
      return false
    }
  }
}
