#if os(macOS)
import CoreGraphics
import CoreText
import Foundation
import FolioKnowledge
@testable import FolioKnowledgeApple
import PDFKit
import Testing
@testable import FolioUI

@Suite @MainActor struct KnowledgeNoteTests {
@Test func pdfImportRetryUsesCopiedOriginalAndCompletedLink() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let filename = "book: #1(100%).pdf"
    let incoming = fixture.base.appending(path: filename)
    let bytes = try fixture.pdf("Source evidence must keep the original.")
    try bytes.write(to: incoming)
    let target = try #require(model.receivedFileTarget)
    // Model a completed source write followed by interrupted presentation.
    #expect(!(await model.fileIntake.capture(incoming, expectedTarget: target, didLink: { _, _ in false })))
    #expect(model.fileIntake.hasPendingCapture(incoming))
    try FileManager.default.removeItem(at: incoming)
    let window = WikiWindowState()
    let changedStaging = fixture.base.appending(path: "missing-staging").appending(path: filename)
    let imported = await model.importSource(changedStaging, in: window, expectedTarget: target, sourceIdentity: incoming)
    #expect(imported, Comment(rawValue: model.message ?? "PDF retry failed"))
    #expect(!model.fileIntake.hasPendingCapture(incoming))
    let attachments = try FileManager.default.contentsOfDirectory(at: fixture.root.appending(path: "attachments"), includingPropertiesForKeys: nil)
    #expect(attachments.count == 1)
    let attachment = try #require(attachments.first)
    #expect(try Data(contentsOf: attachment) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "notes").path).count == 1)
    let workspace = try #require(model.workspace)
    let source = try #require(try await workspace.knowledgeInventory().sources.first { $0.kind == .pdf })
    #expect(source.relativePath == "attachments/" + attachment.lastPathComponent)
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
    let incoming = fixture.base.appending(path: "Source: #2.pdf")
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
    #expect(link.contains("%3A"))
    await model.openMarkdownLink(link, from: note, in: window)
    let saved = try #require(window.savedCitation)
    guard case .pdf(let preview) = saved.content else { throw WikiError.invalidSource("Expected a saved PDF preview.") }
    #expect(preview.pageIndex == 1)
    #expect(preview.data == original)
    #expect(window.selectedDocumentID == note.id)
    window.savedCitation = nil

    let replacement = try fixture.pdf("A replacement without that quotation.", firstPage: "Cover page.")
    try replacement.write(to: fixture.root.appending(path: source.relativePath))
    await model.openMarkdownLink(link, from: note, in: window)
    #expect(window.savedCitation == nil)
    #expect(model.previewURL == nil)
    #expect(model.message?.contains("인용 위치") == true)
    #expect(window.selectedDocumentID == note.id)
  } catch { await model.close(); throw error }
  await model.close()
}

@Test func savedMarkdownCitationReopensItsVerifiedSectionAndRejectsSourceChanges() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let incoming = fixture.base.appending(path: "field notes.md")
    try Data("# 관찰 기록\n\n## 첫 구획\n\n도입부.\n\n## 둘째 구획\n\n목표는 환승 대기시간이다.\n".utf8).write(to: incoming)
    let window = WikiWindowState()
    #expect(await model.importSource(incoming, in: window))
    let workspace = try #require(model.workspace)
    let source = try #require(try await workspace.knowledgeInventory().sources.first { $0.kind == .markdown })
    let material = try await workspace.knowledgeBlocks(for: source)
    let evidence = try #require(material.evidence.first { $0.text.contains("환승 대기시간") })
    let reference = try #require(evidence.markdownReference)
    let answer = WikiKnowledgeAnswer(question: "무엇을 관찰했나요?", evidence: [evidence],
      coverage: .init(sourceCount: 1, blockCount: material.evidence.count, unreadablePages: 0, complete: true,
        semanticComplete: false), semanticUsed: false)
    #expect(await model.saveKnowledgeAnswer(answer, in: window))
    let note = try #require(model.snapshot?.documents.first { $0.id == window.selectedDocumentID })
    let link = try #require(note.declarations.first { $0.target.contains("#folio-quote=") }?.target)
    let legacyLink = String(link.prefix(while: { $0 != "#" }))

    for citation in [link, legacyLink] {
      await model.openMarkdownLink(citation, from: note, in: window)
      let saved = try #require(window.savedCitation)
      guard case .markdown(let preview, let sectionID, let location) = saved.content else {
        throw WikiError.invalidSource("Expected a saved Markdown preview.")
      }
      #expect(preview.revision == source.revision && preview.id == source.documentID)
      #expect(sectionID == reference.sectionID && location == evidence.displayLocation)
      #expect(window.selectedDocumentID == note.id)
      window.savedCitation = nil
    }

    let original = try await workspace.source(relativePath: source.relativePath)
    let replacement = original + Data("\n판본이 변경됨.\n".utf8)
    try replacement.write(to: fixture.root.appending(path: source.relativePath))
    await model.refresh()
    #expect(model.snapshot?.documents.first { $0.id == source.documentID }?.revision == SourceDigest.sha256(replacement))
    await model.openMarkdownLink(link, from: note, in: window)
    #expect(window.savedCitation == nil && window.selectedDocumentID == note.id)
    #expect(model.message?.contains("인용 위치") == true)
  } catch { await model.close(); throw error }
  await model.close()
}

