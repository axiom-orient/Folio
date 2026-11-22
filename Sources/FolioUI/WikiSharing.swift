import CoreTransferable
import Foundation
import FolioKnowledgeApple
import UniformTypeIdentifiers

struct WikiMarkdownShare: Transferable, Sendable {
  let workspace: WikiWorkspace; let path: String; let revision: String; let title: String
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { item in
      SentTransferredFile(try await item.workspace.exportMarkdown(relativePath: item.path, expectedRevision: item.revision))
    }
  }
}
struct WikiArchiveShare: Transferable, Sendable {
  let workspace: WikiWorkspace; let title: String
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .zip) { item in
      SentTransferredFile(try await item.workspace.exportSourceArchive())
    }
  }
}
