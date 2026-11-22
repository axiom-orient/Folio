import Foundation
import Testing
import FolioKnowledge

@Suite struct KnowledgeProjectionTests {
  @Test func replacementIsAtomicAndReplacedBlocksLoseVectors() async throws {
    let fixture = try ProjectionFixture(); defer { fixture.remove() }
    let projection = fixture.projection
    try await projection.replaceKnowledgeDocument(document("a"), blocks: [
      block("a-0", source: "a", ordinal: 0, text: "What is the original knowledge? 무엇인가요 알려주세요")
    ])
    try await projection.replaceKnowledgeDocument(document("b"), blocks: [block("b-0", source: "b", ordinal: 0)])
    #expect(try await projection.searchKnowledgeBlocks("What is the xylophoton?").isEmpty)
    #expect(try await projection.searchKnowledgeBlocks("무엇인가요 알려주세요").isEmpty)
    #expect(try await projection.storeKnowledgeVector(blockID: "a-0", modelID: "test-model", valueJSON: "[1,0]"))
    #expect(try await projection.knowledgeBlockPage(sourceIDs: ["a"]).first?.block.vectorJSON == "[1,0]")
    // A global ID collision occurs after DELETE/INSERT have begun; rollback must
    // restore the old document, block, vector and FTS entries together.
    await #expect(throws: WikiError.self) {
      try await projection.replaceKnowledgeDocument(document("a", revision: "r2"),
        blocks: [block("b-0", source: "a", ordinal: 0, text: "replacement")])
    }
    #expect(try await projection.knowledgeDocuments().first { $0.id == "a" }?.revision == "r1")
    #expect(try await projection.knowledgeBlockPage(sourceIDs: ["a"]).first?.block.vectorJSON == "[1,0]")
    #expect(try await projection.searchKnowledgeBlocks("original", sourceIDs: ["a"]).map(\.id) == ["a-0"])
    try await projection.replaceKnowledgeDocument(document("a", revision: "r2"),
      blocks: [block("a-0", source: "a", ordinal: 0, text: "new knowledge")])
    let replaced = try #require(try await projection.knowledgeBlockPage(sourceIDs: ["a"]).first?.block)
    #expect(replaced.vectorJSON == nil && replaced.vectorModelID == nil)
    #expect(try await projection.searchKnowledgeBlocks("original", sourceIDs: ["a"]).isEmpty)
    #expect(try await projection.searchKnowledgeBlocks("new", sourceIDs: ["a"]).map(\.id) == ["a-0"])
    #expect(try await projection.storeKnowledgeVector(blockID: "missing", modelID: "test-model", valueJSON: "[]") == false)
  }

  @Test func globalPagingCoversMoreThan512BlocksAndSupportsLargeSourceScopes() async throws {
    let fixture = try ProjectionFixture(); defer { fixture.remove() }
    let projection = fixture.projection
    try await projection.replaceKnowledgeDocument(document("a"), blocks: (0..<600).map {
      block("a-\($0)", source: "a", ordinal: $0, text: "한국어 지식 근거 \($0)")
    })
    var rows: [WikiKnowledgeBlockRow] = []
    var cursor: Int64 = 0
    while true {
      let page = try await projection.knowledgeBlockPage(afterRowID: cursor, limit: 256)
      guard let last = page.last else { break }
      #expect(page.allSatisfy { $0.rowID > cursor })
      rows.append(contentsOf: page); cursor = last.rowID
    }
    #expect(rows.count == 600 && Set(rows.map { $0.block.id }).count == 600)
    #expect(try await projection.knowledgeBlockCount() == 600)
    var scope = Set((0..<5_000).map { _ in UUID().uuidString }); scope.insert("a")
    #expect(try await projection.knowledgeBlockPage(limit: 1_000, sourceIDs: scope).count == 600)
    #expect(try await projection.searchKnowledgeBlocks("한국어", sourceIDs: scope).count == 60)
    #expect(try await projection.knowledgeBlockPage(sourceIDs: []).isEmpty)
    #expect(try await projection.searchKnowledgeBlocks("한국어", sourceIDs: []).isEmpty)
    // Literal query terms cannot turn into FTS operators or SQL syntax.
    #expect(try await projection.searchKnowledgeBlocks("\"한국어\" OR unknown*").count == 60)
    let tooManyTerms = (0..<257).map { "term\($0)" }.joined(separator: " ")
    await #expect(throws: WikiError.self) { try await projection.searchKnowledgeBlocks(tooManyTerms) }
  }

  @Test func retainResetAndReadOnlyAccessKeepSourceFiltersConsistent() async throws {
    let fixture = try ProjectionFixture(); defer { fixture.remove() }
    let projection = fixture.projection
    try await projection.replaceKnowledgeDocument(document("a"), blocks: [block("a-0", source: "a", ordinal: 0)])
    try await projection.replaceKnowledgeDocument(document("b"), blocks: [block("b-0", source: "b", ordinal: 0)])
    let readOnly = try WikiProjection(databaseURL: fixture.url, readOnly: true)
    #expect(try await readOnly.knowledgeBlockCount() == 2)
    await #expect(throws: WikiError.self) { try await readOnly.retainKnowledgeDocuments([]) }
    try await projection.retainKnowledgeDocuments(["b"])
    #expect(try await projection.knowledgeDocuments().map(\.id) == ["b"])
    #expect(try await projection.knowledgeBlockCount() == 1)
    #expect(try await projection.searchKnowledgeBlocks("original", sourceIDs: ["a"]).isEmpty)
    #expect(try await projection.searchKnowledgeBlocks("original", sourceIDs: ["b"]).map(\.id) == ["b-0"])
    try await projection.reset()
    #expect(try await projection.knowledgeDocuments().isEmpty)
    #expect(try await projection.knowledgeBlockCount() == 0)
    #expect(try await projection.searchKnowledgeBlocks("original").isEmpty)
  }

  private func document(_ id: String, revision: String = "r1") -> WikiKnowledgeDocumentRecord {
    .init(id: id, revision: revision, producer: "projection-test.v1", payload: "{}")
  }

  private func block(_ id: String, source: String, ordinal: Int, text: String = "original knowledge") -> WikiKnowledgeBlockRecord {
    .init(id: id, sourceID: source, ordinal: ordinal, text: text, payload: "{}")
  }
}

private struct ProjectionFixture {
  let directory: URL
  let url: URL
  let projection: WikiProjection

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioKnowledgeProjection-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    url = directory.appendingPathComponent("projection.sqlite")
    projection = try WikiProjection(databaseURL: url)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
