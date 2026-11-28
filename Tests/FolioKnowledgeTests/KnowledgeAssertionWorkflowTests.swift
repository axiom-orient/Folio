import CoreGraphics
import CoreText
import Foundation
import Testing
import FolioKnowledge
@testable import FolioKnowledgeApple

@Suite struct KnowledgeAssertionWorkflowTests {
  @Test func sourcedAssertionStoresEveryFacetAndReopensItsOriginalWithoutBecomingPrimary() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let quote = try await evidence(f)
    let value = assertion(id: "coefficient", evidence: quote)
    let plan = try await f.workspace.prepareKnowledgeAssertion(value, operationID: UUID())
    let receipt = try await f.workspace.executeKnowledgeAssertion(plan)
    let saved = try await f.workspace.readKnowledgeAssertion(id: value.id)
    #expect(saved.assertion == value && saved.revision == receipt.sourceRevision)
    let preview = try await f.workspace.previewSavedKnowledgeMarkdown(notePath: saved.relativePath,
      noteRevision: saved.revision, sourcePath: quote.source.relativePath, fragment: quote.location.savedCitationFragment)
    #expect(preview?.document.id == "book" && preview?.sectionID == quote.markdownReference?.sectionID)
    #expect(try await f.workspace.knowledgeInventory().sources.allSatisfy { $0.documentID != value.id })
    #expect(try await f.workspace.knowledgeConceptInventory().diagnostics.isEmpty)
    let list = try await f.workspace.knowledgeAssertionInventory(documentID: "book", unit: "W/(m K)", edition: "Edition 2", query: "coefficient")
    #expect(list.complete && list.records.count == 1)
    #expect(try await f.workspace.knowledgeAssertionInventory(unit: "w/(m k)").records.isEmpty)
    let status = try await f.workspace.knowledgeAssertionOperationStatus(operationID: plan.operationID)
    #expect(status.operation.state == .committed && status.sourceObserved && status.currentness == .current)
    #expect(try await f.workspace.source(relativePath: "notes/book.md") == Data(source.utf8))
  }

  @Test func assertionCASPreservesUnknownMetadataAndCommentsWhileReplacingItsRenderedClaim() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let quote = try await evidence(f)
    let original = assertion(id: "coefficient", evidence: quote)
    let plan = try await f.workspace.prepareKnowledgeAssertion(original, operationID: UUID())
    _ = try await f.workspace.executeKnowledgeAssertion(plan)
    let bytes = try await f.workspace.source(relativePath: plan.relativePath)
    let metadata = try #require(try WikiOntologyRecord.read(bytes: bytes))
    var fields = metadata.fields
    fields["future"] = .object(["large": .number("123456789012345678901234567890"), "keep": .string("yes")])
    var items = try #require(fields["evidence"]?.arrayValue)
    var item = try #require(items[0].objectValue)
    var originalEvidence = try #require(item["evidence"]?.objectValue)
    originalEvidence["future"] = .string("belongs to this quotation")
    item["evidence"] = .object(originalEvidence); items[0] = .object(item); fields["evidence"] = .array(items)
    let enriched = try WikiOntologyRecord.replacingRecord(in: bytes, with: WikiOntologyRecord(fields: fields))
    let raw = String(decoding: enriched, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n") + "\r\n<!-- user comment -->\r\n"
    try f.write(raw, path: plan.relativePath)
    let expected = SourceDigest.sha256(Data(raw.utf8))
    let changed = assertion(id: original.id, evidence: quote, statement: "The coefficient is 42 W/(m K)")
    let next = try await f.workspace.prepareKnowledgeAssertion(changed, relativePath: plan.relativePath,
      expectedRevision: expected, operationID: UUID())
    _ = try await f.workspace.executeKnowledgeAssertion(next)
    let saved = try await f.workspace.source(relativePath: next.relativePath)
    let record = try #require(try WikiOntologyRecord.read(bytes: saved))
    #expect(record.fields["future"] == fields["future"])
    #expect(record.fields["evidence"]?.arrayValue?[0].objectValue?["evidence"]?.objectValue?["future"] == .string("belongs to this quotation"))
    let text = String(decoding: saved, as: UTF8.self)
    #expect(text.contains("<!-- user comment -->\r\n"))
    #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    #expect(try await f.workspace.readKnowledgeAssertion(id: changed.id).assertion == changed)
    #expect(text.contains("## 주장\r\n\r\n" + WikiMarkdownEditor.literalInline(changed.statement.text) + "\r\n"))
    await #expect(throws: WikiError.changedSource) {
      try await f.workspace.prepareKnowledgeAssertion(changed, relativePath: next.relativePath,
        expectedRevision: expected, operationID: UUID())
    }
    let drifted = text.replacingOccurrences(of: "## 주장", with: "## Manually changed section")
    try f.write(drifted, path: next.relativePath)
    await #expect(throws: WikiError.self) { try await f.workspace.readKnowledgeAssertion(id: changed.id) }
    #expect(try await f.workspace.source(relativePath: next.relativePath) == Data(drifted.utf8))
  }

  @Test func replacingEvidenceDoesNotInheritAnotherLocationOrRemovedFacets() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let storage = NSMutableData(), consumer = try #require(CGDataConsumer(data: storage))
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil); context.textMatrix = .identity; context.textPosition = CGPoint(x: 40, y: 700)
    let line = NSAttributedString(string: "The coefficient is 42 W/(m K) at 20 °C. Edition 2", attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
    CTLineDraw(CTLineCreateWithAttributedString(line as CFAttributedString), context)
    context.endPDFPage(); context.closePDF()
    try (storage as Data).write(to: f.root.appendingPathComponent("attachments/book.pdf"))
    try f.write("---\nid: book\n---\n# Replacement\nThe replacement value is 7.\n[PDF](../attachments/book.pdf)\n", path: "notes/book.md")
    let sources = try await f.workspace.knowledgeInventory().sources
    let pdf = try #require(sources.first { $0.kind == .pdf })
    let oldQuote = try #require(try await f.workspace.knowledgeBlocks(for: pdf).evidence.first)
    let plan = try await f.workspace.prepareKnowledgeAssertion(assertion(id: "coefficient", evidence: oldQuote), operationID: UUID())
    _ = try await f.workspace.executeKnowledgeAssertion(plan)
    var fields = try #require(try WikiOntologyRecord.read(bytes: Data(plan.after.utf8))).fields
    var items = try #require(fields["evidence"]?.arrayValue)
    var item = try #require(items[0].objectValue)
    var oldEvidence = try #require(item["evidence"]?.objectValue)
    oldEvidence["future"] = .string("old PDF only")
    item["evidence"] = .object(oldEvidence); items[0] = .object(item); fields["evidence"] = .array(items)
    let enriched = try WikiOntologyRecord.replacingRecord(in: Data(plan.after.utf8), with: WikiOntologyRecord(fields: fields))
    try enriched.write(to: f.root.appendingPathComponent(plan.relativePath))
    let markdown = try #require(sources.first { $0.kind == .markdown })
    let quote = try #require(try await f.workspace.knowledgeBlocks(for: markdown).evidence.first { $0.text.contains("replacement") })
    let replacement = WikiKnowledgeAssertion(id: "coefficient",
      statement: .init(text: "The replacement value is 7.", citations: [.init(evidenceID: quote.id, quote: "The replacement value is 7.")]),
      evidence: [.init(evidence: quote)])
    let update = try await f.workspace.prepareKnowledgeAssertion(replacement, relativePath: plan.relativePath,
      expectedRevision: SourceDigest.sha256(enriched), operationID: UUID())
    _ = try await f.workspace.executeKnowledgeAssertion(update)
    let saved = try await f.workspace.readKnowledgeAssertion(id: replacement.id)
    #expect(saved.assertion == replacement)
    #expect(["value", "unit", "edition"].allSatisfy { saved.record.fields[$0] == nil })
    let metadata = try #require(saved.record.fields["evidence"]?.arrayValue?[0].objectValue?["evidence"]?.objectValue)
    #expect(metadata["future"] == nil && metadata["pdfRegion"] == nil)
    #expect(metadata["location"]?.objectValue?.keys.sorted() == ["markdown"])
  }

  @Test func assertionBindingRejectsPayloadSwapChangedOriginalAndUncertainReplay() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let quote = try await evidence(f)
    let value = assertion(id: "coefficient", evidence: quote)
    let plan = try await f.workspace.prepareKnowledgeAssertion(value, operationID: UUID())
    let extra = Data((plan.after + "\nUnreviewed payload\n").utf8)
    let swapped = WikiPreparedEdit(operationID: plan.operationID, workspaceID: plan.workspaceID,
      workspaceRevision: plan.workspaceRevision, relativePath: plan.relativePath, expectedRevision: nil,
      resultRevision: SourceDigest.sha256(extra), replacementBytes: extra, before: plan.before,
      after: String(decoding: extra, as: UTF8.self))
    await #expect(throws: WikiError.changedSource) { try await f.workspace.executeKnowledgeAssertion(swapped) }
    try f.write(source + "\nChanged original\n", path: "notes/book.md")
    await #expect(throws: WikiError.changedSource) { try await f.workspace.executeKnowledgeAssertion(plan) }
    try f.write(source, path: "notes/book.md")
    try Data("{}".utf8).write(to: f.base.appendingPathComponent("State/OperationReceipts/" + plan.operationID.uuidString + ".intent.json"))
    await #expect(throws: WikiError.self) { try await f.workspace.executeKnowledgeAssertion(plan) }
    let status = try await f.workspace.knowledgeAssertionOperationStatus(operationID: plan.operationID)
    #expect(status.operation.state == .uncertain && !status.sourceObserved)
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(plan.relativePath).path))
    await #expect(throws: WikiError.self) { try await f.workspace.prepareKnowledgeAssertion(value, operationID: plan.operationID) }
  }

  @Test func changedConceptRejectsClaimsUntilOneExplicitCASRebindWhileHistoricalReceiptRemains() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let quote = try await evidence(f)
    let concept = WikiKnowledgeConcept(id: "thermal", labels: [.init(language: "en", preferred: "coefficient")], mentions: [.init(evidence: quote)])
    let conceptPlan = try await f.workspace.prepareKnowledgeConcept(concept, operationID: UUID())
    _ = try await f.workspace.executeKnowledgeConcept(conceptPlan)
    let value = assertion(id: "coefficient", evidence: quote, conceptIDs: [concept.id])
    let pending = try await f.workspace.prepareKnowledgeAssertion(value, operationID: UUID())
    let oldConcept = try await f.workspace.readKnowledgeConcept(id: concept.id)
    let expanded = WikiKnowledgeConcept(id: concept.id, labels: [.init(language: "en", preferred: "coefficient", aliases: ["thermal coefficient"])], mentions: [.init(evidence: quote)])
    let update = try await f.workspace.prepareKnowledgeConcept(expanded, relativePath: oldConcept.relativePath,
      expectedRevision: oldConcept.revision, operationID: UUID())
    _ = try await f.workspace.executeKnowledgeConcept(update)
    await #expect(throws: WikiError.changedSource) { try await f.workspace.executeKnowledgeAssertion(pending) }
    let plan = try await f.workspace.prepareKnowledgeAssertion(value, operationID: UUID())
    let receipt = try await f.workspace.executeKnowledgeAssertion(plan)
    let saved = try await f.workspace.readKnowledgeAssertion(id: value.id)
    let conceptBytes = try await f.workspace.source(relativePath: conceptPlan.relativePath)
    try f.write(String(decoding: conceptBytes, as: UTF8.self) + "\n<!-- reviewed metadata changed -->\n", path: conceptPlan.relativePath)
    await #expect(throws: WikiError.changedSource) { try await f.workspace.readKnowledgeAssertion(id: value.id) }
    let list = try await f.workspace.knowledgeAssertionInventory(conceptID: concept.id)
    #expect(!list.complete && list.records.isEmpty)
    let history = try await f.workspace.knowledgeAssertionOperationStatus(operationID: plan.operationID)
    #expect(history.operation.state == .committed && history.currentness == .changed)
    #expect(try await f.workspace.executeKnowledgeAssertion(plan).sourceRevision == receipt.sourceRevision)
    let rebound = try await f.workspace.prepareKnowledgeAssertion(value, relativePath: saved.relativePath,
      expectedRevision: saved.revision, operationID: UUID())
    _ = try await f.workspace.executeKnowledgeAssertion(rebound)
    #expect(try await f.workspace.readKnowledgeAssertion(id: value.id).assertion == value)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("notes").path).count == 3)
  }

  @Test func existingO2ConceptOperationJSONStillRecoversThroughTheSharedWriter() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let quote = try await evidence(f)
    let value = WikiKnowledgeConcept(id: "thermal", labels: [.init(language: "en", preferred: "coefficient")], mentions: [.init(evidence: quote)])
    let plan = try await f.workspace.prepareKnowledgeConcept(value, operationID: UUID())
    let operationURL = f.base.appendingPathComponent("State/ConceptOperations/" + plan.operationID.uuidString.lowercased() + ".json")
    var legacy = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: operationURL)) as? [String: Any])
    legacy.removeValue(forKey: "assertion"); legacy.removeValue(forKey: "conceptBindings")
    try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]).write(to: operationURL)
    let reopened = try WikiWorkspace(root: f.root, localStateDirectory: f.base.appendingPathComponent("State"))
    #expect(try await reopened.knowledgeConceptOperationStatus(operationID: plan.operationID).operation.state == .notObserved)
    let receipt = try await reopened.executeKnowledgeConcept(plan)
    try f.write(source + "\nChanged after old operation committed\n", path: "notes/book.md")
    #expect(try await reopened.knowledgeConceptOperationStatus(operationID: plan.operationID).operation.state == .committed)
    #expect(try await reopened.executeKnowledgeConcept(plan).sourceRevision == receipt.sourceRevision)
  }

  @Test func adoptingProposalPersistsExtractionButManualEditDoesNotForgeNewModelAuthorship() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let quote = try await evidence(f)
    let draft = assertion(id: "coefficient", evidence: quote, state: .draft)
    let proposal = WikiKnowledgeAssertionProposal(assertion: draft, providerID: "fixture.extraction.v1",
      schemaVersion: 1, policyVersion: 1, inputDigest: String(repeating: "a", count: 64),
      proposalID: String(repeating: "b", count: 64), conceptRevisions: [:], scopeID: await f.workspace.knowledgeScopeID)
    let plan = try await f.workspace.prepareKnowledgeAssertion(proposal, operationID: UUID())
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(plan.relativePath).path))
    _ = try await f.workspace.executeKnowledgeAssertion(plan)
    let saved = try await f.workspace.readKnowledgeAssertion(id: draft.id)
    #expect(saved.assertion.state == .accepted)
    #expect(saved.record.fields["extraction"]?.objectValue?["providerID"] == .string("fixture.extraction.v1"))
    #expect(saved.record.fields["extraction"]?.objectValue?["inputDigest"] == .string(proposal.inputDigest))
    let edited = assertion(id: draft.id, evidence: quote, statement: "The coefficient is 42 W/(m K)")
    let change = try await f.workspace.prepareKnowledgeAssertion(edited, relativePath: saved.relativePath,
      expectedRevision: saved.revision, operationID: UUID())
    _ = try await f.workspace.executeKnowledgeAssertion(change)
    let current = try await f.workspace.readKnowledgeAssertion(id: draft.id)
    #expect(current.record.fields["extraction"] == saved.record.fields["extraction"])
    #expect(current.record.fields["editedBy"] == .string("explicitCaller"))
    let wrongScope = WikiKnowledgeAssertionProposal(assertion: draft, providerID: proposal.providerID,
      schemaVersion: 1, policyVersion: 1, inputDigest: proposal.inputDigest, proposalID: proposal.proposalID,
      conceptRevisions: [:], scopeID: "another-scope")
    await #expect(throws: WikiError.changedSource) { try await f.workspace.prepareKnowledgeAssertion(wrongScope, operationID: UUID()) }
  }

  private var source: String {
    "---\nid: book\n---\n# Measurement\nThe coefficient is 42 W/(m K) at 20 °C.\nEdition 2\n"
  }
  private func evidence(_ f: KnowledgeFixture) async throws -> WikiKnowledgeEvidence {
    try f.write(source, path: "notes/book.md")
    let document = try #require(try await f.workspace.knowledgeInventory().sources.first)
    return try #require(try await f.workspace.knowledgeBlocks(for: document).evidence.first)
  }
  private func assertion(id: String, evidence: WikiKnowledgeEvidence, statement: String = "The coefficient is 42 W/(m K) at 20 °C.",
    conceptIDs: [String] = [], state: WikiKnowledgeAssertion.State = .accepted) -> WikiKnowledgeAssertion {
    func field(_ text: String) -> WikiKnowledgeAssertionText {
      .init(text: text, citations: [.init(evidenceID: evidence.id, quote: text)])
    }
    return .init(id: id, statement: field(statement), conceptIDs: conceptIDs, conditions: [field("20 °C")],
      value: field("42"), unit: field("W/(m K)"), edition: field("Edition 2"), evidence: [.init(evidence: evidence)], state: state)
  }
}
