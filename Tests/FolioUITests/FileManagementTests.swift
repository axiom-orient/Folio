import Foundation
import FolioKnowledge
@testable import FolioKnowledgeApple
import Markdown
import Testing

@Test func movingANotePreservesIdentityAndRebasesIncomingAndOutgoingRelativeLinks() async throws {
  try await withFileManagementFixture { fixture in
    let source = """
      ---
      id: alpha
      ---
      # Alpha
      [Peer](b.md#peer)
      ![Picture](../attachments/picture%20one.png)
      [Self](#alpha)
      [External](https://example.com/a.md)
      `[literal](b.md)`
      ```markdown
      [literal](b.md)
      ```

      """
    try fixture.write(source, path: "notes/a.md")
    try fixture.write("---\nid: beta\n---\n# Peer\n", path: "notes/b.md")
    try fixture.write("---\nid: incoming\n---\n# Incoming\n[Back](../a.md#alpha)\n", path: "notes/other/from.md")
    let picture = Data([0, 1, 2, 255])
    try fixture.write(picture, path: "attachments/picture one.png")
    _ = try await fixture.workspace.performFileOperation(.createFolder(path: "notes/deep"))
    let revision = try await fixture.entry("notes/a.md").revision

    let change = try await fixture.workspace.performFileOperation(
      .move(path: "notes/a.md", to: "notes/deep/renamed.md"), expectedRevision: revision)
    let snapshot = try await fixture.workspace.refresh()
    let moved = try #require(snapshot.documents.first { $0.id == "alpha" })
    let incoming = try #require(snapshot.documents.first { $0.id == "incoming" })
    #expect(moved.relativePath == "notes/deep/renamed.md")
    #expect(!fixture.exists("notes/a.md"))
    #expect(change.documentMoves.contains {
      $0.oldPath == "notes/a.md" && $0.newPath == moved.relativePath && $0.oldID == "alpha" && $0.newID == "alpha"
    })
    #expect(resolvedFileManagementLinks(moved).contains("notes/b.md"))
    #expect(resolvedFileManagementLinks(moved).contains("attachments/picture one.png"))
    #expect(resolvedFileManagementLinks(moved).contains(moved.relativePath))
    #expect(resolvedFileManagementLinks(incoming).contains(moved.relativePath))
    #expect(moved.declarations.contains { $0.target.hasSuffix("#peer") })
    #expect(incoming.declarations.contains { $0.target.hasSuffix("#alpha") })
    let text = try fixture.text(moved.relativePath)
    #expect(text.contains("`[literal](b.md)`"))
    #expect(text.contains("```markdown\n[literal](b.md)\n```"))
    #expect(text.contains("https://example.com/a.md"))
    #expect(try fixture.bytes("attachments/picture one.png") == picture)
    #expect(snapshot.relations.contains { $0.sourceID == "incoming" && $0.targetID == "alpha" && $0.status == .valid })
  }
}

