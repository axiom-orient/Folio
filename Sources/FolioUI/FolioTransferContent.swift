import FolioNearbyTransport
import CoreTransferable
import Foundation

/// Routing for a regular transfer file; directory import intents are separate.
enum FolioTransferFileKind: Equatable {
  case document, archive, attachment

  init(url: URL) {
    switch url.pathExtension.lowercased() {
    case "md", "markdown": self = .document
    case "zip": self = .archive
    default: self = .attachment
    }
  }
}

struct FolioReceivedShare: Transferable, Sendable {
  let owner: FolioNearbyModel
  let transferID: AcornryTransferID
  let file: AcornrySavedFile
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .data) { item in
      let original = try await item.owner.validatedFile(item.file, transferID: item.transferID)
      return SentTransferredFile(try await FolioTransferStorage.copyForSending(original))
    }
  }
}

enum FolioSendSource: Identifiable {
  case document(WikiMarkdownShare), archive(WikiArchiveShare), file(URL)
  var id: String {
    switch self {
    case .document(let value): "document:\(value.path):\(value.revision)"
    case .archive(let value): "archive:\(value.title)"
    case .file(let url): url.absoluteString
    }
  }
  var title: String {
    switch self {
    case .document(let value): value.title
    case .archive(let value): value.title + ".zip"
    case .file(let url): url.lastPathComponent
    }
  }
  func prepare(in transfer: FolioNearbyModel) async throws -> URL {
    let original: URL
    switch self {
    case .document(let value):
      original = try await value.workspace.exportMarkdown(relativePath: value.path, expectedRevision: value.revision)
    case .archive(let value): original = try await value.workspace.exportSourceArchive()
    case .file(let url): original = url
    }
    return try await transfer.prepareFile(original)
  }
}

