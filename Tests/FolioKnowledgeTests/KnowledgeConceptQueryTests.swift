import Foundation
import Testing
@testable import FolioKnowledge
import FolioKnowledgeApple

@Suite struct KnowledgeConceptQueryTests {
  @Test func reviewedKoreanNameFindsExactEnglishOriginalWithoutModels() async throws {
    let fixture = try KnowledgeFixture(); defer { fixture.remove() }
    let original = "---\nid: book\n---\n# Conduction record\nThe flux coefficient for material ALTA is 42 W per metre kelvin.\n"
    try fixture.write(original, path: "notes/book.md")
    let quote = try await evidence(in: fixture, documentID: "book")
    try await saveConcept(in: fixture, id: "thermal", name: "열전도율", aliases: ["thermal conductivity"], domain: "재료", evidence: quote)
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace)
    let answer = try await engine.answer("열전도율 알려줘", documentID: "book")
    #expect(!answer.semanticUsed && !answer.atomicSnapshot)
    #expect(answer.evidence == [quote])
    #expect(answer.concepts?.selectedConceptID == "thermal")
    #expect(try await fixture.workspace.readKnowledgeEvidence(answer.evidence[0]) == quote.text)
    let english = try await engine.answer("thermal conductivity", documentID: "book")
    #expect(english.evidence == [quote])
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("notes/book.md"), encoding: .utf8) == original)
    await fixture.workspace.close()
  }

  @Test func ordinaryDocumentAliasesNeverBecomeConceptEvidence() async throws {
    let fixture = try KnowledgeFixture(); defer { fixture.remove() }
    try fixture.write("---\nid: ordinary\naliases: [열전도율]\n---\n# Unrelated report\nThe archive contains a railway timetable.\n", path: "notes/report.md")
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace)
    let answer = try await engine.answer("열전도율")
    #expect(answer.evidence.isEmpty)
    #expect(answer.concepts?.choices.isEmpty == true)
    #expect(answer.concepts?.selectedConceptID == nil)
    let raw = try ProjectionDatabase(url: fixture.base.appendingPathComponent("State/knowledge.sqlite"))
    try raw.execute("UPDATE metadata SET value='2' WHERE key='ontology_schema'")
    let fallback = try await engine.answer("railway")
    let quotation = try #require(fallback.evidence.first)
    #expect(quotation.source.documentID == "ordinary" && quotation.text.contains("railway timetable"))
    #expect(try await fixture.workspace.readKnowledgeEvidence(quotation) == quotation.text)
    #expect(fallback.concepts?.complete == false && fallback.concepts?.selectedConceptID == nil)
    await #expect(throws: WikiError.self) { try await engine.answer("railway", conceptID: "ordinary") }
    await fixture.workspace.close()
  }

  @Test func ambiguousNamesRequireAChoiceAndSelectedDocumentCannotLeakOtherConceptSources() async throws {
    let fixture = try KnowledgeFixture(); defer { fixture.remove() }
    try fixture.write("---\nid: mechanics\n---\n# Rotational record\nThe torque measurement for sample AXIS is 12 newton metres.\n", path: "notes/mechanics.md")
    try fixture.write("---\nid: statistics\n---\n# Distribution record\nThe second distribution measurement for sample BETA is 7.\n", path: "notes/statistics.md")
    let mechanicalQuote = try await evidence(in: fixture, documentID: "mechanics")
    let statisticalQuote = try await evidence(in: fixture, documentID: "statistics")
    try await saveConcept(in: fixture, id: "torque", name: "모멘트", domain: "역학", evidence: mechanicalQuote)
    try await saveConcept(in: fixture, id: "distribution", name: "모멘트", domain: "통계", evidence: statisticalQuote)
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace)
    let ambiguous = try await engine.answer("모멘트")
    #expect(ambiguous.evidence.isEmpty)
    #expect(ambiguous.concepts?.isAmbiguous == true)
    #expect(Set(ambiguous.concepts?.choices.map(\.id) ?? []) == ["torque", "distribution"])
    let chosen = try await engine.answer("모멘트", conceptID: "torque")
    #expect(chosen.evidence == [mechanicalQuote])
    #expect(chosen.concepts?.selectedConceptID == "torque")
    let scoped = try await engine.answer("모멘트", documentID: "statistics")
    #expect(scoped.evidence == [statisticalQuote])
    #expect(scoped.concepts?.selectedConceptID == "distribution")
    #expect(scoped.evidence.allSatisfy { $0.source.documentID == "statistics" })
    await #expect(throws: WikiError.self) { try await engine.answer("모멘트", documentID: "statistics", conceptID: "torque") }
    let unrelated = try await engine.answer("galactic orchard routing", documentID: "statistics")
    #expect(unrelated.evidence.isEmpty && unrelated.concepts?.choices.isEmpty == true)
    #expect(unrelated.coverage.sourceCount == 1)
    try fixture.write("---\nid: statistics\n---\n# Distribution record\nThe revised second distribution measurement is 9.\n", path: "notes/statistics.md")
    let changedMeaning = try await engine.answer("모멘트")
    #expect(changedMeaning.evidence.isEmpty)
    #expect(Set(changedMeaning.concepts?.choices.map(\.id) ?? []) == ["torque", "distribution"])
    #expect(changedMeaning.concepts?.selectedConceptID == nil && changedMeaning.concepts?.complete == false)
    await #expect(throws: WikiError.self) { try await engine.answer("모멘트", conceptID: "distribution") }
    await fixture.workspace.close()
  }

  @Test(.timeLimit(.minutes(1))) func conceptChangedToDraftDuringRelevanceAwaitRejectsPublication() async throws {
    let fixture = try KnowledgeFixture(); defer { fixture.remove() }
    try fixture.write("---\nid: book\n---\n# Conduction record\nThe flux coefficient for material ALTA is 42 W per metre kelvin.\n", path: "notes/book.md")
    let quote = try await evidence(in: fixture, documentID: "book")
    try await saveConcept(in: fixture, id: "thermal", name: "열전도율", domain: "재료", evidence: quote)
    let before = try await fixture.workspace.knowledgeInventory()
    let relevance = PausedConceptRelevance()
    let engine = WikiKnowledgeQuery(workspace: fixture.workspace, embedding: ConstantConceptEmbedding(), relevance: relevance)
    let pending = Task { try await engine.answer("열전도율", useSemantic: true) }
    await relevance.waitUntilEntered()
    let recordURL = fixture.root.appendingPathComponent("notes/thermal.md")
    let original = try Data(contentsOf: recordURL)
    let record = try #require(try WikiOntologyRecord.read(bytes: original))
    var fields = record.fields
    fields["state"] = .string("draft")
    let draft = try WikiOntologyRecord.replacingRecord(in: original, with: WikiOntologyRecord(fields: fields))
    try draft.write(to: recordURL, options: .atomic)
    // Primary inventory deliberately excludes derived Concept records. The new
    // record manifest, rather than a source-only token, must catch this change.
    let after = try await fixture.workspace.knowledgeInventory()
    #expect(before.fingerprint == after.fingerprint)
    await relevance.resume()
    await #expect(throws: WikiError.changedSource) { try await pending.value }
    #expect(await relevance.lastQuestion() == "열전도율")
    #expect(await relevance.candidateCount() <= WikiLocalSemanticSearch.maximumRelevanceCandidates)
    await fixture.workspace.close()
  }

  private func evidence(in fixture: KnowledgeFixture, documentID: String) async throws -> WikiKnowledgeEvidence {
    let inventory = try await fixture.workspace.knowledgeInventory()
    let source = try #require(inventory.sources.first { $0.kind == .markdown && $0.documentID == documentID })
    let material = try await fixture.workspace.knowledgeBlocks(for: source)
    return try #require(material.evidence.first)
  }

  private func saveConcept(in fixture: KnowledgeFixture, id: String, name: String, aliases: [String] = [],
    domain: String, evidence: WikiKnowledgeEvidence
  ) async throws {
    let concept = WikiKnowledgeConcept(id: id, domain: domain,
      labels: [.init(language: "ko", preferred: name, aliases: aliases)], mentions: [.init(evidence: evidence)])
    let plan = try await fixture.workspace.prepareKnowledgeConcept(concept, operationID: UUID())
    _ = try await fixture.workspace.executeKnowledgeConcept(plan)
  }
}

private struct ConstantConceptEmbedding: WikiSemanticEmbedding {
  let identifier = "test-concept-embedding.v1"
  let dimensions = 2
  func vector(for text: String, role: WikiSemanticRole) async throws -> [Double] { [1, 0] }
}

private actor PausedConceptRelevance: WikiSemanticRelevance {
  nonisolated let identifier = "test-concept-relevance.v1"
  private var entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var gate: CheckedContinuation<Void, Never>?
  private var question: String?
  private var count = 0
  func scores(query: String, passages: [String]) async throws -> [Double?] {
    question = query; count = passages.count; entered = true
    waiter?.resume(); waiter = nil
    await withCheckedContinuation { gate = $0 }
    return passages.map { _ in 2.0 }
  }
  func waitUntilEntered() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
  func resume() { gate?.resume(); gate = nil }
  func lastQuestion() -> String? { question }
  func candidateCount() -> Int { count }
}
