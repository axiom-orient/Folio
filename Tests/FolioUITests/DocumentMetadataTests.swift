import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import Markdown
import Testing

@Test func metadataEditingPreservesUnknownYAMLCommentsIdentityRelationsAndCRLFBody() throws {
  let prefix = "---\r\nid: preserved-id # identity note\r\ntype: document\r\naliases: [\"Alias One\", \"별칭\"] # alias note\r\nrelations:\r\n  references: [\"peer\"] # relation note\r\n"
  let custom = "custom:\r\n  nested: \"keep: # literal\"\r\n  text: |\r\n    tags: literal inside an unknown scalar\r\n# trailing header note\r\n"
  let tail = "\r\n본문 바이트를 그대로 보존합니다. [Peer](peer.md)\r\n\r\n### Other heading\r\n`# literal code`\r\n"
  let original = Data((prefix + "tags: [old] # tag list note\r\n" + custom + "---\r\n## Original **heading**\r\n" + tail).utf8)
  let title = "새 제목 [literal] **강조 아님** # <tag>"
  let edited = try WikiMarkdownEditor.editingMetadata(bytes: original, title: title, tags: [" Swift ", "iOS"])
  let text = String(decoding: edited, as: UTF8.self)
  let document = try metadataDocument(edited)
  #expect(text.hasPrefix(prefix))
  #expect(text.contains(custom))
  #expect(text.contains("# tag list note\r\n"))
  #expect(text.contains("---\r\n## "))
  #expect(text.hasSuffix(tail))
  #expect(document.id == "preserved-id")
  #expect(document.type == "document")
  #expect(document.aliases == ["Alias One", "별칭"])
  #expect(document.tags == ["Swift", "iOS"])
  #expect(document.title == title)
  #expect(document.declarations.contains { $0.origin == .frontmatter && $0.predicate == "references" && $0.target == "peer" })
  let headings = metadataHeadings(text)
  #expect(headings.first?.level == 2)
  #expect(headings.first?.plainText == title)
  #expect(headings.dropFirst().first?.plainText == "Other heading")
}

@Test func metadataEditingSupportsFlowMappingsWithoutReemittingUnrelatedFields() throws {
  let original = "---\n{id: flow-note, aliases: [Alias], tags: [old], title: \"unknown title field\", custom: {tags: nested, note: \"a: # value\"}}\n---\n# Flow title\n\nExact body text\n"
  let edited = try WikiMarkdownEditor.editingMetadata(bytes: Data(original.utf8), title: "Changed title", tags: ["Swift", "Mac"])
  let text = String(decoding: edited, as: UTF8.self)
  let document = try metadataDocument(edited)
  #expect(text.contains("id: flow-note"))
  #expect(text.contains("aliases: [Alias]"))
  #expect(text.contains("title: \"unknown title field\""))
  #expect(text.contains("custom: {tags: nested, note: \"a: # value\"}"))
  #expect(text.hasSuffix("\n\nExact body text\n"))
  #expect(document.id == "flow-note")
  #expect(document.aliases == ["Alias"])
  #expect(document.tags == ["Swift", "Mac"])
  #expect(document.title == "Changed title")
}

@Test func blockTagEditingKeepsCommentsAndUnknownFields() throws {
  let original = "---\nid: block-note\n# Tags belong to this note\ntags:\n  - old # retain this annotation\n  - other\n# Custom field boundary\ncustom: unchanged\n---\n# Title\n\nOriginal body\n"
  let edited = try WikiMarkdownEditor.editingMetadata(bytes: Data(original.utf8), title: "Title", tags: ["New", "Swift"])
  let text = String(decoding: edited, as: UTF8.self)
  #expect(text.contains("# Tags belong to this note"))
  #expect(text.contains("# retain this annotation"))
  #expect(text.contains("# Custom field boundary\ncustom: unchanged\n"))
  #expect(text.hasSuffix("# Title\n\nOriginal body\n"))
  #expect(try metadataDocument(edited).tags == ["New", "Swift"])
}

