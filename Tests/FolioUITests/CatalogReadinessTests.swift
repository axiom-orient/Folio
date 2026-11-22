import Foundation
import FolioKnowledgeApple
import Testing
@testable import FolioUI

@Test @MainActor func catalogReadinessFailureClearsOnlyAfterItsOwnSuccessfulReload() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolioCatalog-" + UUID().uuidString)
  let source = root.appendingPathComponent("Source")
  defer { try? FileManager.default.removeItem(at: root) }
  try WikiWorkspace.create(at: source, name: "Catalog")
  let workspace = try WikiWorkspace(root: source, localStateDirectory: root.appendingPathComponent("State"))
  let catalog = FolioDocumentLibrary()
  let context = FolioDocumentContext(root: source, generation: 1)
  try await catalog.reload(workspace: workspace, context: context)
  #expect(catalog.loadProblem == nil)
  let outside = root.appendingPathComponent("outside.md")
  try Data("# Outside\n".utf8).write(to: outside)
  let link = source.appendingPathComponent("notes/foreign.md")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
  await #expect(throws: (any Error).self) { try await catalog.reload(workspace: workspace, context: context) }
  #expect(catalog.loadProblem != nil)
  #expect(catalog.phase == .ready)
  #expect(catalog.entries.isEmpty)
  try FileManager.default.removeItem(at: link)
  try await catalog.reload(workspace: workspace, context: context)
  #expect(catalog.loadProblem == nil)
  await workspace.close()
}
