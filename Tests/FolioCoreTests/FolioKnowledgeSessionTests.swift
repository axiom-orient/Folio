import Foundation
import Testing
import FolioCore
import FolioKnowledge
import FolioKnowledgeApple

@MainActor
@Suite struct FolioKnowledgeSessionTests {
  @Test func hostSessionQueriesCurrentKnowledgeAndRevocationPreservesOriginal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioKnowledgeSDK-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("source")
    try WikiWorkspace.create(at: root, name: "연구 자료")
    let bytes = Data("---\nid: research\ntitle: 연구\n---\n# 연구\n광합성은 빛 에너지를 이용한다.\n".utf8)
    let note = root.appendingPathComponent("notes/research.md")
    try bytes.write(to: note)
    let access = FolioSourceAccess()
    let configuration = try FolioConfiguration(stateDirectory: directory.appendingPathComponent("host"),
      namespace: "com.folio.tests.knowledge", sourceAccess: access)
    let session = FolioSession(configuration: configuration)
    try await session.openWorkspace(at: root)
    let coverage = try await session.prepareKnowledgeIndex()
    #expect(coverage.sourceCount == 1 && coverage.complete)
    let answer = try await session.knowledgeAnswer("광합성")
    let evidence = try #require(answer.evidence.first)
    #expect(evidence.text.contains("빛 에너지"))
    #expect(try await session.readKnowledgeEvidence(evidence) == evidence.text)
    let concept = WikiKnowledgeConcept(id: "photosynthesis", labels: [
      WikiConceptLabel(language: "ko", preferred: "광합성", aliases: ["photosynthesis"])
    ], mentions: [.init(evidence: evidence)])
    let operationID = UUID()
    let plan = try await session.prepareKnowledgeConcept(concept, operationID: operationID)
    let receipt = try await session.executeKnowledgeConcept(plan)
    let record = try await session.readKnowledgeConcept(id: concept.id)
    #expect(record.concept == concept && record.revision == receipt.sourceRevision)
    let status = try await session.knowledgeConceptOperationStatus(operationID: operationID)
    #expect(status.operation.state == .committed && status.sourceObserved && status.currentness == .current)
    let aliasAnswer = try await session.knowledgeAnswer("photosynthesis")
    #expect(aliasAnswer.evidence.contains { $0.id == evidence.id })
    #expect(!aliasAnswer.semanticUsed)
    let assertion = WikiKnowledgeAssertion(id: "light-energy", statement: .init(text: "광합성은 빛 에너지를 이용한다.",
      citations: [.init(evidenceID: evidence.id, quote: "광합성은 빛 에너지를 이용한다.")]),
      conceptIDs: [concept.id], evidence: [.init(evidence: evidence)])
    let assertionPlan = try await session.prepareKnowledgeAssertion(assertion, operationID: UUID())
    let assertionReceipt = try await session.executeKnowledgeAssertion(assertionPlan)
    #expect(try await session.readKnowledgeAssertion(id: assertion.id).revision == assertionReceipt.sourceRevision)
    let assertions = try await session.knowledgeAssertions(conceptID: concept.id, documentID: "research", query: "빛 에너지")
    #expect(assertions.complete && assertions.records.map(\.assertion.id) == [assertion.id])
    #expect(try await session.knowledgeEvidenceContext(evidence).focus == evidence)
    #expect(try await session.knowledgeAssertionOperationStatus(operationID: assertionPlan.operationID).currentness == .current)
    await #expect(throws: WikiError.self) { try await session.proposeKnowledgeAssertions("광합성", evidence: [evidence]) }
    #expect(try await session.reviewKnowledgeAssertion(id: assertion.id).requiresConceptReview == false)
    let renamed = WikiKnowledgeConcept(id: concept.id, labels: [
      WikiConceptLabel(language: "ko", preferred: "광합성", aliases: ["photosynthesis", "광 에너지 이용"])
    ], mentions: [.init(evidence: evidence)])
    let rename = try await session.prepareKnowledgeConcept(renamed, relativePath: record.relativePath,
      expectedRevision: record.revision, operationID: UUID())
    _ = try await session.executeKnowledgeConcept(rename)
    await #expect(throws: WikiError.changedSource) { try await session.readKnowledgeAssertion(id: assertion.id) }
    let review = try await session.reviewKnowledgeAssertion(id: assertion.id)
    #expect(review.requiresConceptReview && review.record.assertion == assertion)
    #expect(review.conceptChanges.map(\.conceptID) == [concept.id])
    let rebound = try await session.prepareKnowledgeAssertion(review.record.assertion, relativePath: review.record.relativePath,
      expectedRevision: review.record.revision, expectedConceptRevisions: review.currentConceptRevisions, operationID: UUID())
    _ = try await session.executeKnowledgeAssertion(rebound)
    #expect(try await session.readKnowledgeAssertion(id: assertion.id).assertion == assertion)
    access.revoke()
    await #expect(throws: (any Error).self) { try await session.readKnowledgeEvidence(evidence) }
    await #expect(throws: (any Error).self) { try await session.knowledgeAnswer("광합성") }
    await #expect(throws: (any Error).self) { try await session.readKnowledgeConcept(id: concept.id) }
    await #expect(throws: (any Error).self) { try await session.knowledgeConceptOperationStatus(operationID: operationID) }
    await #expect(throws: (any Error).self) { try await session.executeKnowledgeConcept(plan) }
    await #expect(throws: (any Error).self) { try await session.readKnowledgeAssertion(id: assertion.id) }
    await #expect(throws: (any Error).self) { try await session.reviewKnowledgeAssertion(id: assertion.id) }
    await #expect(throws: (any Error).self) { try await session.knowledgeAssertions() }
    await #expect(throws: (any Error).self) { try await session.executeKnowledgeAssertion(assertionPlan) }
    await #expect(throws: (any Error).self) { try await session.knowledgeAssertionOperationStatus(operationID: assertionPlan.operationID) }
    #expect(try Data(contentsOf: note) == bytes)
    try await session.close()
    await #expect(throws: FolioError.noWorkspace) { try await session.readKnowledgeEvidence(evidence) }
  }
}
