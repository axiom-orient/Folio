import Foundation
import Testing
@testable import FolioUI

@MainActor @Suite struct KnowledgePresentationTests {
  @Test func savedNoteNavigationKeepsTheOriginalQueryPresentationUntilDismissalOrWorkspaceReset() throws {
    let window = WikiWindowState()
    let context = FolioDocumentContext(root: URL(fileURLWithPath: "/FolioPresentationSource"), generation: 3)
    window.selectedDocumentID = "original"
    window.query = "열전도율"
    let request = WikiWindowState.KnowledgeRequest(documentID: "original", initialQuestion: window.query,
      context: context, workspaceGeneration: 7)
    window.knowledgeRequest = request

    // A successful explicit save selects the created note before the query dismisses.
    let navigation = window.beginNavigation()
    #expect(window.completeNavigation(navigation, documentID: "saved-note", sectionID: nil))
    window.query = ""
    #expect(window.knowledgeRequest?.id == request.id)
    #expect(window.knowledgeRequest?.documentID == "original")
    #expect(window.knowledgeRequest?.initialQuestion == "열전도율")
    #expect(window.knowledgeRequest?.context == context)
    #expect(window.knowledgeRequest?.workspaceGeneration == 7)

    window.knowledgeRequest = nil
    #expect(window.knowledgeRequest == nil && window.selectedDocumentID == "saved-note")
    window.knowledgeRequest = request
    window.resetNavigation()
    #expect(window.knowledgeRequest == nil)
  }
}
