#if os(macOS)
import CoreGraphics
import CoreText
import Foundation
import FolioKnowledge
@testable import FolioKnowledgeApple
import Testing
@testable import FolioUI

@Suite @MainActor struct KnowledgeNoteTests {
@Test func pdfImportRetryUsesCopiedOriginalAndCompletedLink() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let incoming = fixture.base.appending(path: "book #1(100%).pdf")
    let bytes = try fixture.pdf("Source evidence must keep the original.")
    try bytes.write(to: incoming)
    let target = try #require(model.receivedFileTarget)
    // Model a completed source write followed by interrupted presentation.
    #expect(!(await model.fileIntake.capture(incoming, expectedTarget: target, didLink: { _, _ in false })))
    #expect(model.fileIntake.hasPendingCapture(incoming))
    try FileManager.default.removeItem(at: incoming)
    let window = WikiWindowState()
    let changedStaging = fixture.base.appending(path: "missing-staging/book #1(100%).pdf")
    let imported = await model.importSource(changedStaging, in: window, expectedTarget: target, sourceIdentity: incoming)
    #expect(imported, Comment(rawValue: model.message ?? "PDF retry failed"))
    #expect(!model.fileIntake.hasPendingCapture(incoming))
    let attachments = try FileManager.default.contentsOfDirectory(at: fixture.root.appending(path: "attachments"), includingPropertiesForKeys: nil)
    #expect(attachments.count == 1)
    let attachment = try #require(attachments.first)
    #expect(try Data(contentsOf: attachment) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "notes").path).count == 1)
    let workspace = try #require(model.workspace)
    #expect(try await workspace.knowledgeInventory().sources.contains { $0.kind == .pdf })
  } catch { await model.close(); throw error }
  await model.close()
}

@Test func knowledgeSaveRechecksSourcesAndObservesPendingPublicationWithoutDuplicating() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let incoming = fixture.base.appending(path: "book.md")
    let original = Data("# 한국어 원문\n\n광합성은 빛 에너지를 화학 에너지로 바꾼다.\n".utf8)
    try original.write(to: incoming)
    let window = WikiWindowState()
    #expect(await model.importSource(incoming, in: window))
    let workspace = try #require(model.workspace)
    let source = try #require(try await workspace.knowledgeInventory().sources.first { $0.kind == .markdown })
    let admittedOriginal = try await workspace.source(relativePath: source.relativePath)
    let evidence = try #require(try await workspace.knowledgeBlocks(for: source).evidence.first { $0.text.contains("광합성") })
    let answer = WikiKnowledgeAnswer(question: "광합성은 무엇인가? '원문'", evidence: [evidence],
      coverage: WikiKnowledgeCoverage(sourceCount: 1, blockCount: 1, unreadablePages: 0, complete: true, semanticComplete: false), semanticUsed: false)
    #expect(await model.saveKnowledgeAnswer(answer, in: window))
    #expect(!window.isEditing)
    let note = try #require(model.snapshot?.documents.first { $0.id == window.selectedDocumentID })
    let saved = try await workspace.source(relativePath: note.relativePath)
    let savedText = String(decoding: saved, as: UTF8.self)
    #expect(try WikiMarkdownParser.isDerivedKnowledgeNote(bytes: saved))
    #expect(savedText.contains("folio_knowledge_provenance:") && savedText.contains("atomicSnapshot"))
    let body = try #require(savedText.range(of: "\n---\n\n")).upperBound
    #expect(!savedText[body...].contains(evidence.id))
    #expect(savedText[body...].contains("광합성") && savedText[body...].contains("행"))
    #expect(try await workspace.source(relativePath: source.relativePath) == admittedOriginal)
    #expect(try Data(contentsOf: incoming) == original)
    #expect(try await workspace.knowledgeInventory().sources.allSatisfy { $0.documentID != note.id })

    let sourceURL = fixture.root.appending(path: source.relativePath)
    try (admittedOriginal + Data("\n원문 변경\n".utf8)).write(to: sourceURL)
    #expect(!(await model.saveKnowledgeAnswer(answer, in: window)))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "notes").path).count == 2)

    // Retrying an already published historical note must observe its original
    // operation, even when the cited source changed after the first Save.
    let content = try FolioKnowledgeNote.content(answer, sourceCheckStartedAt: Date(), sourceCheckFinishedAt: Date())
    let id = UUID().uuidString.lowercased()
    let plan = try await workspace.prepareEdit(relativePath: "notes/" + id + ".md", expectedRevision: nil, range: nil,
      replacement: FolioInput.documentSource(id: id, title: content.title, body: content.body, additionalFrontmatter: content.frontmatter), operationID: UUID())
    let submitted = FolioSubmittedDocument(id: id, plan: plan, sourceRoot: workspace.root)
    let key = FolioKnowledgeSaves.Key(root: workspace.root, workspaceID: workspace.workspaceID,
      recoveryScope: try #require(model.draftStore.recoveryScopeURL), question: answer.question, evidence: answer.evidence)
    model.knowledgeSaves.submissions[key] = submitted
    _ = try await workspace.execute(plan)
    let receipts = await workspace.receiptDirectory
    try FileManager.default.removeItem(at: receipts.appending(path: plan.operationID.uuidString + ".json"))
    #expect(await model.saveKnowledgeAnswer(answer, in: window))
    #expect(window.selectedDocumentID == id && !window.isEditing)
    #expect(model.knowledgeSaves.submissions[key] == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "notes").path).count == 3)
  } catch { await model.close(); throw error }
  await model.close()
}

