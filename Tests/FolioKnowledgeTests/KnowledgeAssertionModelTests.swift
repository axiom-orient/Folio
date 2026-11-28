import Foundation
import Testing
import FolioKnowledge
@testable import FolioKnowledgeApple

@Suite struct KnowledgeAssertionModelTests {
  @Test func oneClaimKeepsValueHeaderUnitEditionAndExactFacetSource() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let items = try await evidence(f)
    let claim = assertion(items)
    _ = try claim.validated()
    #expect(claim.polarity == .unspecified)
    #expect(claim.statement.origin == .quoted)
    #expect(try claim.sourceEvidence(for: #require(claim.unit)).map(\.id) == [items[1].id])
    #expect(try claim.sourceEvidence(for: #require(claim.edition)).map(\.id) == [items[2].id])
    #expect(try claim.sourceEvidence(for: #require(claim.value)).map(\.id) == [items[0].id])
    let bytes = try JSONEncoder().encode(claim)
    #expect(try WikiKnowledgeAssertion.decodeInput(bytes) == claim)
    let schema = try #require(try JSONSerialization.jsonObject(with: Data(WikiKnowledgeAssertion.inputSchemaJSON.utf8)) as? [String: Any])
    #expect(schema["$defs"] != nil)
  }

  @Test func koreanSuffixAfterLatinUnitOrNumberKeepsExactFacetsThroughSaveAndRead() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let statement = "열전도율은 20 °C에서 42 W/(m K)이다."
    let source = "---\nid: korean-source\n---\n# 물성\n" + statement + "\n별도 값은 42이다.\n# 판본\n제2판\n"
    try f.write(source, path: "notes/korean-source.md")
    let original = try #require(try await f.workspace.knowledgeInventory().sources.first)
    let items = try await f.workspace.knowledgeBlocks(for: original).evidence
    let row = try #require(items.first { $0.text.contains(statement) })
    let numericRow = try #require(items.first { $0.text.contains("별도 값은 42이다.") })
    let cover = try #require(items.first { $0.text.contains("제2판") })
    let condition = literal("20 °C", in: row, quote: "20 °C")
    let claim = WikiKnowledgeAssertion(id: "korean-conductivity", statement: literal(statement, in: row),
      conditions: [condition], value: literal("42", in: row), unit: literal("W/(m K)", in: row),
      edition: literal("제2판", in: cover), evidence: [.init(evidence: row), .init(evidence: cover, role: .context)])
    let plan = try await f.workspace.prepareKnowledgeAssertion(claim, operationID: UUID())
    _ = try await f.workspace.executeKnowledgeAssertion(plan)
    let saved = try await f.workspace.readKnowledgeAssertion(id: claim.id)
    #expect(saved.assertion == claim)
    for field in [condition, try #require(claim.value), try #require(claim.unit)] {
      #expect(try saved.assertion.sourceEvidence(for: field).map(\.id) == [row.id])
    }
    #expect(try saved.assertion.sourceEvidence(for: #require(claim.edition)).map(\.id) == [cover.id])
    #expect(try await f.workspace.source(relativePath: original.relativePath) == Data(source.utf8))
    // The same narrow boundary accepts a number immediately before a Korean suffix.
    let number = WikiKnowledgeAssertion(id: "korean-number", statement: literal("별도 값은 42이다.", in: numericRow),
      value: literal("42", in: numericRow, quote: "42이다"), evidence: [.init(evidence: numericRow)])
    _ = try number.validated()
    // Same-script Hangul clipping stays invalid; no morphological word inference is installed.
    let fragment = WikiKnowledgeAssertion(id: "korean-fragment", statement: literal("전도", in: row),
      evidence: [.init(evidence: row)])
    #expect(throws: WikiError.self) { try fragment.validated() }
  }

  @Test func forgedNumbersWordFragmentsAndCrossSourceBridgesAreRejected() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let items = try await evidence(f)
    try f.write("---\nid: other\n---\n# Other\nBETA coefficient is 99 Pa under condition Q. Edition 3.\n", path: "notes/other.md")
    let otherSource = try #require(try await f.workspace.knowledgeInventory().sources.first { $0.documentID == "other" })
    let other = try #require(try await f.workspace.knowledgeBlocks(for: otherSource).evidence.first)
    let base = assertion(items)
    let variants: [WikiKnowledgeAssertion] = [
      // Neither a full quote nor a clipped quote may turn -42 into 42.
      assertion(items, value: literal("42", in: items[0])),
      assertion(items, value: literal("42", in: items[0], quote: "42")),
      assertion(items, unit: literal("m", in: items[1], quote: "material")),
      assertion(items, unit: literal("W", in: items[1], quote: "WATT")),
      assertion(items, unit: literal("W", in: items[1], quote: "W/(m K)")),
      assertion(items, unit: literal("W", in: items[1], quote: "W")),
      assertion(items, unit: literal("m/s", in: items[1], quote: "m/s²")),
      // An unrelated citation cannot lend its physical source to a different literal.
      .init(id: "bridged", statement: base.statement, value: base.value,
        unit: .init(text: "Pa", citations: [.init(evidenceID: items[0].id, quote: items[0].text),
          .init(evidenceID: other.id, quote: other.text)]),
        evidence: base.evidence + [.init(evidence: other, role: .context)]),
      // Being on the same page/file does not authorize taking a different row's numeric value.
      assertion(items, value: literal("99", in: items[1])),
      .init(id: "context-only", statement: base.statement, evidence: [.init(evidence: items[0], role: .context)]),
      .init(id: "inference", statement: .init(text: "The coefficient is 42.", citations: base.statement.citations,
        origin: .interpretation), evidence: base.evidence)
    ]
    for variant in variants { #expect(throws: WikiError.self) { try variant.validated() } }
    let negation = WikiKnowledgeAssertion(id: "negation", statement: .init(text: "The effect is significant.",
      citations: [.init(evidenceID: items[1].id, quote: "The effect is not significant.")]), evidence: [.init(evidence: items[1])])
    #expect(throws: WikiError.self) { try negation.validated() }
  }

  @Test func strictNewInputRejectsUnknownNestedKeysAndPreservesLiteralUnicode() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let items = try await evidence(f)
    let value = assertion(items)
    var fields = try #require(try WikiJSONValue.parse(JSONEncoder().encode(value)).objectValue)
    var entries = try #require(fields["evidence"]?.arrayValue)
    var entry = try #require(entries[0].objectValue)
    var original = try #require(entry["evidence"]?.objectValue)
    original["pdfRegion"] = .null
    entry["evidence"] = .object(original); entries[0] = .object(entry); fields["evidence"] = .array(entries)
    #expect(try WikiKnowledgeAssertion.decodeInput(WikiJSONValue.object(fields).encoded()) == value)
    original["untrustedExtra"] = .null
    entry["evidence"] = .object(original); entries[0] = .object(entry); fields["evidence"] = .array(entries)
    #expect(throws: WikiError.self) { try WikiKnowledgeAssertion.decodeInput(WikiJSONValue.object(fields).encoded()) }
    let normalized = WikiKnowledgeAssertion(id: "unicode", statement: .init(text: "café", citations: [
      .init(evidenceID: items[1].id, quote: "café")]), evidence: [.init(evidence: items[1])])
    #expect(throws: WikiError.self) { try normalized.validated() }
  }

  @Test func contextAndOptionalProviderKeepOriginalAdmissionAndOnlyReturnDrafts() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let items = try await evidence(f)
    let context = try await f.workspace.knowledgeEvidenceContext(items[0])
    #expect(context.evidence.first == items[0])
    #expect(context.evidence.contains { $0.id == items[1].id })
    #expect(try await f.workspace.readKnowledgeEvidence(context.evidence) == context.evidence.map(\.text))
    let absent = WikiKnowledgeAssertionProposer(workspace: f.workspace)
    await #expect(throws: WikiError.self) { try await absent.propose(question: "coefficient", evidence: [items[0]]) }
    let proposer = WikiKnowledgeAssertionProposer(workspace: f.workspace, provider: FixtureAssertionProvider())
    let proposals = try await proposer.propose(question: "coefficient", evidence: [items[0]])
    let candidate = try #require(proposals.first)
    #expect(candidate.assertion.state == .draft && candidate.providerID == "fixture.assertions.v1")
    #expect(candidate.assertion.allEvidence == [items[0]] && candidate.inputDigest.count == 64)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("notes").path).count == 1)
    for mode in [FixtureAssertionProvider.Mode.unknownID, .acceptedState] {
      let bad = WikiKnowledgeAssertionProposer(workspace: f.workspace, provider: FixtureAssertionProvider(mode: mode))
      await #expect(throws: WikiError.self) { try await bad.propose(question: "coefficient", evidence: [items[0]]) }
    }
    let url = f.root.appendingPathComponent("notes/source.md")
    let changed = Data((source + "\nSource changed while model waited.\n").utf8)
    let stale = WikiKnowledgeAssertionProposer(workspace: f.workspace,
      provider: FixtureAssertionProvider(mutation: { try changed.write(to: url) }))
    await #expect(throws: WikiError.changedSource) { try await stale.propose(question: "coefficient", evidence: [items[0]]) }
  }

  @Test func cancellationRetainsTheProviderSlotUntilItActuallyEnds() async throws {
    let f = try KnowledgeFixture(); defer { f.remove() }
    let item = try await evidence(f)[0]
    let provider = GatedAssertionProvider()
    let proposer = WikiKnowledgeAssertionProposer(workspace: f.workspace, provider: provider)
    let task = Task { try await proposer.propose(question: "coefficient", evidence: [item]) }
    await provider.waitUntilEntered()
    task.cancel()
    await #expect(throws: WikiError.self) { try await proposer.propose(question: "coefficient", evidence: [item]) }
    await provider.resume()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await proposer.propose(question: "coefficient", evidence: [item]).count == 1)
  }

  private var source: String {
    "---\nid: source\n---\n# Results\nALTA coefficient is -42 under condition Z.\n# Units\nColumn unit: W/(m K). material and WATT are words. Velocity unit: m/s². Other row: 99. The effect is not significant. cafe\u{301}.\n# Cover\nEdition 2.\n"
  }
  private func evidence(_ f: KnowledgeFixture) async throws -> [WikiKnowledgeEvidence] {
    try f.write(source, path: "notes/source.md")
    let item = try #require(try await f.workspace.knowledgeInventory().sources.first)
    return try await f.workspace.knowledgeBlocks(for: item).evidence
  }
  private func literal(_ text: String, in evidence: WikiKnowledgeEvidence, quote: String? = nil) -> WikiKnowledgeAssertionText {
    .init(text: text, citations: [.init(evidenceID: evidence.id, quote: quote ?? evidence.text)])
  }
  private func assertion(_ evidence: [WikiKnowledgeEvidence], value: WikiKnowledgeAssertionText? = nil,
    unit: WikiKnowledgeAssertionText? = nil) -> WikiKnowledgeAssertion {
    .init(id: "measurement", statement: literal("ALTA coefficient is -42 under condition Z.", in: evidence[0]),
      conditions: [literal("condition Z", in: evidence[0])], value: value ?? literal("-42", in: evidence[0]),
      unit: unit ?? literal("W/(m K)", in: evidence[1]), edition: literal("Edition 2", in: evidence[2]),
      evidence: [.init(evidence: evidence[0]), .init(evidence: evidence[1], role: .context), .init(evidence: evidence[2], role: .context)])
  }
}