@Test func missingScalarAndSequenceTagsHaveStableNormalizedValues() throws {
  #expect(try metadataDocument(Data("# No tags\n".utf8)).tags.isEmpty)
  #expect(try metadataDocument(Data("---\ntags: \" Swift \"\n---\n# Scalar\n".utf8)).tags == ["Swift"])
  let values = [" Swift ", "Swift", "swift", "cafe\u{301}", "café", "Straße", "STRASSE", "iOS", "IOS"]
  let bytes = try metadataSource(tags: values)
  #expect(try metadataDocument(bytes).tags == ["Swift", "café", "Straße", "iOS"])
  let maximumTag = String(repeating: "한", count: 42) + "ab"
  #expect(maximumTag.utf8.count == 128)
  #expect(try metadataDocument(metadataSource(tags: [maximumTag])).tags == [maximumTag])
  let maximumCount = (0..<64).map { "Tag\($0)" }
  #expect(try metadataDocument(metadataSource(tags: maximumCount)).tags == maximumCount)
}

@Test(arguments: ["empty", "whitespace", "control", "long-ascii", "long-unicode", "too-many-duplicates", "non-string", "mapping"])
func invalidTagValuesAreRejectedWithoutWeakeningMetadataBounds(kind: String) throws {
  let bytes: Data
  switch kind {
  case "empty": bytes = try metadataSource(tags: [""])
  case "whitespace": bytes = try metadataSource(tags: ["   "])
  case "control": bytes = try metadataSource(tags: ["Swift\u{7f}Tag"])
  case "long-ascii": bytes = try metadataSource(tags: [String(repeating: "x", count: 129)])
  case "long-unicode": bytes = try metadataSource(tags: [String(repeating: "한", count: 43)])
  case "too-many-duplicates": bytes = try metadataSource(tags: Array(repeating: "same", count: 65))
  case "non-string": bytes = Data("---\ntags: [Swift, 4]\n---\n# Invalid\n".utf8)
  default: bytes = Data("---\ntags: {key: value}\n---\n# Invalid\n".utf8)
  }
  #expect(throws: (any Error).self) { try metadataDocument(bytes) }
}

@Test(arguments: ["# 제목", "[링크 아님](file.md)", "**강조 아님**", "backslash \\ and `code`", "한국어 제목 📚"])
func literalMetadataHeadingsPreserveTheirVisibleText(_ title: String) throws {
  let heading = WikiMarkdownEditor.literalHeading(title)
  #expect(!heading.contains("\n"))
  #expect(try metadataDocument(Data((heading + "\n\nBody\n").utf8)).title == title)
}

@Test func addingMetadataAndANewHeadingPreservesTheOriginalBodyAndPathIdentity() throws {
  let body = "원래 본문입니다.\r\n\r\n[Link](other.md)\r\n"
  let edited = try WikiMarkdownEditor.editingMetadata(bytes: Data(body.utf8), title: "새 제목", tags: ["Swift"])
  let document = try metadataDocument(edited)
  #expect(document.title == "새 제목")
  #expect(document.tags == ["Swift"])
  #expect(document.stableID == nil)
  #expect(document.id == "path:notes/metadata.md")
  #expect(String(decoding: edited, as: UTF8.self).hasSuffix(body))
}

@Test func legacyDocumentsWithoutTagsDecodeWithoutLosingExistingFields() throws {
  let current = try metadataDocument(Data("---\nid: legacy-note\naliases: [Alias]\ntags: [Swift]\n---\n# Legacy\nBody\n".utf8))
  let legacy = try legacyMetadataDocument(current)
  #expect(legacy.tags.isEmpty)
  #expect(legacy.id == current.id)
  #expect(legacy.stableID == current.stableID)
  #expect(legacy.relativePath == current.relativePath)
  #expect(legacy.title == current.title)
  #expect(legacy.aliases == current.aliases)
  #expect(legacy.revision == current.revision)
  #expect(legacy.sections == current.sections)
  #expect(legacy.declarations == current.declarations)
}

