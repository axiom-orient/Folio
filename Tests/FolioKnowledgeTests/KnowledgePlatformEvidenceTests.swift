import CoreGraphics
import CoreText
import Foundation
import Testing
import FolioKnowledge
import FolioKnowledgeApple

@Suite struct KnowledgePlatformEvidenceTests {
  @Test func pdfQuotesReextractOriginalPageAndRejectForgedCacheOrChangedSource() async throws {
    let fixture = try EvidenceFixture(); defer { fixture.remove() }
    let original = try fixture.pdf("광합성은 빛 에너지를 화학 에너지로 바꾼다.")
    try original.write(to: fixture.root.appendingPathComponent("attachments/book.pdf"))
    let inventory = try await fixture.workspace.knowledgeInventory()
    let source = try #require(inventory.sources.first { $0.kind == .pdf })
    let material = try await fixture.workspace.knowledgeBlocks(for: source)
    #expect(material.unreadablePages == 1)
    let quote = try #require(material.evidence.first)
    #expect(quote.text.contains("광합성"))
    #expect(try await fixture.workspace.readKnowledgeEvidence(quote) == quote.text)
    let preview = try await fixture.workspace.previewKnowledgePDF(quote)
    #expect(preview.data == original && preview.pageIndex == 0)
    #expect(preview.bounds.allSatisfy { $0.isNormalized })
    let owner = try #require(inventory.sources.first { $0.kind == .markdown })
    let ownerQuote = try #require(try await fixture.workspace.knowledgeBlocks(for: owner).evidence.first)
    let batched = try await fixture.workspace.readKnowledgeEvidence([quote, ownerQuote, quote])
    #expect(batched == [quote.text, ownerQuote.text, quote.text])
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace)
    let answer = try await engine.answer("광합성")
    #expect(answer.evidence.contains { $0.source.kind == .pdf && $0.text.contains("광합성") })
    #expect(!answer.coverage.complete && answer.coverage.unreadablePages == 1)
    #expect(try await engine.answer("열역학전도율").evidence.isEmpty)
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("attachments/book.pdf")) == original)
    let forged = WikiKnowledgeEvidence(id: quote.id, text: "원본에는 없는 임의의 정답", source: quote.source, location: quote.location)
    await #expect(throws: WikiError.self) { try await fixture.workspace.readKnowledgeEvidence(forged) }
    try fixture.pdf("현재 원본의 내용은 달라졌다.").write(to: fixture.root.appendingPathComponent("attachments/book.pdf"))
    await #expect(throws: WikiError.self) { try await fixture.workspace.readKnowledgeEvidence(quote) }
    #expect(try await fixture.workspace.knowledgeInventory().fingerprint != inventory.fingerprint)
  }

  @Test func markdownEvidenceUsesExactUTF8AndInclusiveLineLocations() async throws {
    let fixture = try EvidenceFixture(); defer { fixture.remove() }
    let original = Data("---\r\nid: book\r\n---\r\n# 첫 장\r\ncafe\u{301}\r\n# 다음 장\r\n가나다\r\n".utf8)
    try original.write(to: fixture.root.appendingPathComponent("notes/book.md"))
    let source = try #require(try await fixture.workspace.knowledgeInventory().sources.first)
    let material = try await fixture.workspace.knowledgeBlocks(for: source)
    let quote = try #require(material.evidence.first)
    guard case .markdown(_, let range) = quote.location else {
      Issue.record("Expected Markdown evidence")
      return
    }
    #expect(range.startLine == 4 && range.endLine == 5)
    #expect(try range.extract(from: original) == Data(quote.text.utf8))
    let normalized = quote.text.precomposedStringWithCanonicalMapping
    #expect(normalized == quote.text && !normalized.utf8.elementsEqual(quote.text.utf8))
    let altered = WikiKnowledgeEvidence(id: quote.id, text: normalized, source: source, location: quote.location)
    await #expect(throws: WikiError.changedSource) { try await fixture.workspace.readKnowledgeEvidence(altered) }
  }

  @Test func markdownQuotesRetainOriginalBytesAndOwnerLinkRemovalRevokesPDFEvidence() async throws {
    let fixture = try EvidenceFixture(); defer { fixture.remove() }
    try fixture.pdf("A citation must come from the current original.").write(to: fixture.root.appendingPathComponent("attachments/book.pdf"))
    let inventory = try await fixture.workspace.knowledgeInventory()
    let markdown = try #require(inventory.sources.first { $0.kind == .markdown })
    let markdownBlocks = try await fixture.workspace.knowledgeBlocks(for: markdown)
    #expect(!markdownBlocks.evidence.isEmpty)
    #expect(markdownBlocks.evidence.contains { $0.text.contains("\r\n") })
    for quote in markdownBlocks.evidence {
      #expect(try await fixture.workspace.readKnowledgeEvidence(quote) == quote.text)
    }
    let pdf = try #require(inventory.sources.first { $0.kind == .pdf })
    let quote = try #require(try await fixture.workspace.knowledgeBlocks(for: pdf).evidence.first)
    try Data("---\nid: book\ntitle: 책\n---\n# 책\n원본 링크를 제거했습니다.\n".utf8)
      .write(to: fixture.root.appendingPathComponent("notes/book.md"))
    await #expect(throws: WikiError.self) { try await fixture.workspace.previewKnowledgePDF(quote) }
    #expect(try await fixture.workspace.knowledgeInventory().sources.allSatisfy { $0.kind != .pdf })
  }

  @Test func workspacePathAndClosedAdmissionCannotBeBypassedWithCachedEvidence() async throws {
    let fixture = try EvidenceFixture(); defer { fixture.remove() }
    try fixture.pdf("Private source quotation.").write(to: fixture.root.appendingPathComponent("attachments/book.pdf"))
    let source = try #require(try await fixture.workspace.knowledgeInventory().sources.first { $0.kind == .pdf })
    let quote = try #require(try await fixture.workspace.knowledgeBlocks(for: source).evidence.first)
    let clone = fixture.directory.appendingPathComponent("clone")
    try FileManager.default.copyItem(at: fixture.root, to: clone)
    let other = try WikiWorkspace(root: clone, localStateDirectory: fixture.directory.appendingPathComponent("other-state"))
    await #expect(throws: WikiError.self) { try await other.readKnowledgeEvidence(quote) }
    let otherAccount = try WikiWorkspace(root: fixture.root, localStateDirectory: fixture.directory.appendingPathComponent("state"),
      knowledgeAccountScope: UUID())
    await #expect(throws: WikiError.changedSource) { try await otherAccount.readKnowledgeEvidence(quote) }
    await fixture.workspace.close()
    await #expect(throws: WikiError.self) { try await fixture.workspace.readKnowledgeEvidence(quote) }
    await #expect(throws: WikiError.self) { try await fixture.workspace.knowledgeInventory() }
  }

  @Test func savedKnowledgeNotesRemainReadableDocumentsWithoutBecomingPrimaryEvidence() async throws {
    let fixture = try EvidenceFixture(); defer { fixture.remove() }
    try fixture.pdf("Original book evidence.").write(to: fixture.root.appendingPathComponent("attachments/book.pdf"))
    let path = "notes/derived.md"
    let derived = Data("---\nid: derived\nfolio_knowledge_note: true\n---\n# 근거 노트\n파생전용단어 원문에서 인용한 기록입니다.\n".utf8)
    try derived.write(to: fixture.root.appendingPathComponent(path))
    #expect(try await fixture.workspace.refresh().documents.contains { $0.id == "derived" })
    let inventory = try await fixture.workspace.knowledgeInventory()
    #expect(inventory.sources.allSatisfy { $0.documentID != "derived" })
    let scopeID = try #require(inventory.sources.first?.scopeID)
    let revision = SourceDigest.sha256(derived)
    let id = SourceDigest.sha256(try JSONEncoder().encode([scopeID, "derived", path, "markdown"]))
    let candidate = WikiKnowledgeSource(id: id, scopeID: scopeID, title: "근거 노트", relativePath: path,
      documentID: "derived", documentPath: path, documentRevision: revision, revision: revision, kind: .markdown)
    await #expect(throws: WikiError.changedSource) { try await fixture.workspace.knowledgeBlocks(for: candidate) }
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace)
    #expect(try await engine.answer("파생전용단어").evidence.isEmpty)
    #expect(try await fixture.workspace.source(relativePath: path) == derived)
  }

  @Test func generatedPDFCompanionDoesNotSupplyFilenameEvidence() async throws {
    let fixture = try EvidenceFixture(); defer { fixture.remove() }
    let id = "f9ae61c9-70db-4762-a0e4-afddb47b0a12"
    let filename = "filenameonly.pdf"
    let path = "attachments/\(id)-\(filename)"
    let noteURL = fixture.root.appendingPathComponent("notes/book.md")
    let pdfURL = fixture.root.appendingPathComponent(path)
    let original = try fixture.pdf("Photosynthesis converts energy.")
    try original.write(to: pdfURL)
    let companion = WikiAttachmentImport.noteSource(id: id, filename: filename, link: "../" + path)
    try Data(companion.utf8).write(to: noteURL)

    let engine = WikiKnowledgeQuery(workspace: fixture.workspace)
    let inventory = try await fixture.workspace.knowledgeInventory()
    #expect(inventory.sources.map(\.kind) == [.pdf])
    #expect(try await engine.answer("filenameonly", documentID: id).evidence.isEmpty)
    #expect(try await engine.answer("Photosynthesis", documentID: id).evidence.map(\.source.kind) == [.pdf])
    #expect(try Data(contentsOf: pdfURL) == original)

    try FileManager.default.removeItem(at: pdfURL)
    let missing = try await engine.answer("filenameonly", documentID: id)
    #expect(missing.evidence.isEmpty && !missing.coverage.complete)

    try Data((companion + "\n사용자주석은 자료를 읽은 뒤 작성했습니다.\n").utf8).write(to: noteURL)
    #expect(try await engine.answer("사용자주석은", documentID: id).evidence.map(\.source.kind) == [.markdown])
  }
}

private struct EvidenceFixture {
  let directory: URL
  let root: URL
  let workspace: WikiWorkspace
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioEvidence-" + UUID().uuidString)
    root = directory.appendingPathComponent("source")
    try WikiWorkspace.create(at: root, name: "근거 테스트")
    try Data("---\nid: book\ntitle: 책\n---\n# 책\n한국어 원문과 공백을 보존합니다.\n\n[원본](../attachments/book.pdf)\n".replacingOccurrences(of: "\n", with: "\r\n").utf8)
      .write(to: root.appendingPathComponent("notes/book.md"))
    workspace = try WikiWorkspace(root: root, localStateDirectory: directory.appendingPathComponent("state"))
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
  func pdf(_ text: String) throws -> Data {
    let storage = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: storage))
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
    context.beginPDFPage(nil)
    context.textMatrix = .identity; context.textPosition = CGPoint(x: 72, y: 700)
    let string = NSAttributedString(string: text, attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    ])
    CTLineDraw(CTLineCreateWithAttributedString(string as CFAttributedString), context)
    context.endPDFPage()
    context.beginPDFPage(nil); context.endPDFPage()
    context.closePDF()
    return storage as Data
  }
}
