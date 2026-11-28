import Foundation
import Testing
import FolioKnowledge
@testable import FolioKnowledgeApple

@Suite struct KnowledgeAssertionReviewTests {
  @Test func changedConceptCanBeExplicitlyReviewedAndReboundButChangedOriginalCannot() async throws {
    let fixture = try KnowledgeFixture(); defer { fixture.remove() }
    let source = "---\nid: source\n---\n# 측정\n열전도율은 20 °C에서 42 W/(m K)이다.\n"
    try fixture.write(source, path: "notes/source.md")
    let admitted = try #require(try await fixture.workspace.knowledgeInventory().sources.first)
    let evidence = try #require(try await fixture.workspace.knowledgeBlocks(for: admitted).evidence.first)
    let concept = WikiKnowledgeConcept(id: "thermal", labels: [.init(language: "ko", preferred: "열전도율")],
      mentions: [.init(evidence: evidence)])
    let conceptPlan = try await fixture.workspace.prepareKnowledgeConcept(concept, operationID: UUID())
    _ = try await fixture.workspace.executeKnowledgeConcept(conceptPlan)
    let assertion = WikiKnowledgeAssertion(id: "measurement", statement: .init(text: "열전도율은 20 °C에서 42 W/(m K)이다.",
      citations: [.init(evidenceID: evidence.id, quote: evidence.text)]), conceptIDs: [concept.id], evidence: [.init(evidence: evidence)])
    let plan = try await fixture.workspace.prepareKnowledgeAssertion(assertion, operationID: UUID())
    _ = try await fixture.workspace.executeKnowledgeAssertion(plan)
    let originalRecord = try await fixture.workspace.readKnowledgeAssertion(id: assertion.id)
    let previousConcept = try await fixture.workspace.readKnowledgeConcept(id: concept.id)
    let updatedConcept = WikiKnowledgeConcept(id: concept.id,
      labels: [.init(language: "ko", preferred: "열전도율", aliases: ["thermal conductivity"])],
      mentions: concept.mentions)
    let conceptUpdate = try await fixture.workspace.prepareKnowledgeConcept(updatedConcept,
      relativePath: previousConcept.relativePath, expectedRevision: previousConcept.revision, operationID: UUID())
    _ = try await fixture.workspace.executeKnowledgeConcept(conceptUpdate)
    await #expect(throws: WikiError.changedSource) { try await fixture.workspace.readKnowledgeAssertion(id: assertion.id) }
    let list = try await fixture.workspace.knowledgeAssertionInventory()
    #expect(list.records.isEmpty && !list.complete)

    let beforeReview = try await fixture.workspace.source(relativePath: originalRecord.relativePath)
    let review = try await fixture.workspace.reviewKnowledgeAssertion(id: assertion.id)
    #expect(review.requiresConceptReview && review.record.revision == originalRecord.revision)
    #expect(review.conceptChanges.count == 1 && review.conceptChanges[0].state == .changed)
    #expect(review.conceptChanges[0].name == "열전도율")
    #expect(review.conceptChanges[0].currentConcept?.labels.first?.aliases == ["thermal conductivity"])
    #expect(try await fixture.workspace.source(relativePath: originalRecord.relativePath) == beforeReview)
    let latestConcept = try await fixture.workspace.readKnowledgeConcept(id: concept.id)
    let changedAgain = WikiKnowledgeConcept(id: concept.id,
      labels: [.init(language: "ko", preferred: "열전도율", aliases: ["thermal conductivity", "heat conduction coefficient"])],
      mentions: concept.mentions)
    let secondUpdate = try await fixture.workspace.prepareKnowledgeConcept(changedAgain,
      relativePath: latestConcept.relativePath, expectedRevision: latestConcept.revision, operationID: UUID())
    _ = try await fixture.workspace.executeKnowledgeConcept(secondUpdate)
    await #expect(throws: WikiError.changedSource) {
      try await fixture.workspace.prepareKnowledgeAssertion(review.record.assertion,
        relativePath: review.record.relativePath, expectedRevision: review.record.revision,
        expectedConceptRevisions: review.currentConceptRevisions, operationID: UUID())
    }
    #expect(try await fixture.workspace.source(relativePath: originalRecord.relativePath) == beforeReview)
    let freshReview = try await fixture.workspace.reviewKnowledgeAssertion(id: assertion.id)
    #expect(freshReview.currentConceptRevisions != review.currentConceptRevisions)
    let rebind = try await fixture.workspace.prepareKnowledgeAssertion(freshReview.record.assertion,
      relativePath: freshReview.record.relativePath, expectedRevision: freshReview.record.revision,
      expectedConceptRevisions: freshReview.currentConceptRevisions, operationID: UUID())
    _ = try await fixture.workspace.executeKnowledgeAssertion(rebind)
    #expect(try await fixture.workspace.readKnowledgeAssertion(id: assertion.id).assertion == assertion)
    let afterRebind = try await fixture.workspace.reviewKnowledgeAssertion(id: assertion.id)
    #expect(!afterRebind.requiresConceptReview)

    // A draft concept is shown for review but must be explicitly unlinked.
    let currentConcept = try await fixture.workspace.readKnowledgeConcept(id: concept.id)
    let draft = WikiKnowledgeConcept(id: concept.id, labels: currentConcept.concept.labels,
      mentions: concept.mentions, state: .draft)
    let draftPlan = try await fixture.workspace.prepareKnowledgeConcept(draft, relativePath: currentConcept.relativePath,
      expectedRevision: currentConcept.revision, operationID: UUID())
    _ = try await fixture.workspace.executeKnowledgeConcept(draftPlan)
    let unavailable = try await fixture.workspace.reviewKnowledgeAssertion(id: assertion.id)
    #expect(unavailable.conceptChanges.first?.state == .unavailable)
    let unlinked = WikiKnowledgeAssertion(id: assertion.id, statement: assertion.statement, evidence: assertion.evidence)
    let unlink = try await fixture.workspace.prepareKnowledgeAssertion(unlinked, relativePath: unavailable.record.relativePath,
      expectedRevision: unavailable.record.revision, expectedConceptRevisions: [:], operationID: UUID())
    _ = try await fixture.workspace.executeKnowledgeAssertion(unlink)
    #expect(try await fixture.workspace.readKnowledgeAssertion(id: assertion.id).assertion.conceptIDs.isEmpty)
    #expect(try await fixture.workspace.source(relativePath: "notes/source.md") == Data(source.utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("notes").path).count == 3)

    try fixture.write(source + "\n원문이 변경됨.\n", path: "notes/source.md")
    await #expect(throws: WikiError.changedSource) { try await fixture.workspace.reviewKnowledgeAssertion(id: assertion.id) }
  }
}