@Test func savedPDFRegionLinksDistinguishTwoFormulasOnTheSamePage() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let incoming = fixture.base.appending(path: "Equations.pdf")
    let original = try fixture.pdf("F = mass * acceleration", nextLine: "P = energy / time")
    try original.write(to: incoming)
    let window = WikiWindowState()
    #expect(await model.importSource(incoming, in: window))
    let workspace = try #require(model.workspace)
    let source = try #require(try await workspace.knowledgeInventory().sources.first { $0.kind == .pdf })
    let material = try await workspace.knowledgeBlocks(for: source)
    let force = try #require(material.evidence.first { $0.pdfRegion != nil && $0.text.contains("acceleration") })
    let power = try #require(material.evidence.first { $0.pdfRegion != nil && $0.text.contains("energy") })
    #expect(force.id != power.id)
    let answer = WikiKnowledgeAnswer(question: "Compare the two formulas", evidence: [force, power],
      coverage: .init(sourceCount: 1, blockCount: 2, unreadablePages: 0, complete: true, semanticComplete: false),
      semanticUsed: false)
    #expect(await model.saveKnowledgeAnswer(answer, in: window))
    let note = try #require(model.snapshot?.documents.first { $0.id == window.selectedDocumentID })
    let concept = WikiKnowledgeConcept(id: "mechanics-formulas", domain: "역학",
      labels: [.init(language: "ko", preferred: "역학 공식", aliases: ["mechanics formulas"])],
      mentions: [.init(evidence: force), .init(evidence: power)])
    let plan = try await workspace.prepareKnowledgeConcept(concept, operationID: UUID())
    _ = try await workspace.executeKnowledgeConcept(plan)
    let assertion = WikiKnowledgeAssertion(id: "force-assertion", statement: .init(text: force.text,
      citations: [.init(evidenceID: force.id, quote: force.text)]), evidence: [.init(evidence: force), .init(evidence: power, role: .context)])
    #expect(await model.saveKnowledgeAssertion(assertion))
    await model.refresh()
    let conceptNote = try #require(model.snapshot?.documents.first { $0.id == concept.id })
    let assertionNote = try #require(model.snapshot?.documents.first { $0.id == assertion.id })
    var observedBounds: [[WikiPDFBounds]] = []
    for saved in [note, conceptNote, assertionNote] {
      window.selectedDocumentID = saved.id
      await model.loadSelection(window)
      for evidence in [force, power] {
        let link = try #require(saved.declarations.first { $0.target.hasSuffix("#page=1&folio-quote=" + evidence.id) }?.target)
        await model.openMarkdownLink(link, from: saved, in: window)
        let citation = try #require(window.savedCitation)
        guard case .pdf(let preview) = citation.content else { throw WikiError.changedSource }
        #expect(preview.pageIndex == 0 && preview.data == original && !preview.bounds.isEmpty)
        observedBounds.append(preview.bounds)
        window.savedCitation = nil
      }
    }
    #expect(observedBounds[0] != observedBounds[1])
    #expect(observedBounds[0] == observedBounds[2] && observedBounds[1] == observedBounds[3])
    #expect(observedBounds[0] == observedBounds[4] && observedBounds[1] == observedBounds[5])
    #expect(try Data(contentsOf: fixture.root.appending(path: source.relativePath)) == original)
  } catch { await model.close(); throw error }
  await model.close()
}

