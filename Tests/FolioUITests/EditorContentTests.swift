import Testing
@testable import FolioUI

@Test func bodyEditingPreservesMetadataBytesAndDocumentIdentity() {
  let header = "---\nid: a32c1c5b-e770-4eaf-8236-0bdb730ca38f\ntags: [ai-agent, '한글'] # keep comment\ncustom: |\n  ---\n  기록\n---\n"
  let source = header + "\n# 에이전트\n\n본문\n\n---\n구분선 아래\n"
  let presentation = FolioEditorContent(source: source)
  #expect(presentation.metadata == header)
  #expect(presentation.replacingBody(with: presentation.body) == source)
  #expect(presentation.replacingBody(with: "\n# 에이전트\n\n수정한 본문\n") == header + "\n# 에이전트\n\n수정한 본문\n")
}

@Test func bodyEditingPreservesBOMAndCRLF() {
  let header = "\u{feff}---\r\nid: retained\r\n---\r\n"
  let presentation = FolioEditorContent(source: header + "# 문서\r\n한글 👨‍👩‍👦\r\n")
  #expect(presentation.metadata == header)
  #expect(presentation.body == "# 문서\r\n한글 👨‍👩‍👦\r\n")
  #expect(presentation.replacingBody(with: "# 문서\r\n새 본문\r\n") == header + "# 문서\r\n새 본문\r\n")
}

@Test(arguments: ["", "# 본문\n\n---\n구분선\n", "---\nid: incomplete\n본문\n", "앞말\n---\nid: body\n---\n"])
func ambiguousOrAbsentMetadataRemainsEditable(_ source: String) {
  let presentation = FolioEditorContent(source: source)
  #expect(presentation.metadata.isEmpty)
  #expect(presentation.body == source)
  #expect(presentation.replacingBody(with: source) == source)
}

@Test func appendingBodyToHeaderWithoutFinalNewlineKeepsAValidDelimiter() {
  let presentation = FolioEditorContent(source: "---\nid: retained\n---")
  #expect(presentation.replacingBody(with: "# 본문\n") == "---\nid: retained\n---\n# 본문\n")
  #expect(presentation.replacingBody(with: "") == "---\nid: retained\n---")
}
