import Foundation
import Testing
@testable import FolioUI

@Test func metadataChangesRefreshOnlyTheAdmittedTextWorkspace() {
  let root = URL(fileURLWithPath: "/cloud/Workspaces/research", isDirectory: true)
  #expect(FolioCloudSourceChange.affectsText(paths: ["/cloud/Workspaces/research/notes/react.md"], root: root))
  #expect(FolioCloudSourceChange.affectsText(paths: ["/cloud/Workspaces/research/notes/MCP.markdown"], root: root))
  #expect(FolioCloudSourceChange.affectsText(paths: ["/cloud/Workspaces/research/_ontology.md"], root: root))
  #expect(FolioCloudSourceChange.affectsText(paths: ["/cloud/Workspaces/research/notes/reorganized"], root: root))
  #expect(FolioCloudSourceChange.affectsText(paths: ["/cloud/Workspaces/research/.folio-trash/id/record.json"], root: root))
  #expect(!FolioCloudSourceChange.affectsText(paths: ["/cloud/Workspaces/research-other/notes/react.md"], root: root))
  #expect(!FolioCloudSourceChange.affectsText(paths: ["/cloud/Workspaces/research/notes/../../other/notes/react.md"], root: root))
  #expect(!FolioCloudSourceChange.affectsText(paths: ["/cloud/Workspaces/research/attachments/diagram.png"], root: root))
  #expect(!FolioCloudSourceChange.affectsText(paths: [], root: root))
}
