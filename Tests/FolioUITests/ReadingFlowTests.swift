import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import Markdown
import Testing
@testable import FolioUI

@Test @MainActor func paragraphBreaksKeepWordsApart() throws {
  let paragraph = try #require(Array(Document(parsing: "첫 문장\n다음 문장  \n마지막 문장").children).first)
  #expect(WikiMarkdownReader.inlineSource(paragraph) == "첫 문장 다음 문장\n마지막 문장")
}

@Test @MainActor func inlineFormattingAndLinksSurviveLineBreaks() throws {
  let paragraph = try #require(Array(Document(parsing: "**중요**\n[연결](other.md)").children).first)
  let formatted = WikiMarkdownReader.inlineSource(paragraph)
  #expect(formatted.contains("**중요** "))
  #expect(formatted.contains("[연결](other.md)"))
}

@Test @MainActor func tableCellsRenderWithoutFormattingTheContainer() throws {
  let table = try #require(Array(Document(parsing: "| 기능 | 결과 |\n| --- | --- |\n| **검색** | [원문](other.md) |\n").children).first as? Markdown.Table)
  let heading = try #require(Array(table.head.children).first)
  let row = try #require(Array(table.body.rows).first)
  let cells = Array(row.children)
  #expect(WikiMarkdownReader.inlineSource(heading) == "기능")
  #expect(WikiMarkdownReader.inlineSource(cells[0]).contains("**검색**"))
  #expect(WikiMarkdownReader.inlineSource(cells[1]).contains("[원문](other.md)"))
}

@Test(arguments: ["#다음-내용", "other.md#다음-내용", "#%EB%8B%A4%EC%9D%8C-%EB%82%B4%EC%9A%A9"])
@MainActor func headingLinksSelectTheActualSection(_ link: String) throws {
  let document = try WikiMarkdownParser.document(relativePath: "notes/other.md",
    bytes: Data("---\nid: other\n---\n# 제목\n\n첫 문장\n\n## 다음 내용\n\n두 번째 문장\n".utf8))
  let window = WikiWindowState()
  window.selectMarkdownLink(link, document: document)
  let section = try #require(document.sections.first { $0.headingPath.last == "다음 내용" })
  #expect(window.selectedDocumentID == document.id)
  #expect(window.selectedSectionID == section.id)
}

@Test @MainActor func navigationKeepsReadingPositionsAndClearsEditing() {
  let window = WikiWindowState()
  window.selectedDocumentID = "first"
  window.readingAnchors["first"] = "first-section"
  window.isEditing = true
  window.selectedDocumentID = "second"
  #expect(!window.isEditing)
  window.goBack()
  #expect(window.selectedDocumentID == "first")
  #expect(window.selectedSectionID == "first-section")
  window.goForward()
  #expect(window.selectedDocumentID == "second")
}

@Test @MainActor func lateNavigationCannotReplaceANewerSelection() {
  let window = WikiWindowState()
  window.selectedDocumentID = "first"
  let oldRequest = window.beginNavigation()
  window.selectedDocumentID = "chosen-by-user"
  #expect(!window.completeNavigation(oldRequest, documentID: "old-result", sectionID: "old-section"))
  #expect(window.selectedDocumentID == "chosen-by-user")
  let current = window.beginNavigation()
  #expect(window.completeNavigation(current, documentID: "current-result", sectionID: "current-section"))
  #expect(window.selectedDocumentID == "current-result")
  #expect(window.selectedSectionID == "current-section")
}

@Test(arguments: ["# 제목", "**강조 아님**", "[링크 아님](file.md)", "백슬래시 \\와 괄호 [ ]", "한국어 문서 📚"])
func newDocumentKeepsTheLiteralTitle(_ title: String) throws {
  let source = FolioInput.documentSource(id: "created-document", title: title, body: "기록한 본문\n")
  let document = try WikiMarkdownParser.document(relativePath: "notes/created.md", bytes: Data(source.utf8))
  #expect(document.id == "created-document")
  #expect(document.title == title)
  #expect(source.hasSuffix("기록한 본문\n"))
}

@Test func attachmentKeepsItsFilenameAndLink() throws {
  let name = "설계: [최종] #1.txt"
  let path = "attachments/id-" + name
  let target = try WikiPath.linkFromNotesDirectory(to: path)
  #expect(target == "../attachments/id-%EC%84%A4%EA%B3%84%3A%20%5B%EC%B5%9C%EC%A2%85%5D%20%231.txt")
  let source = WikiAttachmentImport.noteSource(id: "attachment-document", filename: name, link: target)
  let document = try WikiMarkdownParser.document(relativePath: "notes/attachment.md", bytes: Data(source.utf8))
  #expect(document.title == name)
  #expect(document.declarations.contains { $0.target == target })
  #expect(WikiPath.resolveLink(target, from: document.relativePath) == path)
  #expect(WikiPath.resolveLink("../attachments/id-%EC%84%A4%EA%B3%84:%20%5B%EC%B5%9C%EC%A2%85%5D%20%231.txt",
    from: document.relativePath) == path)
  #expect(WikiPath.resolveLink("#section:one", from: document.relativePath) == document.relativePath)
  for invalid in ["https://example.com/doc", "https%3A%2F%2Fexample.com/doc", "../../outside.pdf", "%2Foutside.pdf"] {
    #expect(WikiPath.resolveLink(invalid, from: document.relativePath) == nil)
  }
}

@Test func namesRejectEmptyMultilineAndOversizedInput() {
  #expect(FolioInput.name("  내 문서  ") == "내 문서")
  #expect(FolioInput.name(" \t ") == nil)
  #expect(FolioInput.name("첫 줄\n다음 줄") == nil)
  #expect(FolioInput.name("이름\0") == nil)
  #expect(FolioInput.name(String(repeating: "가", count: 171)) == nil)
}

@Test func retainedLocalSourceAndCloudCopyHaveDistinctRowIdentities() {
  let id = UUID()
  let local = FolioLibraryIdentity(location: .localManaged(workspaceID: id), workspaceID: id)
  let cloud = FolioLibraryIdentity(location: .managedCloud(containerIdentifier: "iCloud.com.axient.Folio", workspaceID: id), workspaceID: id)
  #expect(local != cloud)
  #expect(Set([local, cloud]).count == 2)
  let stored = try? JSONEncoder().encode(Set([local, cloud]))
  let restored = stored.flatMap { try? JSONDecoder().decode(Set<FolioLibraryIdentity>.self, from: $0) }
  #expect(restored == Set([local, cloud]))
  #expect(local == FolioLibraryIdentity(location: .localManaged(workspaceID: id), workspaceID: id))
}

@Test func libraryRowAccessibilityIdentifiersDistinguishLocations() {
  let workspace = UUID(uuidString: "0aad1085-a55f-4571-bf32-d96df65cc2a8")!
  let otherWorkspace = UUID(uuidString: "8231965d-1c28-4d16-bfef-e2b381304cb9")!
  let identities: [FolioLibraryIdentity] = [
    .cloud("iCloud.com.axient.Folio", workspace),
    .cloud("iCloud.com.axient.Folio", otherWorkspace),
    .cloud("iCloud.com.other.Folio", workspace),
    .cloud(nil, workspace),
    .cloud("", workspace),
    .local(workspace),
    .external(workspace)
  ]
  let identifiers = identities.map(\.accessibilityIdentifier)
  #expect(Set(identifiers).count == identities.count)
  #expect(identifiers[0] == "folio-library.cloud.container.aUNsb3VkLmNvbS5heGllbnQuRm9saW8=.0aad1085-a55f-4571-bf32-d96df65cc2a8")
}
