import Foundation
import FolioKnowledge

extension WikiWorkspace {
  /// One synchronous actor segment validates every reference in request order.
  /// Each distinct path is coordinated/read/parsed once; no derived cache supplies evidence.
  public func read(_ references: [WikiEvidenceReference]) throws -> [String] {
    try requireOpen()
    guard references.count <= 1000 else { throw WikiError.invalidSource("Evidence batches accept at most 1,000 references.") }
    guard NSFileVersion.unresolvedConflictVersionsOfItem(at: root.appendingPathComponent("_workspace.md"))?.isEmpty != false else {
      throw WikiError.conflict("_workspace.md")
    }
    let identity = try WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: root, path: "_workspace.md", maximumBytes: 65536))
    guard references.allSatisfy({ $0.workspaceID == identity.id }) else { throw WikiError.changedSource }
    let groups = Dictionary(grouping: references.indices, by: { references[$0].relativePath })
    var results = [String](repeating: "", count: references.count)
    for path in groups.keys.sorted() {
      try Task.checkCancellation()
      let url = root.appendingPathComponent(try WikiPath.validate(path))
      guard NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty != false else { throw WikiError.conflict(path) }
      let bytes = try CoordinatedFiles.read(root: root, path: path)
      let revision = SourceDigest.sha256(bytes)
      let indices = groups[path] ?? []
      guard indices.allSatisfy({ references[$0].sourceRevision == revision }) else { throw WikiError.changedSource }
      let document = try WikiMarkdownParser.document(relativePath: path, bytes: bytes)
      let sections = Dictionary(uniqueKeysWithValues: document.sections.map { ($0.id, $0.range) })
      for index in indices {
        try Task.checkCancellation()
        let reference = references[index]
        guard document.id == reference.documentID, sections[reference.sectionID] == reference.range else { throw WikiError.changedSource }
        results[index] = try reference.resolve(currentBytes: bytes, verifiedSourceRevision: revision)
      }
    }
    return results
  }
}