@Test func documentTrashRestoreAndPurgePreserveAttachmentsAndRemoveSearchResults() async throws {
  try await withFileManagementFixture { fixture in
    _ = try await fixture.workspace.performFileOperation(.createFolder(path: "notes/Managed"))
    let source = "---\nid: managed-note\n---\n# Managed\nUniqueTrashSearchToken\n[Attachment](../../attachments/shared.pdf)\n"
    _ = try await fixture.workspace.performFileOperation(.createDocument(path: "notes/Managed/created.md", text: source))
    let attachment = Data("Original PDF attachment bytes".utf8)
    try fixture.write(attachment, path: "attachments/shared.pdf")
    let revision = try await fixture.entry("notes/Managed/created.md").revision
    let removed = try await fixture.workspace.performFileOperation(.trash(path: "notes/Managed/created.md"), expectedRevision: revision)
    let trashID = try #require(removed.trashID)
    let trash = try #require(try await fixture.workspace.trashEntries().first { $0.id == trashID })
    #expect(trash.originalPath == "notes/Managed/created.md")
    #expect(trash.isAvailable)
    #expect(!fixture.exists("notes/Managed/created.md"))
    #expect(try fixture.bytes("attachments/shared.pdf") == attachment)
    let afterTrash = try await fixture.workspace.refresh()
    #expect(!afterTrash.documents.contains { $0.id == "managed-note" })
    #expect(!afterTrash.staleDocuments.contains { $0.id == "managed-note" })
    #expect(try await fixture.workspace.projection.search("UniqueTrashSearchToken").hits.isEmpty)
    #expect(try await fixture.workspace.libraryEntries().allSatisfy { $0.relativePath != trash.originalPath })

    let restored = try await fixture.workspace.performFileOperation(.restore(id: trashID), expectedRevision: trash.revision)
    #expect(try fixture.text("notes/Managed/created.md") == source)
    #expect(restored.documentMoves.contains { $0.newPath == "notes/Managed/created.md" && $0.newID == "managed-note" })
    #expect(try await fixture.workspace.trashEntries().allSatisfy { $0.id != trashID })
    let refreshed = try await fixture.workspace.refresh()
    #expect(refreshed.documents.contains { $0.id == "managed-note" })

    let secondRevision = try await fixture.entry("notes/Managed/created.md").revision
    let secondTrash = try await fixture.workspace.performFileOperation(.trash(path: "notes/Managed/created.md"), expectedRevision: secondRevision)
    let secondID = try #require(secondTrash.trashID)
    let secondEntry = try #require(try await fixture.workspace.trashEntries().first { $0.id == secondID })
    _ = try await fixture.workspace.performFileOperation(.purge(id: secondID), expectedRevision: secondEntry.revision)
    #expect(try await fixture.workspace.trashEntries().allSatisfy { $0.id != secondID })
    #expect(!fixture.exists("notes/Managed/created.md"))
    #expect(try fixture.bytes("attachments/shared.pdf") == attachment)
  }
}

@Test func movingALegacyPathIdentifiedNoteReturnsItsNewIdentity() async throws {
  try await withFileManagementFixture { fixture in
    let source = "# Legacy path identity\nOriginal body\n"
    try fixture.write(source, path: "notes/legacy.md")
    let revision = try await fixture.entry("notes/legacy.md").revision
    let change = try await fixture.workspace.performFileOperation(
      .move(path: "notes/legacy.md", to: "notes/renamed.md"), expectedRevision: revision)
    let snapshot = try await fixture.workspace.refresh()
    let document = try #require(snapshot.documents.first { $0.relativePath == "notes/renamed.md" })
    #expect(document.id == "path:notes/renamed.md")
    #expect(document.stableID == nil)
    #expect(change.documentMoves.contains {
      $0.oldID == "path:notes/legacy.md" && $0.newID == document.id && $0.oldPath == "notes/legacy.md" && $0.newPath == document.relativePath
    })
    #expect(try fixture.text(document.relativePath) == source)
  }
}

@Test func movingAReferenceLinkTargetPreservesItsLabelTitleAndOriginalDefinition() async throws {
  try await withFileManagementFixture { fixture in
    let original = "---\nid: target\n---\n# Target\n"
    let incoming = "---\nid: incoming\n---\n# Incoming\n[Reference][target]\n\n[target]: a.md \"Original link title\"\n"
    try fixture.write(original, path: "notes/a.md")
    try fixture.write(incoming, path: "notes/incoming.md")
    let revision = try await fixture.entry("notes/a.md").revision
    _ = try await fixture.workspace.performFileOperation(.move(path: "notes/a.md", to: "notes/renamed.md"), expectedRevision: revision)
    #expect(!fixture.exists("notes/a.md"))
    #expect(try fixture.text("notes/renamed.md") == original)
    let rewritten = try fixture.text("notes/incoming.md")
    let link = try #require(fileManagementMarkdownLinks(rewritten).first { $0.plainText == "Reference" })
    #expect(link.title == "Original link title")
    let destination = try #require(link.destination)
    #expect(WikiPath.resolveLink(destination, from: "notes/incoming.md") == "notes/renamed.md")
    #expect(rewritten.contains("[target]: a.md \"Original link title\""))
    #expect(try await fixture.workspace.trashEntries().isEmpty)
  }
}

