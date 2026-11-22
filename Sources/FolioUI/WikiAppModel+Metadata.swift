import FolioKnowledge

extension WikiAppModel {
  @discardableResult
  func updateDocumentMetadata(_ selection: WikiMetadataSelection, title: String, tags: [String]) async -> Bool {
    guard let workspace = admittedDocumentWorkspace(context: selection.context, metadataSelectionID: selection.id) else { return false }
    return await performDocumentMutation(context: selection.context, workspace: workspace, prepare: { () }, apply: { _ in
      let receipt = try await documentLibrary.editMetadata(selection.document, title: title, tags: tags,
        workspace: workspace, context: selection.context)
      return DocumentMutationResult(replacements: [selection.document.id: selection.document.id],
        removedIDs: [], diagnostic: receipt.diagnostic)
    })
  }
}
