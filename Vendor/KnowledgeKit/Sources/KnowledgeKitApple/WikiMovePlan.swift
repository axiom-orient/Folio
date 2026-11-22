import Foundation
import FolioKnowledge

struct WikiMovePlan: Sendable {
  struct Patch: Sendable { let path: String; let before: Data; let after: Data }
  let from: String
  let to: String
  let source: WikiFileTree
  let inventory: WikiFileTree
  let patches: [Patch]
  let documentMoves: [WikiDocumentMove]

  init(root: URL, from raw: String, to destination: String) throws {
    let sourcePath = try WikiFilePaths.notes(raw)
    let destinationPath = try WikiFilePaths.notes(destination)
    from = sourcePath; to = destinationPath
    guard from != to,
      !WikiFilePaths.aliasKey(to).hasPrefix(WikiFilePaths.aliasKey(from) + "/") else {
      throw WikiError.invalidPath("An item cannot move into itself or a path alias.")
    }
    try CoordinatedFiles.requireMoveDestination(root: root, from: from, to: to)
    inventory = try WikiFileTree.snapshot(root: root, path: "notes")
    source = try inventory.subtree(from)
    if !source.isDirectory {
      guard URL(fileURLWithPath: from).pathExtension.lowercased() == URL(fileURLWithPath: to).pathExtension.lowercased() else {
        throw WikiError.invalidPath("Moving a document must preserve its file extension.")
      }
    }
    var documents: [(String, Data, WikiDocument)] = []
    for (relative, bytes) in inventory.bytes {
      let path = "notes/" + relative
      guard ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
        !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
      do { documents.append((path, bytes, try WikiMarkdownParser.document(relativePath: path, bytes: bytes))) }
      catch {
        throw WikiError.unavailable("Repair invalid Markdown metadata before moving source: " + path)
      }
    }
    let pathIDs = Dictionary(uniqueKeysWithValues: documents.compactMap { path, _, doc -> (String, String)? in
      let new = WikiFilePaths.moved(path, from: sourcePath, to: destinationPath)
      return new != path && doc.stableID == nil ? (doc.id, "path:" + new.precomposedStringWithCanonicalMapping) : nil
    })
    guard !documents.contains(where: { $0.2.declarations.contains { $0.origin == .frontmatter && pathIDs[$0.target] != nil } }) else {
      throw WikiError.unavailable("Assign explicit stable IDs before moving a path-ID note used by frontmatter relations.")
    }
    var updates: [Patch] = []; var moves: [WikiDocumentMove] = []
    for (path, bytes, document) in documents.sorted(by: { $0.0 < $1.0 }) {
      let newPath = WikiFilePaths.moved(path, from: from, to: to)
      let changed = try WikiRelativeLinkPlan.rewrite(bytes: bytes, document: document, newPath: newPath, from: from, to: to)
      guard changed.count <= 256 * 1024 else { throw WikiError.invalidSource("Rewritten Markdown exceeds 256 KiB.") }
      let resulting = try WikiMarkdownParser.document(relativePath: newPath, bytes: changed)
      guard resulting.stableID == document.stableID else { throw WikiError.changedSource }
      if changed != bytes { updates.append(Patch(path: path, before: bytes, after: changed)) }
      if newPath != path { moves.append(WikiDocumentMove(oldPath: path, newPath: newPath, oldID: document.id, newID: resulting.id)) }
    }
    patches = updates; documentMoves = moves
  }
}