@Test func caseOnlyFilenameChangesPreserveBytesAndUseTheRequestedDirectoryEntryName() async throws {
  try await withFileManagementFixture { fixture in
    let source = "---\nid: case-note\n---\n# Case note\nOriginal source bytes\n"
    try fixture.write(source, path: "notes/note.md")
    let revision = try await fixture.entry("notes/note.md").revision
    let change = try await fixture.workspace.performFileOperation(
      .move(path: "notes/note.md", to: "notes/Note.md"), expectedRevision: revision)
    // fileExists(oldPath) remains true on a case-insensitive volume. Read the
    // actual directory entry to distinguish a rename from an unchanged alias.
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.url("notes").path)
    #expect(names.contains("Note.md"))
    #expect(!names.contains("note.md"))
    #expect(try fixture.text("notes/Note.md") == source)
    let snapshot = try await fixture.workspace.refresh()
    let document = try #require(snapshot.documents.first { $0.id == "case-note" })
    #expect(document.relativePath == "notes/Note.md")
    #expect(document.stableID == "case-note")
    #expect(change.documentMoves.contains {
      $0.oldPath == "notes/note.md" && $0.newPath == "notes/Note.md" && $0.oldID == "case-note" && $0.newID == "case-note"
    })
  }
}

@Test func aCommittedMoveRemovesPrivateRollbackSourceCopiesAndRetainsItsReceipt() async throws {
  try await withFileManagementFixture { fixture in
    let sourceMarker = "OriginalSourceMustNotRemainInRollbackAfterSuccess"
    let backlinkMarker = "BacklinkSourceMustNotRemainInRollbackAfterSuccess"
    let source = "---\nid: moved\n---\n# Moved\n\(sourceMarker)\n"
    try fixture.write(source, path: "notes/a.md")
    try fixture.write("---\nid: incoming\n---\n# Incoming\n\(backlinkMarker)\n[Back](a.md)\n", path: "notes/incoming.md")
    let operationID = UUID()
    let revision = try await fixture.entry("notes/a.md").revision
    let operation = WikiFileOperation.move(path: "notes/a.md", to: "notes/renamed.md")
    let change = try await fixture.workspace.performFileOperation(operation, expectedRevision: revision, operationID: operationID)
    #expect(!fixture.exists("notes/a.md"))
    #expect(try fixture.text("notes/renamed.md") == source)
    let snapshot = try await fixture.workspace.refresh()
    let incoming = try #require(snapshot.documents.first { $0.id == "incoming" })
    #expect(resolvedFileManagementLinks(incoming).contains("notes/renamed.md"))
    #expect(try fixture.text("notes/incoming.md").contains(backlinkMarker))
    #expect(change.operationID == operationID)

    let receiptDirectory = await fixture.workspace.receiptDirectory
    let journal = receiptDirectory.appendingPathComponent("FileManagement", isDirectory: true)
    let rollback = journal.appendingPathComponent(operationID.uuidString + "-rollback", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: rollback.path))
    let receipt = journal.appendingPathComponent(operationID.uuidString + ".json")
    let receiptBytes = try Data(contentsOf: receipt)
    #expect(receiptBytes.count < 65_536)
    let artifacts = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: [.isRegularFileKey])
    for artifact in artifacts {
      #expect(try artifact.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
      let bytes = try Data(contentsOf: artifact)
      #expect(bytes.count < 65_536)
      let text = String(decoding: bytes, as: UTF8.self)
      #expect(!text.contains(sourceMarker))
      #expect(!text.contains(backlinkMarker))
    }
    let replay = try await fixture.workspace.performFileOperation(operation, expectedRevision: revision, operationID: operationID)
    #expect(replay.operationID == operationID)
    #expect(!FileManager.default.fileExists(atPath: rollback.path))
    #expect(try fixture.text("notes/renamed.md") == source)
  }
}