@Test func knowledgeWriterRejectsPDFChangedAfterPreparingSave() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let incoming = fixture.base.appending(path: "book.pdf")
    try fixture.pdf("Evidence from the original book.").write(to: incoming)
    let imported = await model.importSource(incoming, in: WikiWindowState())
    #expect(imported, Comment(rawValue: model.message ?? "PDF import failed"))
    let workspace = try #require(model.workspace)
    let source = try #require(try await workspace.knowledgeInventory().sources.first { $0.kind == .pdf })
    let evidence = try #require(try await workspace.knowledgeBlocks(for: source).evidence.first)
    let id = UUID().uuidString.lowercased()
    let path = "notes/" + id + ".md"
    let operationID = UUID()
    let draft = FolioInput.documentSource(id: id, title: "근거 노트", body: evidence.text,
      additionalFrontmatter: "folio_knowledge_note: true\n")
    let plan = try await workspace.prepareEdit(relativePath: path, expectedRevision: nil, range: nil,
      replacement: draft, operationID: operationID)

    // The original attachment changes while its Markdown owner and the new
    // note's prepared plan remain identical.
    let replacement = try fixture.pdf("The book was replaced after checking the evidence.")
    let original = fixture.root.appending(path: source.relativePath)
    try replacement.write(to: original)
    await #expect(throws: WikiError.changedSource) { try await workspace.executeKnowledgeNote(plan, evidence: [evidence]) }
    #expect(try await workspace.operationStatus(operationID).state == .notObserved)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: path).path))
    #expect(try Data(contentsOf: original) == replacement)
  } catch { await model.close(); throw error }
  await model.close()
}

@Test func savedCitationOpensTheRecordedPDFPageAndRejectsAReplacement() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let incoming = fixture.base.appending(path: "Source #2.pdf")
    let original = try fixture.pdf("Evidence on the second page.", firstPage: "Cover page.")
    try original.write(to: incoming)
    let window = WikiWindowState()
    #expect(await model.importSource(incoming, in: window))
    let workspace = try #require(model.workspace)
    let source = try #require(try await workspace.knowledgeInventory().sources.first { $0.kind == .pdf })
    let material = try await workspace.knowledgeBlocks(for: source)
    let evidence = try #require(material.evidence.first { $0.text.contains("second page") })
    let answer = WikiKnowledgeAnswer(question: "Which page contains the evidence?", evidence: [evidence],
      coverage: .init(sourceCount: 1, blockCount: 2, unreadablePages: 0, complete: true, semanticComplete: false),
      semanticUsed: false)
    #expect(await model.saveKnowledgeAnswer(answer, in: window))
    let note = try #require(model.snapshot?.documents.first { $0.id == window.selectedDocumentID })
    let link = try #require(note.declarations.first { $0.target.hasSuffix("#page=2") }?.target)
    await model.openMarkdownLink(link, from: note, in: window)
    let preview = try #require(window.savedPDF?.preview)
    #expect(preview.pageIndex == 1)
    #expect(preview.data == original)
    #expect(window.selectedDocumentID == note.id)
    window.savedPDF = nil

    let replacement = try fixture.pdf("A replacement without that quotation.", firstPage: "Cover page.")
    try replacement.write(to: fixture.root.appending(path: source.relativePath))
    await model.openMarkdownLink(link, from: note, in: window)
    #expect(window.savedPDF == nil)
    #expect(model.previewURL == nil)
    #expect(model.message?.contains("인용 위치") == true)
    #expect(window.selectedDocumentID == note.id)
  } catch { await model.close(); throw error }
  await model.close()
}
}

@MainActor private struct KnowledgeNoteFixture {
  let base: URL
  let root: URL
  let model: WikiAppModel
  let defaults: UserDefaults
  let defaultsName: String
  init() async throws {
    base = FileManager.default.temporaryDirectory.appending(path: "FolioKnowledgeNote-" + UUID().uuidString)
    root = base.appending(path: "Source")
    defaultsName = "FolioKnowledgeNote-" + UUID().uuidString
    defaults = try #require(UserDefaults(suiteName: defaultsName))
    try WikiWorkspace.create(at: root, name: "Knowledge note")
    let storage = FolioStorageAccess()
    let state = base.appending(path: "State")
    let session = FolioWorkspaceSession(defaults: defaults, storageAccess: storage, stateRoot: { state }, applyIndex: { _ in })
    let model = WikiAppModel(session: session, storageAccess: storage, history: FolioLibraryHistory(defaults: defaults),
      nearbyEnabled: false, migrateLegacyStorage: false)
    self.model = model
    let repository = FolioDraftRepository(url: base.appending(path: "drafts.json"))
    let location = WikiWorkspaceLocation.externalMac(bookmark: try WikiWorkspaceAccess.bookmark(for: root))
    _ = try await session.open(location, preserveNavigation: false, willReplace: {}, didLoad: { _ in
      try model.draftStore.bind(repository)
    })
  }
  func cleanup() {
    defaults.removePersistentDomain(forName: defaultsName)
    try? FileManager.default.removeItem(at: base)
  }
  func pdf(_ text: String, firstPage: String? = nil) throws -> Data {
    let storage = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: storage))
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
    let pages = firstPage.map { [$0, text] } ?? [text]
    for page in pages {
      context.beginPDFPage(nil)
      context.textMatrix = .identity; context.textPosition = CGPoint(x: 72, y: 700)
      let line = NSAttributedString(string: page, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil)
      ])
      CTLineDraw(CTLineCreateWithAttributedString(line as CFAttributedString), context)
      context.endPDFPage()
    }
    context.closePDF()
    return storage as Data
  }
}
#endif
