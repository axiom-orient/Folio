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
    access.revoke()
    await #expect(throws: (any Error).self) { try await session.readKnowledgeEvidence(evidence) }
    await #expect(throws: (any Error).self) { try await session.knowledgeAnswer("광합성") }
    #expect(try Data(contentsOf: note) == bytes)
    try await session.close()
    await #expect(throws: FolioError.noWorkspace) { try await session.readKnowledgeEvidence(evidence) }
  }
}