private struct FixtureAssertionProvider: WikiKnowledgeAssertionExtractionProvider {
  enum Mode: Sendable { case valid, unknownID, acceptedState }
  let identifier = "fixture.assertions.v1"
  var mode: Mode = .valid
  var mutation: (@Sendable () throws -> Void)? = nil
  func extract(from input: WikiKnowledgeAssertionExtractionInput) async throws -> Data {
    let encoded = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
    #expect(!encoded.contains("relativePath") && !encoded.contains("file://"))
    try mutation?()
    return try fixtureOutput(input, mode: mode)
  }
}

private func fixtureOutput(_ input: WikiKnowledgeAssertionExtractionInput,
  mode: FixtureAssertionProvider.Mode = .valid) throws -> Data {
  let source = input.sources[0]
  let citation = WikiKnowledgeAssertionCitation(evidenceID: source.id, quote: source.text)
  let statement = WikiKnowledgeAssertionText(text: source.text, citations: [citation])
  var candidate: [String: WikiJSONValue] = [
    "statement": try WikiJSONValue.parse(JSONEncoder().encode(statement)), "polarity": .string("unspecified"),
    "conceptIDs": .array([]), "conditions": .array([]), "evidence": .array([.object([
      "evidenceID": .string(mode == .unknownID ? "unknown" : source.id), "role": .string("support")
    ])])
  ]
  if mode == .acceptedState { candidate["state"] = .string("accepted") }
  return try WikiJSONValue.object(["schemaVersion": .number("1"), "candidates": .array([.object(candidate)])]).encoded()
}

private actor GatedAssertionProvider: WikiKnowledgeAssertionExtractionProvider {
  nonisolated let identifier = "fixture.gated-assertions.v1"
  private var entered = false
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var extractionContinuation: CheckedContinuation<Void, Never>?
  func extract(from input: WikiKnowledgeAssertionExtractionInput) async throws -> Data {
    if !entered {
      entered = true; enteredContinuation?.resume(); enteredContinuation = nil
      await withCheckedContinuation { extractionContinuation = $0 }
    }
    return try fixtureOutput(input)
  }
  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { enteredContinuation = $0 } }
  }
  func resume() { extractionContinuation?.resume(); extractionContinuation = nil }
}