@Test func mixedPDFKeepsNativeTextAndReopensItsImageTableAndFormula() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let (original, crop) = try fixture.mixedPDF()
    let page = try #require(PDFDocument(data: original)?.page(at: 0))
    #expect(page.bounds(for: .cropBox) == crop)
    let images = try WikiPDFImageRegions.regions(in: page)
    #expect(!images.incomplete && images.regions.count == 3)
    #expect(images.regions.allSatisfy { $0.height < crop.height / 4 && crop.contains($0) })
    let baseline = try #require(WikiPDFExtractor.extract(original).first)
    #expect(baseline.text.contains("geology") && baseline.text.contains("CONTROL LABEL"))
    #expect(!baseline.text.contains("COBALT") && !baseline.text.contains("ENERGY"))

    let incoming = fixture.base.appending(path: "Mixed.pdf")
    try original.write(to: incoming)
    let window = WikiWindowState()
    #expect(await model.importSource(incoming, in: window))
    let workspace = try #require(model.workspace)
    let engine = WikiKnowledgeQuery(workspace: workspace)
    let results = try await engine.answer("geology control cobalt energy companion")
    #expect(results.evidence.contains { $0.pdfRegion?.kind != .ocrUnreviewed && $0.text.contains("geology") })
    let controls = results.evidence.filter { $0.text.localizedCaseInsensitiveContains("control") }
    #expect(controls.count == 1 && controls.allSatisfy { $0.pdfRegion?.kind != .ocrUnreviewed })
    let table = try #require(results.evidence.first {
      $0.pdfRegion?.kind == .ocrUnreviewed && $0.text.localizedCaseInsensitiveContains("cobalt")
    })
    let formula = try #require(results.evidence.first {
      $0.pdfRegion?.kind == .ocrUnreviewed && $0.text.localizedCaseInsensitiveContains("energy")
    })
    #expect(!table.text.localizedCaseInsensitiveContains("silver"))
    #expect(formula.text.localizedCaseInsensitiveContains("time"))
    #expect(results.evidence.contains { $0.pdfRegion?.kind == .ocrUnreviewed && $0.text.contains("COMPANION") })
    let imageIndex = try #require(table.pdfRegion?.imageIndex)
    #expect(formula.pdfRegion?.imageIndex != nil && formula.pdfRegion?.imageIndex != imageIndex)

    let answer = WikiKnowledgeAnswer(question: "Find cobalt and the energy formula", evidence: [table, formula],
      coverage: results.coverage, semanticUsed: false)
    let saved = await model.saveKnowledgeAnswer(answer, in: window)
    #expect(saved, Comment(rawValue: model.message ?? "Could not save OCR evidence"))
    let note = try #require(model.snapshot?.documents.first { $0.id == window.selectedDocumentID })
    let concept = WikiKnowledgeConcept(id: "mixed-source-record", labels: [
      .init(language: "ko", preferred: "실험 기록", aliases: ["experimental record"])
    ], mentions: [.init(evidence: table), .init(evidence: formula)])
    let plan = try await workspace.prepareKnowledgeConcept(concept, operationID: UUID())
    _ = try await workspace.executeKnowledgeConcept(plan)
    let assertion = WikiKnowledgeAssertion(id: "ocr-assertion", statement: .init(text: table.text,
      citations: [.init(evidenceID: table.id, quote: table.text)]), evidence: [.init(evidence: table), .init(evidence: formula, role: .context)])
    #expect(await model.saveKnowledgeAssertion(assertion))
    await model.refresh()
    let conceptNote = try #require(model.snapshot?.documents.first { $0.id == concept.id })
    let assertionNote = try #require(model.snapshot?.documents.first { $0.id == assertion.id })
    var openedRegions: [[WikiPDFBounds]] = []
    for savedNote in [note, conceptNote, assertionNote] {
      window.selectedDocumentID = savedNote.id
      await model.loadSelection(window)
      for (evidence, position) in [(table, CGPoint(x: 102, y: 442)), (formula, CGPoint(x: 150, y: 264))] {
        let live = try await workspace.previewKnowledgePDF(evidence)
        #expect(live.pageIndex == 0 && live.usesOCR && live.data == original)
        let link = try #require(savedNote.declarations.first { $0.target.hasSuffix("#page=1&folio-quote=" + evidence.id) }?.target)
        await model.openMarkdownLink(link, from: savedNote, in: window)
        let citation = try #require(window.savedCitation)
        guard case .pdf(let preview) = citation.content else { throw WikiError.changedSource }
        #expect(preview.pageIndex == 0 && preview.usesOCR && preview.data == original && preview.bounds == live.bounds)
        let expectedX = Double((position.x - crop.minX) / crop.width)
        let expectedY = Double((position.y - crop.minY) / crop.height)
        #expect(preview.bounds.contains {
          $0.isNormalized && abs($0.x - expectedX) < 0.055 && abs($0.y - expectedY) < 0.045
        })
        #expect(window.selectedDocumentID == savedNote.id)
        openedRegions.append(preview.bounds)
        window.savedCitation = nil
      }
    }
    #expect(openedRegions[0] != openedRegions[1])
    #expect(openedRegions[0] == openedRegions[2] && openedRegions[1] == openedRegions[3])
    #expect(openedRegions[0] == openedRegions[4] && openedRegions[1] == openedRegions[5])
    #expect(try Data(contentsOf: fixture.root.appending(path: table.source.relativePath)) == original)
  } catch { await model.close(); throw error }
  await model.close()
}