@Test func unchangedSourceTagsAreReparsedFromLegacyPersistedProjectionRecords() async throws {
  try await withDocumentMetadataFixture { fixture in
    let bytes = Data("---\nid: legacy-cached\ntags: [Swift, Research]\n---\n# Cached source\nBody\n".utf8)
    try fixture.write(bytes)
    let document = try metadataDocument(bytes)
    let legacy = try legacyMetadataDocument(document)
    let identity = try WikiMarkdownParser.workspace(bytes: Data(contentsOf: fixture.root.appendingPathComponent("_workspace.md")))
    let scan = WikiScan(workspace: identity, documents: [legacy], observedPaths: ["notes/metadata.md"],
      ontology: nil, ontologyUnavailable: false, diagnostics: [], enumerationComplete: true)
    _ = try await fixture.workspace.projection.apply(scan)
    let reopened = try WikiWorkspace(root: fixture.root, localStateDirectory: fixture.state)
    do {
      let snapshot = try await reopened.refresh()
      let reparsed = try #require(snapshot.documents.first { $0.id == "legacy-cached" })
      #expect(reparsed.tags == ["Swift", "Research"])
      #expect(reparsed.revision == document.revision)
      #expect(try fixture.bytes() == bytes)
    } catch { await reopened.close(); throw error }
    await reopened.close()
  }
}

@Test func metadataSaveUsesTheExistingRevisionCheckedWriteLane() async throws {
  try await withDocumentMetadataFixture { fixture in
    let original = Data("---\nid: edited-note\naliases: [Alias]\ntags: old\ncustom: untouched # annotation\n---\n# Original\n\nBody remains\n".utf8)
    try fixture.write(original)
    let document = try metadataDocument(original)
    let plan = try await fixture.workspace.prepareMetadataEdit(relativePath: "notes/metadata.md", expectedRevision: document.revision,
      title: "Changed title", tags: ["Swift", "Research"], operationID: UUID())
    #expect(try fixture.bytes() == original)
    let receipt = try await fixture.workspace.execute(plan)
    let committed = try fixture.bytes()
    let updated = try metadataDocument(committed)
    #expect(receipt.sourceRevision == SourceDigest.sha256(committed))
    #expect(updated.id == "edited-note")
    #expect(updated.aliases == ["Alias"])
    #expect(updated.title == "Changed title")
    #expect(updated.tags == ["Swift", "Research"])
    #expect(String(decoding: committed, as: UTF8.self).contains("custom: untouched # annotation\n"))
    #expect(String(decoding: committed, as: UTF8.self).hasSuffix("\n\nBody remains\n"))
    let snapshot = try await fixture.workspace.refresh()
    #expect(snapshot.documents.first { $0.id == "edited-note" }?.tags == ["Swift", "Research"])
  }
}

@Test(arguments: ["before-preview", "after-preview"])
func metadataEditsRejectExternalChangesWithoutReplacingTheNewerSource(stage: String) async throws {
  try await withDocumentMetadataFixture { fixture in
    let original = Data("---\nid: original\ntags: [Old]\n---\n# Original\nBody\n".utf8)
    let external = original + Data("A later external edit\n".utf8)
    try fixture.write(original)
    let revision = SourceDigest.sha256(original)
    if stage == "before-preview" {
      try fixture.write(external)
      await #expect(throws: (any Error).self) {
        try await fixture.workspace.prepareMetadataEdit(relativePath: "notes/metadata.md", expectedRevision: revision,
          title: "Requested title", tags: ["New"], operationID: UUID())
      }
    } else {
      let plan = try await fixture.workspace.prepareMetadataEdit(relativePath: "notes/metadata.md", expectedRevision: revision,
        title: "Requested title", tags: ["New"], operationID: UUID())
      try fixture.write(external)
      await #expect(throws: (any Error).self) { try await fixture.workspace.execute(plan) }
    }
    #expect(try fixture.bytes() == external)
  }
}