@Test func sourceMoveAndTrashRestoreNeverReplaceAnArrivingDestination() async throws {
  try await withFileManagementFixture { fixture in
    let original = "---\nid: original\n---\n# Original\n"
    let occupied = "---\nid: occupied\n---\n# Occupied\n"
    try fixture.write(original, path: "notes/a.md")
    try fixture.write(occupied, path: "notes/occupied.md")
    let revision = try await fixture.entry("notes/a.md").revision
    await #expect(throws: (any Error).self) {
      try await fixture.workspace.performFileOperation(.move(path: "notes/a.md", to: "notes/occupied.md"), expectedRevision: revision)
    }
    #expect(try fixture.text("notes/a.md") == original)
    #expect(try fixture.text("notes/occupied.md") == occupied)

    let deleted = try await fixture.workspace.performFileOperation(.trash(path: "notes/a.md"), expectedRevision: revision)
    let id = try #require(deleted.trashID)
    let entry = try #require(try await fixture.workspace.trashEntries().first { $0.id == id })
    try fixture.write(occupied, path: "notes/a.md")
    await #expect(throws: (any Error).self) {
      try await fixture.workspace.performFileOperation(.restore(id: id), expectedRevision: entry.revision)
    }
    #expect(try fixture.text("notes/a.md") == occupied)
    #expect(try await fixture.workspace.trashEntries().contains { $0.id == id })
    try FileManager.default.removeItem(at: fixture.url("notes/a.md"))
    _ = try await fixture.workspace.performFileOperation(.restore(id: id), expectedRevision: entry.revision)
    #expect(try fixture.text("notes/a.md") == original)
  }
}

