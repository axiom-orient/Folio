import Foundation
import FolioKnowledge

extension WikiWorkspace {
  /// Metadata shares the approved source edit/CAS lane; this method never writes.
  public func prepareMetadataEdit(relativePath: String, expectedRevision: String, title: String,
    tags: [String], operationID: UUID
  ) async throws -> WikiPreparedEdit {
    try requireOpen()
    let path = try WikiPath.validate(relativePath)
    guard path.hasPrefix("notes/"), ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
      throw WikiError.invalidPath("Metadata edits must target Markdown inside notes/.")
    }
    let old = try CoordinatedFiles.read(root: root, path: path, maximumBytes: 256 * 1024)
    guard SourceDigest.sha256(old) == expectedRevision else { throw WikiError.changedSource }
    let bytes = try WikiMarkdownEditor.editingMetadata(bytes: old, title: title, tags: tags, relativePath: path)
    return try await prepareEdit(relativePath: path, expectedRevision: expectedRevision, range: nil,
      replacement: String(decoding: bytes, as: UTF8.self), operationID: operationID)
  }
}
