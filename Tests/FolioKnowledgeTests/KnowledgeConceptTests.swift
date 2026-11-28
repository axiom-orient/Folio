import Foundation
import Testing
import FolioKnowledge
@testable import FolioKnowledgeApple

@Suite struct KnowledgeConceptTests {
  @Test func conceptSaveUsesOriginalQuotesAndReopensSavedCitationWithoutBecomingPrimaryEvidence() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let quotes = try await evidence(f)
    let value = concept(id: "thermal", evidence: [quotes[0]])
    let plan = try await f.workspace.prepareKnowledgeConcept(value, operationID: UUID())
    let receipt = try await f.workspace.executeKnowledgeConcept(plan)
    let saved = try await f.workspace.readKnowledgeConcept(id: value.id)
    #expect(saved.concept == value)
    #expect(saved.revision == receipt.sourceRevision)
    let preview = try await f.workspace.previewSavedKnowledgeMarkdown(notePath: saved.relativePath,
      noteRevision: saved.revision, sourcePath: quotes[0].source.relativePath,
      fragment: quotes[0].location.savedCitationFragment)
    #expect(preview?.document.id == quotes[0].source.documentID)
    #expect(preview?.sectionID == quotes[0].markdownReference?.sectionID)
    let inventory = try await f.workspace.knowledgeInventory()
    #expect(inventory.sources.allSatisfy { $0.documentID != value.id })
    let status = try await f.workspace.knowledgeConceptOperationStatus(operationID: plan.operationID)
    #expect(status.operation.state == .committed && status.sourceObserved && status.currentness == .current)
  }

  @Test func conceptCASUpdatePreservesUnknownJSONCommentsCRLFAndExistingMentions() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let quotes = try await evidence(f)
    let value = concept(id: "thermal", evidence: [quotes[0]])
    let plan = try await f.workspace.prepareKnowledgeConcept(value, operationID: UUID())
    _ = try await f.workspace.executeKnowledgeConcept(plan)
    let original = try await f.workspace.source(relativePath: plan.relativePath)
    let parsed = try #require(try WikiOntologyRecord.read(bytes: original))
    var fields = parsed.fields
    fields["future"] = .object(["large": .number("123456789012345678901234567890"), "note": .string("preserve")])
    var mentions = try #require(fields["mentions"]?.arrayValue)
    var mention = try #require(mentions[0].objectValue)
    mention["futureMention"] = .bool(true)
    mentions[0] = .object(mention); fields["mentions"] = .array(mentions)
    let enriched = try WikiOntologyRecord.replacingRecord(in: original, with: WikiOntologyRecord(fields: fields))
    let raw = String(decoding: enriched, as: UTF8.self)
      .replacingOccurrences(of: "\n", with: "\r\n") + "\r\n<!-- user comment -->\r\n"
    try f.write(raw, path: plan.relativePath)
    let expected = SourceDigest.sha256(Data(raw.utf8))
    let update = WikiKnowledgeConcept(id: value.id, labels: [WikiConceptLabel(language: "ko", preferred: "열전도율", aliases: ["thermal conductivity"])],
      mentions: [.init(evidence: quotes[1])])
    let next = try await f.workspace.prepareKnowledgeConcept(update, relativePath: plan.relativePath,
      expectedRevision: expected, operationID: UUID())
    _ = try await f.workspace.executeKnowledgeConcept(next)
    let bytes = try await f.workspace.source(relativePath: plan.relativePath)
    let record = try #require(try WikiOntologyRecord.read(bytes: bytes))
    #expect(record.fields["future"] == fields["future"])
    #expect(record.fields["mentions"]?.arrayValue?.first?.objectValue?["futureMention"] == .bool(true))
    let read = try await f.workspace.readKnowledgeConcept(id: value.id)
    #expect(read.concept.mentions.count == 2 && read.concept.domain == "physics")
    #expect(read.concept.labels[0].aliases.contains("thermal conductivity"))
    #expect(String(decoding: bytes, as: UTF8.self).contains("<!-- user comment -->\r\n"))
    #expect(!String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    await #expect(throws: WikiError.changedSource) {
      try await f.workspace.prepareKnowledgeConcept(update, relativePath: plan.relativePath,
        expectedRevision: expected, operationID: UUID())
    }
  }

  @Test func conceptPayloadBindingAndUncertainOperationCannotBeReplayed() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let quotes = try await evidence(f)
    let plan = try await f.workspace.prepareKnowledgeConcept(concept(id: "thermal", evidence: [quotes[0]]), operationID: UUID())
    let tampered = Data((plan.after + "\nUnreviewed payload\n").utf8)
    let other = WikiPreparedEdit(operationID: plan.operationID, workspaceID: plan.workspaceID,
      workspaceRevision: plan.workspaceRevision, relativePath: plan.relativePath, expectedRevision: nil,
      resultRevision: SourceDigest.sha256(tampered), replacementBytes: tampered,
      before: plan.before, after: String(decoding: tampered, as: UTF8.self))
    await #expect(throws: WikiError.changedSource) { try await f.workspace.executeKnowledgeConcept(other) }
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(plan.relativePath).path))
    try f.write(source + "\nChanged before approval execution.\n", path: "notes/source.md")
    await #expect(throws: WikiError.changedSource) { try await f.workspace.executeKnowledgeConcept(plan) }
    try f.write(source, path: "notes/source.md")
    let intent = f.base.appendingPathComponent("State/OperationReceipts/" + plan.operationID.uuidString + ".intent.json")
    try Data("{}".utf8).write(to: intent)
    await #expect(throws: WikiError.self) { try await f.workspace.executeKnowledgeConcept(plan) }
    let status = try await f.workspace.knowledgeConceptOperationStatus(operationID: plan.operationID)
    #expect(status.operation.state == .uncertain && !status.sourceObserved)
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(plan.relativePath).path))
    #expect(try await f.workspace.source(relativePath: "notes/source.md") == Data(source.utf8))
  }

  @Test func historicalCommitRemainsObservableWhenBackingOriginalChanges() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let quotes = try await evidence(f)
    let plan = try await f.workspace.prepareKnowledgeConcept(concept(id: "thermal", evidence: [quotes[0]]), operationID: UUID())
    let receipt = try await f.workspace.executeKnowledgeConcept(plan)
    try f.write(source + "\nOriginal changed.\n", path: "notes/source.md")
    let reopened = try WikiWorkspace(root: f.root, localStateDirectory: f.base.appendingPathComponent("State"))
    let status = try await reopened.knowledgeConceptOperationStatus(operationID: plan.operationID)
    #expect(status.operation.state == .committed && status.currentness == .changed)
    #expect(status.operation.receipt?.sourceRevision == receipt.sourceRevision)
    await #expect(throws: WikiError.changedSource) { try await reopened.readKnowledgeConcept(id: "thermal") }
    // Receipt lookup is historical and must not be blocked by a changed source.
    let repeated = try await reopened.executeKnowledgeConcept(plan)
    #expect(repeated.sourceRevision == receipt.sourceRevision)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("notes").path).count == 2)
  }

  private var source: String {
    "---\nid: source\n---\n# Heat\nThermal conductivity describes heat conduction.\n# Units\nThe source reports W/(m K), with the stated material conditions.\n"
  }
  private func evidence(_ fixture: KnowledgeFixture) async throws -> [WikiKnowledgeEvidence] {
    try fixture.write(source, path: "notes/source.md")
    let item = try #require(try await fixture.workspace.knowledgeInventory().sources.first)
    let blocks = try await fixture.workspace.knowledgeBlocks(for: item).evidence
    #expect(blocks.count == 2)
    return blocks
  }
  private func concept(id: String, evidence: [WikiKnowledgeEvidence]) -> WikiKnowledgeConcept {
    .init(id: id, domain: "physics", labels: [WikiConceptLabel(language: "ko", preferred: "열전도율")],
      mentions: evidence.map { .init(evidence: $0) })
  }
}