@Test(arguments: ["bytes", "new-file", "empty-folder"])
func folderRevisionsRejectExternalChangesBeforeMoving(change: String) async throws {
  try await withFileManagementFixture { fixture in
    try fixture.write("---\nid: original\n---\n# Original\n", path: "notes/Folder/a.md")
    try fixture.write("Original non-Markdown payload", path: "notes/Folder/payload.txt")
    let revision = try await fixture.entry("notes/Folder").revision
    switch change {
    case "bytes": try fixture.write("A later external payload", path: "notes/Folder/payload.txt")
    case "new-file": try fixture.write("An arriving file", path: "notes/Folder/arriving.txt")
    default: try FileManager.default.createDirectory(at: fixture.url("notes/Folder/Empty"), withIntermediateDirectories: false)
    }
    await #expect(throws: (any Error).self) {
      try await fixture.workspace.performFileOperation(.move(path: "notes/Folder", to: "notes/Moved"), expectedRevision: revision)
    }
    #expect(fixture.exists("notes/Folder/a.md"))
    #expect(!fixture.exists("notes/Moved"))
    if change == "bytes" { #expect(try fixture.text("notes/Folder/payload.txt") == "A later external payload") }
    if change == "new-file" { #expect(try fixture.text("notes/Folder/arriving.txt") == "An arriving file") }
    if change == "empty-folder" { #expect(fixture.exists("notes/Folder/Empty")) }
  }
}

@Test(arguments: ["../escape.md", "notes/../escape.md", "_workspace.md", "attachments/replaced.md", "absolute-outside"])
func fileManagementRejectsPathsOutsideTheNotesOwner(destination: String) async throws {
  try await withFileManagementFixture { fixture in
    let source = "---\nid: original\n---\n# Original\n"
    try fixture.write(source, path: "notes/a.md")
    let marker = try fixture.bytes("_workspace.md")
    let revision = try await fixture.entry("notes/a.md").revision
    let target = destination == "absolute-outside" ? fixture.base.appendingPathComponent("escape.md").path : destination
    await #expect(throws: (any Error).self) {
      try await fixture.workspace.performFileOperation(.move(path: "notes/a.md", to: target), expectedRevision: revision)
    }
    #expect(try fixture.text("notes/a.md") == source)
    #expect(try fixture.bytes("_workspace.md") == marker)
    #expect(!fixture.exists("escape.md"))
    #expect(!FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("escape.md").path))
    #expect(!fixture.exists("attachments/replaced.md"))
  }
}

@Test func folderMoveTrashAndRestorePreserveEveryChildAndExternalBacklinks() async throws {
  try await withFileManagementFixture { fixture in
    let first = "---\nid: first-child\n---\n# First child\n[Second](Sub/b.md)\n"
    let second = "---\nid: second-child\n---\n# Second child\n[First](../a.md)\n"
    let hidden = Data([0, 255, 13, 10])
    try fixture.write(first, path: "notes/Folder/a.md")
    try fixture.write(second, path: "notes/Folder/Sub/b.md")
    try fixture.write("Non-Markdown child", path: "notes/Folder/payload.txt")
    try fixture.write(hidden, path: "notes/Folder/.private.bin")
    try FileManager.default.createDirectory(at: fixture.url("notes/Folder/Empty/Nested"), withIntermediateDirectories: true)
    try fixture.write("---\nid: external-backlink\n---\n# Index\n[First](Folder/a.md#first-child)\n", path: "notes/index.md")
    let originalRevision = try await fixture.entry("notes/Folder").revision

    let moved = try await fixture.workspace.performFileOperation(.move(path: "notes/Folder", to: "notes/Renamed"), expectedRevision: originalRevision)
    #expect(!fixture.exists("notes/Folder"))
    #expect(try fixture.text("notes/Renamed/a.md") == first)
    #expect(try fixture.text("notes/Renamed/Sub/b.md") == second)
    #expect(try fixture.text("notes/Renamed/payload.txt") == "Non-Markdown child")
    #expect(try fixture.bytes("notes/Renamed/.private.bin") == hidden)
    #expect(fixture.exists("notes/Renamed/Empty/Nested"))
    #expect(Set(moved.documentMoves.map(\.newID)) == ["first-child", "second-child"])
    let snapshot = try await fixture.workspace.refresh()
    let incoming = try #require(snapshot.documents.first { $0.id == "external-backlink" })
    #expect(resolvedFileManagementLinks(incoming).contains("notes/Renamed/a.md"))

    let movedRevision = try await fixture.entry("notes/Renamed").revision
    let removal = try await fixture.workspace.performFileOperation(.trash(path: "notes/Renamed"), expectedRevision: movedRevision)
    let id = try #require(removal.trashID)
    let trash = try #require(try await fixture.workspace.trashEntries().first { $0.id == id })
    #expect(trash.isDirectory)
    #expect(trash.isAvailable)
    #expect(!fixture.exists("notes/Renamed"))
    #expect(try await fixture.workspace.refresh().documents.allSatisfy { !["first-child", "second-child"].contains($0.id) })
    _ = try await fixture.workspace.performFileOperation(.restore(id: id), expectedRevision: trash.revision)
    #expect(try fixture.text("notes/Renamed/a.md") == first)
    #expect(try fixture.text("notes/Renamed/Sub/b.md") == second)
    #expect(try fixture.text("notes/Renamed/payload.txt") == "Non-Markdown child")
    #expect(try fixture.bytes("notes/Renamed/.private.bin") == hidden)
    #expect(try fixture.url("notes/Renamed/Empty/Nested").resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    #expect(try await fixture.workspace.trashEntries().allSatisfy { $0.id != id })
  }
}

@Test func fileManagementDoesNotTraverseSymlinkParents() async throws {
  try await withFileManagementFixture { fixture in
    let original = "---\nid: original\n---\n# Original\n"
    try fixture.write(original, path: "notes/a.md")
    let outside = fixture.base.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let sentinel = outside.appendingPathComponent("keep.txt")
    try Data("Keep outside data".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(at: fixture.url("notes/linked"), withDestinationURL: outside)
    await #expect(throws: (any Error).self) {
      try await fixture.workspace.performFileOperation(.move(path: "notes/a.md", to: "notes/linked/moved.md"))
    }
    #expect(try fixture.text("notes/a.md") == original)
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("moved.md").path))
    #expect(try Data(contentsOf: sentinel) == Data("Keep outside data".utf8))
  }
}

