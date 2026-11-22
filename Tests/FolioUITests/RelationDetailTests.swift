import Foundation
import FolioKnowledge
import Testing
@testable import FolioUI

struct RelationDetailTests {
  @Test func unconstrainedLinksAreNotPresentedAsTypeCertification() throws {
    let source = try WikiMarkdownParser.document(relativePath: "notes/a.md",
      bytes: Data("---\nid: a\n---\n# First\n[Other](b.md)\n".utf8))
    let target = try WikiMarkdownParser.document(relativePath: "notes/b.md", bytes: Data("---\nid: b\n---\n# Other\n".utf8))
    let identity = try WikiMarkdownParser.workspace(bytes: Data("---\nkind: workspace\nschema: 1\nid: \(UUID())\nname: Fixture\n---\n".utf8))
    let snapshot = WikiSnapshot(workspace: identity, documents: [source, target])
    let valid = try #require(snapshot.relations.first)
    #expect(FolioRelationDetail(relation: valid).explanation.contains("별도 유형 규칙 검증이 적용되지 않았습니다"))
    let unresolved = try #require(WikiSnapshot(workspace: identity, documents: [source]).relations.first)
    #expect(FolioRelationDetail(relation: unresolved).explanation.contains("대상 문서가 없거나"))
  }
}
