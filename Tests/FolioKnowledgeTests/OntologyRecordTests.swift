import Foundation
import Testing
@testable import FolioKnowledge

@Suite struct OntologyRecordTests {
  @Test func metadataPatchPreservesUnknownNumbersCommentsAndOriginalBody() throws {
    let json = #"{"schemaVersion":1,"role":"concept","recordID":"thermal","future":{"big":123456789012345678901234567890,"decimal":1.234567890123456789e-20},"state":"draft"}"#
    let original = Data(("---\r\nid: thermal # keep ID comment\r\nunknown: [one, two] # keep YAML\r\nfolio_ontology_record: '" + json + "' # keep record comment\r\n---\r\n# 열전도율\r\n원문 spelling remains.\r\n").utf8)
    let old = try #require(try WikiOntologyRecord.read(bytes: original))
    var fields = old.fields
    fields["state"] = .string("accepted")
    fields["note"] = .string("작은따옴표 '와\u{85}줄\u{2028}구분\u{2029}")
    let changed = try WikiOntologyRecord(fields: fields)
    let patched = try WikiOntologyRecord.replacingRecord(in: original, with: changed)
    let reread = try #require(try WikiOntologyRecord.read(bytes: patched))
    #expect(reread == changed)
    #expect(reread.fields["future"] == old.fields["future"])
    let text = String(decoding: patched, as: UTF8.self)
    #expect(text.contains("123456789012345678901234567890"))
    #expect(text.contains("1.234567890123456789e-20"))
    #expect(text.contains("id: thermal # keep ID comment\r\nunknown: [one, two] # keep YAML\r\n"))
    #expect(text.contains(" # keep record comment\r\n---\r\n# 열전도율\r\n원문 spelling remains.\r\n"))
    #expect(!text.contains("\u{85}") && !text.contains("\u{2028}") && !text.contains("\u{2029}"))
  }

  @Test func envelopeRejectsDuplicateKeysMismatchedIDsAndOversizedEscapedFrontmatter() throws {
    #expect(throws: WikiError.self) { try WikiJSONValue.parse(Data(#"{"a":1,"a":2}"#.utf8)) }
    #expect(throws: WikiError.self) { try WikiJSONValue.parse(Data(#"{"a":01}"#.utf8)) }
    let future = try WikiOntologyRecord(fields: ["schemaVersion": .number("2"), "role": .string("future"), "recordID": .string("term")])
    #expect(future.schemaVersion == 2 && future.role == "future")
    let text = "---\nid: term\n" + (try future.frontmatterLine()) + "---\n# Term\n"
    #expect(try WikiOntologyRecord.read(bytes: Data(text.utf8)) == future)
    #expect(throws: WikiError.self) { try WikiOntologyRecord.read(bytes: Data(text.replacingOccurrences(of: "id: term", with: "id: other").utf8)) }
    let huge = try WikiOntologyRecord(fields: ["schemaVersion": .number("1"), "role": .string("concept"), "recordID": .string("term"),
      "future": .string(String(repeating: "'", count: 33_000))])
    let base = Data("---\nid: term\n---\n# Term\n".utf8)
    #expect(throws: WikiError.self) { try WikiOntologyRecord.replacingRecord(in: base, with: huge) }
    #expect(String(decoding: base, as: UTF8.self) == "---\nid: term\n---\n# Term\n")
  }