@Test func emptyFoldersAndVisibleNotesAfterHiddenFilesSurviveSourceZIPRoundTrip() async throws {
  try await withFileManagementFixture { fixture in
    try fixture.write("Hidden local file", path: "notes/.skip")
    let source = "---\nid: visible\n---\n# Visible source\n"
    try fixture.write(source, path: "notes/Subfolder/visible.md")
    try fixture.write("---\nid: trashed\n---\n# Private trash content\n", path: "notes/removed.md")
    let removedRevision = try await fixture.entry("notes/removed.md").revision
    _ = try await fixture.workspace.performFileOperation(.trash(path: "notes/removed.md"), expectedRevision: removedRevision)
    _ = try await fixture.workspace.performFileOperation(.createFolder(path: "notes/Empty"))
    _ = try await fixture.workspace.performFileOperation(.createFolder(path: "notes/Empty/Nested"))
    let entries = try await fixture.workspace.libraryEntries()
    #expect(entries.contains { $0.relativePath == "notes/Subfolder/visible.md" && !$0.isDirectory })
    #expect(entries.contains { $0.relativePath == "notes/Empty/Nested" && $0.isDirectory })
    #expect(try await fixture.workspace.refresh().documents.contains { $0.id == "visible" })

    let archive = try await fixture.workspace.exportSourceArchive()
    defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
    let restored = fixture.base.appendingPathComponent("Restored", isDirectory: true)
    try WikiWorkspaceAccess.unpackSourceArchive(at: archive, to: restored)
    #expect(try restored.appendingPathComponent("notes/Empty/Nested").resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    #expect(try Data(contentsOf: restored.appendingPathComponent("notes/Subfolder/visible.md")) == Data(source.utf8))
    #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("notes/.skip").path))
    #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("notes/removed.md").path))
    #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent(".folio-trash").path))
  }
}

@Test func capturedEvidenceAndMarkdownExportsCannotReadAnUnrelatedReplacementAfterMove() async throws {
  try await withFileManagementFixture { fixture in
    try fixture.write("---\nid: original\n---\n# Original\nOriginal evidence\n", path: "notes/a.md")
    let snapshot = try await fixture.workspace.refresh()
    let original = try #require(snapshot.documents.first { $0.id == "original" })
    let section = try #require(original.sections.first)
    let evidence = WikiEvidenceReference(workspaceID: fixture.workspace.workspaceID, document: original, section: section)
    _ = try await fixture.workspace.performFileOperation(.move(path: original.relativePath, to: "notes/moved.md"), expectedRevision: original.revision)
    try fixture.write("---\nid: unrelated\n---\n# Unrelated\nDifferent evidence\n", path: "notes/a.md")
    await #expect(throws: (any Error).self) { try await fixture.workspace.read(evidence) }
    await #expect(throws: (any Error).self) {
      try await fixture.workspace.exportMarkdown(relativePath: original.relativePath, expectedRevision: original.revision)
    }
  }
}