@Test func conceptLinkRepeatIsIdempotentAndExplicitExistingSelectionAddsAnotherQuote() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let original = Data("---\nid: thermal-source\n---\n# Heat\nThermal conductivity describes heat conduction.\n# Units\nThe stated measurement uses W/(m K).\n".utf8)
    try original.write(to: fixture.root.appending(path: "notes/thermal.md"))
    await model.refresh()
    let workspace = try #require(model.workspace)
    let source = try #require(try await workspace.knowledgeInventory().sources.first { $0.documentID == "thermal-source" })
    let evidence = try await workspace.knowledgeBlocks(for: source).evidence
    let first = try #require(evidence.first { $0.text.contains("heat conduction") })
    let second = try #require(evidence.first { $0.text.contains("measurement") })
    #expect(await model.saveKnowledgeConcept(name: "열전도율", aliases: ["thermal conductivity"], domain: "physics", evidence: first))
    let existing = try #require(try await workspace.knowledgeConceptInventory().records.first)
    #expect(await model.saveKnowledgeConcept(name: "열전도율", aliases: ["thermal conductivity"], domain: "physics", evidence: first))
    let repeated = try await workspace.knowledgeConceptInventory()
    #expect(repeated.records.count == 1 && repeated.records[0].revision == existing.revision)
    #expect(await model.saveKnowledgeConcept(name: "열전도율", aliases: ["thermal conductivity"], domain: "physics", evidence: second, existing: existing))
    let updated = try await workspace.readKnowledgeConcept(id: existing.concept.id)
    #expect(updated.concept.id == existing.concept.id && updated.relativePath == existing.relativePath)
    #expect(Set(updated.concept.mentions.map { $0.evidence.id }) == Set([first.id, second.id]))
    #expect(updated.revision != existing.revision)
    #expect(try await workspace.knowledgeConceptInventory().records.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "notes").path).count == 2)
    #expect(try Data(contentsOf: fixture.root.appending(path: "notes/thermal.md")) == original)
  } catch { await model.close(); throw error }
  await model.close()
}

@Test func assertionSaveReusesIdenticalClaimAndUpdatesItsFacetsInPlace() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let original = Data("---\nid: measurement\n---\n# Result\nThe coefficient is 42 W/(m K) at 20 °C.\n# Unit\nW/(m K)\n# Edition\nEdition 2\n".utf8)
    try original.write(to: fixture.root.appending(path: "notes/measurement.md"))
    await model.refresh()
    let workspace = try #require(model.workspace)
    let source = try #require(try await workspace.knowledgeInventory().sources.first { $0.documentID == "measurement" })
    let evidence = try await workspace.knowledgeBlocks(for: source).evidence
    let result = try #require(evidence.first { $0.text.contains("42") })
    let header = try #require(evidence.first { $0.text.hasPrefix("# Unit\n") })
    let cover = try #require(evidence.first { $0.text.contains("Edition 2") })
    func field(_ text: String, _ quote: WikiKnowledgeEvidence) -> WikiKnowledgeAssertionText {
      .init(text: text, citations: [.init(evidenceID: quote.id, quote: quote.text)])
    }
    func assertion(_ id: String, conditions: [WikiKnowledgeAssertionText] = []) -> WikiKnowledgeAssertion {
      .init(id: id, statement: field("The coefficient is 42 W/(m K) at 20 °C.", result), conditions: conditions,
        value: field("42", result), unit: field("W/(m K)", header), edition: field("Edition 2", cover),
        evidence: [.init(evidence: result), .init(evidence: header, role: .context), .init(evidence: cover, role: .context)])
    }
    #expect(await model.saveKnowledgeAssertion(assertion("coefficient")))
    let first = try await workspace.readKnowledgeAssertion(id: "coefficient")
    #expect(await model.saveKnowledgeAssertion(assertion("new-ui-identity")))
    #expect(try await workspace.knowledgeAssertionInventory().records.count == 1)
    #expect(try await workspace.readKnowledgeAssertion(id: "coefficient").revision == first.revision)
    #expect(await model.saveKnowledgeAssertion(assertion("coefficient", conditions: [field("20 °C", result)]), existing: first))
    let updated = try await workspace.readKnowledgeAssertion(id: "coefficient")
    #expect(updated.relativePath == first.relativePath && updated.revision != first.revision)
    let unitField = try #require(updated.assertion.unit)
    let unitEvidence = try #require(try updated.assertion.sourceEvidence(for: unitField).first)
    let selection = try await FolioKnowledgeSourceSelection.load(unitEvidence, in: workspace)
    guard case .markdown(let document, let sectionID, _) = selection.content else { throw WikiError.changedSource }
    #expect(document.revision == source.revision && sectionID == header.markdownReference?.sectionID)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "notes").path).count == 2)
    #expect(try Data(contentsOf: fixture.root.appending(path: source.relativePath)) == original)
  } catch { await model.close(); throw error }
  await model.close()
}