@Test(arguments: ["atx", "setext", "no-heading"])
func changingOnlyTagsPreservesExistingHeadingFormattingAndUnheadedBody(style: String) async throws {
  try await withDocumentMetadataFixture { fixture in
    let body: String
    switch style {
    case "atx": body = "# **Title**\n\nExact body bytes\n"
    case "setext": body = "Title\n=====\n\nExact body bytes\n"
    default: body = "A body without a heading.\n\nExact body bytes\n"
    }
    let original = Data(("---\nid: tag-only\ntags: [Old]\n---\n" + body).utf8)
    try fixture.write(original)
    let current = try metadataDocument(original)
    let plan = try await fixture.workspace.prepareMetadataEdit(relativePath: "notes/metadata.md", expectedRevision: current.revision,
      title: current.title, tags: ["New"], operationID: UUID())
    _ = try await fixture.workspace.execute(plan)
    let edited = try fixture.bytes()
    #expect(String(decoding: edited, as: UTF8.self).hasSuffix(body))
    #expect(try metadataDocument(edited).title == current.title)
    #expect(try metadataDocument(edited).tags == ["New"])
  }
}

@Test func metadataEditingCannotRewriteTheWorkspaceIdentityFile() async throws {
  try await withDocumentMetadataFixture { fixture in
    let marker = fixture.root.appendingPathComponent("_workspace.md")
    let original = try Data(contentsOf: marker)
    await #expect(throws: (any Error).self) {
      try await fixture.workspace.prepareMetadataEdit(relativePath: "_workspace.md", expectedRevision: SourceDigest.sha256(original),
        title: "Not a source note", tags: ["New"], operationID: UUID())
    }
    #expect(try Data(contentsOf: marker) == original)
  }
}

private func metadataDocument(_ bytes: Data) throws -> WikiDocument {
  try WikiMarkdownParser.document(relativePath: "notes/metadata.md", bytes: bytes)
}

private func metadataSource(tags: [String]) throws -> Data {
  let encoded = try JSONEncoder().encode(tags)
  return Data(("---\nid: tags-note\ntags: " + String(decoding: encoded, as: UTF8.self) + "\n---\n# Tags\nBody\n").utf8)
}

private func legacyMetadataDocument(_ document: WikiDocument) throws -> WikiDocument {
  let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any]
  let oldKeys: Set<String> = ["id", "stableID", "relativePath", "title", "type", "aliases", "revision", "sections", "declarations"]
  let legacy = current.filter { oldKeys.contains($0.key) }
  return try JSONDecoder().decode(WikiDocument.self, from: JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]))
}

private func metadataHeadings(_ text: String) -> [Heading] {
  // Swift treats CRLF as one Character; normalize only this parsed test view so
  // a Character-based split cannot mistake frontmatter comments for headings.
  let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
    .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
  let body: String
  if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
    let closing = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) {
    body = lines.dropFirst(closing + 1).joined(separator: "\n")
  } else { body = text }
  return Markdown.Document(parsing: body).children.compactMap { $0 as? Heading }
}

private func withDocumentMetadataFixture(_ operation: (DocumentMetadataFixture) async throws -> Void) async throws {
  let fixture = try DocumentMetadataFixture()
  do { try await operation(fixture) }
  catch { await fixture.workspace.close(); fixture.cleanup(); throw error }
  await fixture.workspace.close()
  fixture.cleanup()
}

private struct DocumentMetadataFixture: Sendable {
  let base: URL
  let state: URL
  let workspace: WikiWorkspace
  var root: URL { workspace.root }
  var source: URL { root.appendingPathComponent("notes/metadata.md") }

  init() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioDocumentMetadata-" + UUID().uuidString, isDirectory: true)
    let root = base.appendingPathComponent("Source", isDirectory: true)
    state = base.appendingPathComponent("DerivedState", isDirectory: true)
    try WikiWorkspace.create(at: root, name: "Isolated document metadata")
    workspace = try WikiWorkspace(root: root, localStateDirectory: state)
  }
  func write(_ bytes: Data) throws { try bytes.write(to: source) }
  func bytes() throws -> Data { try Data(contentsOf: source) }
  func cleanup() { try? FileManager.default.removeItem(at: base) }
}