@Test func malformedTrashMetadataDoesNotHideValidTrashOrLibraryEntries() async throws {
  try await withFileManagementFixture { fixture in
    try fixture.write("---\nid: recoverable\n---\n# Recoverable\n", path: "notes/recoverable.md")
    try fixture.write("---\nid: still-visible\n---\n# Still visible\n", path: "notes/visible.md")
    let revision = try await fixture.entry("notes/recoverable.md").revision
    let deletion = try await fixture.workspace.performFileOperation(.trash(path: "notes/recoverable.md"), expectedRevision: revision)
    let validID = try #require(deletion.trashID)
    let validRecord = ".folio-trash/" + validID.uuidString.lowercased() + "/record.json"
    let validBytes = try fixture.bytes(validRecord)
    let corruptID = UUID()
    let corruptRecord = ".folio-trash/" + corruptID.uuidString.lowercased() + "/record.json"
    let corruptBytes = Data("{ invalid JSON must remain available for inspection".utf8)
    let finderBytes = Data([0, 1, 2, 255])
    let unrelatedBytes = Data("Unrecognized content is preserved".utf8)
    try fixture.write(corruptBytes, path: corruptRecord)
    try fixture.write(finderBytes, path: ".folio-trash/.DS_Store")
    try fixture.write(unrelatedBytes, path: ".folio-trash/unrecognized-item.txt")

    let trash = try await fixture.workspace.trashEntries()
    #expect(trash.contains { $0.id == validID && $0.isAvailable })
    let unavailable = try #require(trash.first { $0.id == corruptID })
    #expect(!unavailable.isAvailable)
    #expect(unavailable.revision.isEmpty)
    #expect(unavailable.diagnostic?.isEmpty == false)
    #expect(try await fixture.workspace.libraryEntries().contains { $0.relativePath == "notes/visible.md" })
    #expect(try fixture.bytes(validRecord) == validBytes)
    #expect(try fixture.bytes(corruptRecord) == corruptBytes)
    #expect(try fixture.bytes(".folio-trash/.DS_Store") == finderBytes)
    #expect(try fixture.bytes(".folio-trash/unrecognized-item.txt") == unrelatedBytes)
  }
}

private func resolvedFileManagementLinks(_ document: WikiDocument) -> Set<String> {
  Set(document.declarations.compactMap { declaration in
    guard declaration.origin == .markdownLink else { return nil }
    return WikiPath.resolveLink(declaration.target, from: document.relativePath)
  })
}

private func fileManagementMarkdownLinks(_ text: String) -> [Markdown.Link] {
  var pending: [any Markup] = [Markdown.Document(parsing: text)]
  var result: [Markdown.Link] = []
  while let node = pending.popLast() {
    if let link = node as? Markdown.Link { result.append(link) }
    pending.append(contentsOf: node.children)
  }
  return result
}

private func withFileManagementFixture(_ operation: (FileManagementFixture) async throws -> Void) async throws {
  let fixture = try FileManagementFixture()
  do { try await operation(fixture) }
  catch {
    await fixture.workspace.close()
    fixture.cleanup()
    throw error
  }
  await fixture.workspace.close()
  fixture.cleanup()
}

private struct FileManagementFixture: Sendable {
  let base: URL
  let workspace: WikiWorkspace
  var root: URL { workspace.root }

  init() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioFileManagement-" + UUID().uuidString, isDirectory: true)
    let source = base.appendingPathComponent("Source", isDirectory: true)
    try WikiWorkspace.create(at: source, name: "Isolated file management")
    workspace = try WikiWorkspace(root: source, localStateDirectory: base.appendingPathComponent("DerivedState", isDirectory: true))
  }

  func url(_ path: String) -> URL { root.appendingPathComponent(path) }
  func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }
  func bytes(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }
  func text(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }
  func write(_ text: String, path: String) throws { try write(Data(text.utf8), path: path) }
  func write(_ bytes: Data, path: String) throws {
    let target = url(path)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: target)
  }
  func entry(_ path: String) async throws -> WikiLibraryEntry {
    try #require(try await workspace.libraryEntries().first { $0.relativePath == path })
  }
  func cleanup() { try? FileManager.default.removeItem(at: base) }
}