@Test func assertionDuplicateLookupChecksContentBeforePaginationAndFailsClosedOnUnreadableRecords() async throws {
  let fixture = try await KnowledgeNoteFixture()
  defer { fixture.cleanup() }
  let model = fixture.model
  do {
    let statement = "This original statement retains every qualifying phrase so that a caller can review the exact same content without relying on a truncated search prefix."
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    let cases = (0..<102).map { "C" + String(alphabet[$0 / 26]) + String(alphabet[$0 % 26]) }
    let original = Data(("---\nid: duplicate-source\n---\n# Measurements\n" + statement + "\n"
      + cases.joined(separator: "\n") + "\n").utf8)
    try original.write(to: fixture.root.appending(path: "notes/duplicate-source.md"))
    await model.refresh()
    let workspace = try #require(model.workspace)
    let source = try #require(try await workspace.knowledgeInventory().sources.first { $0.documentID == "duplicate-source" })
    let evidence = try #require(try await workspace.knowledgeBlocks(for: source).evidence.first { $0.text.contains(cases[101]) })
    func assertion(_ id: String, index: Int) -> WikiKnowledgeAssertion {
      func field(_ text: String) -> WikiKnowledgeAssertionText {
        .init(text: text, citations: [.init(evidenceID: evidence.id, quote: evidence.text)])
      }
      return .init(id: id, statement: field(statement), conditions: [field(cases[index])], evidence: [.init(evidence: evidence)])
    }
    // One prepared rendering supplies 101 valid, distinct source records. The fixture
    // does not execute 101 approvals merely to exercise the duplicate lookup boundary.
    let template = assertion("claim-template", index: 0)
    let plan = try await workspace.prepareKnowledgeAssertion(template, operationID: UUID())
    let envelope = try #require(try WikiOntologyRecord.read(bytes: plan.replacementBytes))
    for index in 0..<101 {
      let id = String(format: "claim-%03d", index)
      let value = assertion(id, index: index)
      var fields = envelope.fields
      let typed = try #require(try WikiJSONValue.parse(JSONEncoder().encode(value)).objectValue)
      for (key, entry) in typed { fields[key] = entry }
      let renamedTemplate = plan.after
        .replacingOccurrences(of: "\nid: \"claim-template\"\n", with: "\nid: \"" + id + "\"\n")
      let bytes = try WikiOntologyRecord.replacingRecord(in: Data(renamedTemplate.utf8), with: WikiOntologyRecord(fields: fields))
      let text = String(decoding: bytes, as: UTF8.self)
        .replacingOccurrences(of: "- " + cases[0] + "\n", with: "- " + cases[index] + "\n")
      try Data(text.utf8).write(to: fixture.root.appending(path: "notes/" + id + ".md"))
    }
    await model.refresh()
    let limited = try await workspace.knowledgeAssertionInventory(query: String(statement.prefix(120)), limit: 100)
    #expect(!limited.complete && limited.records.count == 100)
    #expect(!limited.records.contains { $0.assertion.id == "claim-100" })
    let repeated = assertion("new-ui-identity", index: 100)
    #expect(try repeated.contentDigest() == assertion("claim-100", index: 100).contentDigest())
    #expect(await model.saveKnowledgeAssertion(repeated))
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "notes/new-ui-identity.md").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "notes").path).count == 102)
    let distinct = assertion("distinct-claim", index: 101)
    #expect(await model.saveKnowledgeAssertion(distinct))
    #expect(try await workspace.readKnowledgeAssertion(id: distinct.id).assertion == distinct)
    let unreadable = fixture.root.appending(path: "notes/claim-000.md")
    let bytes = try Data(contentsOf: unreadable)
    try Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "## 주장", with: "## Changed claim body").utf8).write(to: unreadable)
    let unavailable = WikiKnowledgeAssertion(id: "unreadable-check", statement: distinct.statement,
      polarity: .affirmed, conditions: distinct.conditions, evidence: distinct.evidence)
    #expect(!(await model.saveKnowledgeAssertion(unavailable)))
    #expect(model.message?.contains("중복 여부") == true)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "notes/unreadable-check.md").path))
    #expect(try Data(contentsOf: fixture.root.appending(path: source.relativePath)) == original)
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
  func pdf(_ text: String, firstPage: String? = nil, nextLine: String? = nil) throws -> Data {
    let storage = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: storage))
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
    let pages = firstPage.map { [$0, text] } ?? [text]
    for (index, page) in pages.enumerated() {
      context.beginPDFPage(nil)
      let lines = index == pages.count - 1 ? [page, nextLine].compactMap { $0 } : [page]
      for (lineIndex, text) in lines.enumerated() {
        context.textMatrix = .identity; context.textPosition = CGPoint(x: 72, y: 700 - lineIndex * 38)
        let line = NSAttributedString(string: text, attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        ])
        CTLineDraw(CTLineCreateWithAttributedString(line as CFAttributedString), context)
      }
      context.endPDFPage()
    }
    context.closePDF()
    return storage as Data
  }

  func mixedPDF() throws -> (Data, CGRect) {
    func draw(_ text: String, into context: CGContext, x: CGFloat, y: CGFloat, scale: CGFloat = 1) {
      let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 24 * scale, nil)
      let line = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
      ])
      context.textMatrix = .identity
      context.textPosition = CGPoint(x: x * scale, y: y * scale)
      CTLineDraw(CTLineCreateWithAttributedString(line as CFAttributedString), context)
    }
    func drawImage(in context: CGContext, at area: CGRect, text: [(String, CGFloat, CGFloat)]) throws {
      let raster = try #require(CGContext(data: nil, width: Int(area.width * 2), height: Int(area.height * 2),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
      raster.setFillColor(gray: 1, alpha: 1)
      raster.fill(CGRect(x: 0, y: 0, width: area.width * 2, height: area.height * 2))
      for (label, x, y) in text { draw(label, into: raster, x: x - area.minX, y: y - area.minY, scale: 2) }
      context.draw(try #require(raster.makeImage()), in: area)
    }

    let storage = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: storage))
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    var crop = CGRect(x: 38, y: 41, width: 530, height: 700)
    let cropBytes = withUnsafeBytes(of: &crop) { Data($0) }
    let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
    context.beginPDFPage([kCGPDFContextCropBox as String: cropBytes] as CFDictionary)
    try drawImage(in: context, at: CGRect(x: 90, y: 603, width: 460, height: 52),
      text: [("CONTROL LABEL COMPANION", 100, 622)])
    var cells: [(String, CGFloat, CGFloat)] = []
    for (row, y) in zip([["ELEMENT", "MASS", "RATIO"], ["COBALT", "59", "HIGH"], ["SILVER", "108", "LOW"]],
      [480, 442, 404] as [CGFloat]) {
      for (x, label) in zip([102, 251, 405] as [CGFloat], row) { cells.append((label, x, y)) }
    }
    try drawImage(in: context, at: CGRect(x: 90, y: 391, width: 445, height: 119), text: cells)
    try drawImage(in: context, at: CGRect(x: 140, y: 250, width: 350, height: 60), text: [("P = ENERGY / TIME", 150, 264)])
    draw("The geology chapter.", into: context, x: 100, y: 690)
    context.setTextDrawingMode(.invisible)
    draw("CONTROL LABEL", into: context, x: 100, y: 622)
    context.endPDFPage()
    context.closePDF()
    return (storage as Data, crop)
  }
}
#endif