  @Test func terminologyProjectionKeepsAmbiguityScopeAndSourceRevision() async throws {
    let fixture = try OntologyProjectionFixture(); defer { fixture.remove() }
    let projection = fixture.projection
    try await projection.replaceKnowledgeDocument(.init(id: "a", revision: "ra", producer: "test", payload: "{}"), blocks: [])
    try await projection.replaceKnowledgeDocument(.init(id: "b", revision: "rb", producer: "test", payload: "{}"), blocks: [])
    try await projection.replaceOntologyRecords([
      try record("material", source: "a", revision: "ra"),
      try record("information", source: "b", revision: "rb")
    ], manifestRevision: "manifest-one")
    let ambiguous = try await projection.ontologyConceptMatches(query: "열전도율 알려줘", sourceIDs: ["a", "b"])
    #expect(ambiguous.complete && ambiguous.matches.count == 2)
    let truncated = try await projection.ontologyConceptMatches(query: "열전도율", sourceIDs: ["a", "b"], limit: 1)
    #expect(!truncated.complete && truncated.matches.count == 1)
    #expect(try await projection.ontologyConceptMatches(query: "열전도율", sourceIDs: ["a"]).matches.map(\.id) == ["material"])
    #expect(try await projection.ontologyConceptMatches(query: "thermal conductivity", sourceIDs: ["a"]).matches.map(\.id) == ["material"])
    #expect(try await projection.ontologyConceptMatches(query: "열전도율이", sourceIDs: ["a"]).matches.isEmpty)
    #expect(try await projection.ontologyConceptMatches(query: "열전도율", sourceIDs: []).matches.isEmpty)
    #expect(try await projection.ontologyMentions(recordIDs: ["material"], sourceIDs: ["a"]).map(\.id) == ["e-a"])
    try await projection.replaceKnowledgeDocument(.init(id: "a", revision: "changed", producer: "test", payload: "{}"), blocks: [])
    // A stale interpretation remains a possible meaning. Dropping it here could
    // silently turn an ambiguous name into a different, apparently unique concept.
    #expect(try await projection.ontologyConceptMatches(query: "열전도율", sourceIDs: ["a"]).matches.map(\.id) == ["material"])
    #expect(try await projection.ontologyMentions(recordIDs: ["material"], sourceIDs: ["a"]).isEmpty)
  }

  @Test func oldResetEpochAndFutureComponentFailClosedWithoutBlockingPrimaryProjection() async throws {
    let fixture = try OntologyProjectionFixture(); defer { fixture.remove() }
    let projection = fixture.projection
    try await projection.replaceOntologyRecords([], manifestRevision: "first")
    let raw = try ProjectionDatabase(url: fixture.url)
    try raw.execute("UPDATE metadata SET value=? WHERE key='store_id'", [.text(UUID().uuidString)])
    let reader = try WikiProjection(databaseURL: fixture.url, readOnly: true)
    #expect(try await reader.ontologyComponentAvailable() == false)
    #expect(try await reader.ontologyManifestRevision() == nil)
    #expect(try await projection.ontologyManifestRevision() == nil)
    try await projection.replaceOntologyRecords([], manifestRevision: "rebuilt")
    #expect(try await projection.ontologyManifestRevision() == "rebuilt")
    try raw.execute("UPDATE metadata SET value='2' WHERE key='ontology_schema'")
    let compatiblePrimary = try WikiProjection(databaseURL: fixture.url)
    #expect(try await compatiblePrimary.ontologyComponentAvailable() == false)
    #expect(try await compatiblePrimary.knowledgeBlockCount() == 0)
    #expect(try await compatiblePrimary.ontologyManifestRevision() == nil)
    await #expect(throws: WikiError.self) { try await compatiblePrimary.replaceOntologyRecords([], manifestRevision: "must-not-overwrite") }
  }

  private func record(_ id: String, source: String, revision: String) throws -> WikiOntologyProjectionRecord {
    let label = WikiConceptLabel(language: "ko", preferred: "열전도율", aliases: ["thermal conductivity"])
    let payload = try WikiOntologyRecord(fields: ["schemaVersion": .number("1"), "role": .string("concept"), "recordID": .string(id)])
    return .init(id: id, revision: "record-" + id, payload: String(decoding: try payload.encoded(), as: UTF8.self), labels: [label],
      mentions: [.init(id: "e-" + source, sourceID: source, sourceRevision: revision, payload: "{}")])
  }
}

private struct OntologyProjectionFixture {
  let directory: URL
  let url: URL
  let projection: WikiProjection
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioOntologyProjection-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    url = directory.appendingPathComponent("projection.sqlite")
    projection = try WikiProjection(databaseURL: url)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
