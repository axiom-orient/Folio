import Foundation
import FolioKnowledgeApple

/// Shared temporary workspace for the existing semantic/projection suites.
/// Source and derived state stay in separate directories, matching production.
struct KnowledgeFixture: Sendable {
  let base: URL
  let root: URL
  let workspace: WikiWorkspace

  init() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioKnowledge-" + UUID().uuidString)
    root = base.appendingPathComponent("Source")
    try WikiWorkspace.create(at: root, name: "Knowledge verification")
    workspace = try WikiWorkspace(root: root, localStateDirectory: base.appendingPathComponent("State"))
  }

  func write(_ text: String, path: String) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent(path), options: .atomic)
  }

  func remove() { try? FileManager.default.removeItem(at: base) }
}
