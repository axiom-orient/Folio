import Foundation
import FolioKnowledge
import Testing
@testable import FolioUI

@Suite struct SearchExcerptTests {
  @Test func matchingParagraphBeyondIndexedPrefixKeepsTheActualWords() throws {
    let fixture = try searchExcerptFixture()
    #expect(!fixture.hit.snippet.contains("MCP"))

    let excerpt = fixture.hit.folioExcerpt(query: "mcp", snapshot: fixture.snapshot)

    #expect(excerpt.text == "MCP는 외부 도구를 연결하는 프로토콜이다. 연결된 권한은 실행 전에 확인한다.")
    #expect(!excerpt.text.contains("소개 문단"))
    #expect(!excerpt.text.contains("…"))
    #expect(String(excerpt.emphasizing("mcp").characters) == excerpt.text)
  }

  @Test func staleSnapshotCannotReplaceTheIndexedExcerptWithNewerText() throws {
    let fixture = try searchExcerptFixture()
    let changed = try WikiMarkdownParser.document(relativePath: fixture.document.relativePath,
      bytes: Data("---\nid: agent-research\n---\n# AI agent 조사\n\nMCP의 새 조사 내용은 아직 이 검색 결과의 근거가 아니다.\n".utf8))
    let newerSnapshot = WikiSnapshot(workspace: fixture.snapshot.workspace, documents: [changed])

    let excerpt = fixture.hit.folioExcerpt(query: "MCP", snapshot: newerSnapshot)

    #expect(excerpt.text == fixture.hit.folioSnippet)
    #expect(excerpt.text.contains("소개 문단"))
    #expect(!excerpt.text.contains("새 조사 내용"))
  }

  @Test(arguments: ["workspaceID", "documentID", "sourceRevision", "sectionID", "excerptSHA256", "relativePath", "range"])
  func mismatchedReferenceKeepsItsOwnSnippet(field: String) throws {
    let fixture = try searchExcerptFixture()
    let encoded = try JSONEncoder().encode(fixture.hit)
    let decoded = try JSONSerialization.jsonObject(with: encoded)
    var fields = try #require(decoded as? [String: Any])
    var reference = try #require(fields["reference"] as? [String: Any])
    switch field {
    case "workspaceID": reference[field] = "F0C4461C-015E-4C46-812A-F83EFDC7639F"
    case "range":
      var range = try #require(reference[field] as? [String: Any])
      range["lowerBound"] = fixture.hit.reference.range.lowerBound + 1
      reference[field] = range
    default: reference[field] = "another-source"
    }
    fields["reference"] = reference
    let hit = try JSONDecoder().decode(WikiSearchHit.self, from: JSONSerialization.data(withJSONObject: fields))

    #expect(hit.folioExcerpt(query: "MCP", snapshot: fixture.snapshot).text == hit.folioSnippet)
  }

  @Test func unavailableSourceAndSemanticOnlyMatchKeepTheHitSnippet() throws {
    let fixture = try searchExcerptFixture()
    #expect(fixture.hit.folioExcerpt(query: "MCP", snapshot: nil).text == fixture.hit.folioSnippet)
    #expect(fixture.hit.folioExcerpt(query: "unwritten-term", snapshot: fixture.snapshot).text == fixture.hit.folioSnippet)
  }

  @Test func emphasisPreservesTextAcrossCaseAndDiacriticDifferences() throws {
    let fixture = try searchExcerptFixture()
    let encoded = try JSONEncoder().encode(fixture.hit)
    let decoded = try JSONSerialization.jsonObject(with: encoded)
    var fields = try #require(decoded as? [String: Any])
    fields["snippet"] = "MCP의 연결과 École의 사례, mcp를 비교한다."
    let hit = try JSONDecoder().decode(WikiSearchHit.self, from: JSONSerialization.data(withJSONObject: fields))
    let excerpt = hit.folioExcerpt(query: "mcp ecole", snapshot: nil)

    let emphasized = excerpt.emphasizing("mcp ecole")
    let matches = emphasized.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
      .map { String(emphasized[$0.range].characters) }

    #expect(String(emphasized.characters) == "MCP의 연결과 École의 사례, mcp를 비교한다.")
    #expect(matches == ["MCP", "École", "mcp"])
  }
}

private func searchExcerptFixture() throws -> (snapshot: WikiSnapshot, document: WikiDocument, hit: WikiSearchHit) {
  let introduction = String(repeating: "소개 문단은 에이전트의 역할과 판단 범위를 설명한다. ", count: 40)
  let source = """
    ---
    id: agent-research
    ---
    # AI agent 조사

    \(introduction)

    **MCP**는 외부 도구를 연결하는 프로토콜이다. [연결된 권한](permissions.md)은 실행 전에 확인한다.
    """
  let document = try WikiMarkdownParser.document(relativePath: "notes/agent-research.md", bytes: Data(source.utf8))
  let section = try #require(document.sections.first { $0.sourceText.contains("**MCP**") })
  let workspace = try JSONDecoder().decode(WikiWorkspaceIdentity.self,
    from: Data(#"{"id":"6D9D108B-F2C7-4B1C-AF5B-AC04F8F72117","name":"AI agent"}"#.utf8))
  let reference = WikiEvidenceReference(workspaceID: workspace.id, document: document, section: section)
  let referenceFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference))
  let fields: [String: Any] = ["title": document.title, "breadcrumb": section.headingPath,
    "snippet": String(section.sourceText.prefix(512)), "reference": referenceFields,
    "provenance": ["fts"], "fusedRank": 1]
  let hit = try JSONDecoder().decode(WikiSearchHit.self, from: JSONSerialization.data(withJSONObject: fields))
  return (WikiSnapshot(workspace: workspace, documents: [document]), document, hit)
}
