import Foundation
import FolioKnowledge

public struct WikiLibraryEntry: Identifiable, Sendable {
  public var id: String { relativePath }
  public let relativePath: String
  public let isDirectory: Bool
  public let revision: String
}

public struct WikiTrashEntry: Identifiable, Sendable {
  public enum State: Sendable, Equatable { case ready, downloading, needsReview }
  public let id: UUID
  public let originalPath: String
  public let deletedAt: Date
  public let isDirectory: Bool
  public let revision: String
  public let state: State
  public var isAvailable: Bool { state == .ready }
  public let metadataAvailable: Bool
  public let diagnostic: String?

  public init(id: UUID, originalPath: String, deletedAt: Date, isDirectory: Bool,
    revision: String, state: State, metadataAvailable: Bool = true, diagnostic: String?
  ) {
    self.id = id; self.originalPath = originalPath; self.deletedAt = deletedAt
    self.isDirectory = isDirectory; self.revision = revision; self.state = state
    self.metadataAvailable = metadataAvailable; self.diagnostic = diagnostic
  }

  public init(id: UUID, originalPath: String, deletedAt: Date, isDirectory: Bool,
    revision: String, isAvailable: Bool, diagnostic: String?
  ) {
    self.init(id: id, originalPath: originalPath, deletedAt: deletedAt, isDirectory: isDirectory,
      revision: revision, state: isAvailable ? .ready : .needsReview, diagnostic: diagnostic)
  }
}

public enum WikiFileOperation: Codable, Sendable {
  case createFolder(path: String)
  case createDocument(path: String, text: String)
  case move(path: String, to: String)
  case trash(path: String)
  case restore(id: UUID)
  case purge(id: UUID)
}

public struct WikiDocumentMove: Codable, Sendable {
  public let oldPath: String
  public let newPath: String
  public let oldID: String
  public let newID: String
}

public struct WikiFileChange: Codable, Sendable {
  public let operationID: UUID
  public let beforePath: String?
  public let afterPath: String?
  public let trashID: UUID?
  public let documentMoves: [WikiDocumentMove]
  public let projectionUpdated: Bool
  public let diagnostic: String?
}

public enum WikiFileOperationError: LocalizedError, Sendable {
  case uncertain(operationID: UUID)
  public var errorDescription: String? {
    switch self {
    case .uncertain(let id): "File operation \(id.uuidString) has an uncertain outcome. Inspect the source and retained operation records before trying a new operation."
    }
  }
}

enum WikiFilePaths {
  static let trash = ".folio-trash"
  static func notes(_ raw: String, allowRoot: Bool = false) throws -> String {
    let path = try WikiPath.validate(raw)
    let components = path.split(separator: "/")
    guard (path.hasPrefix("notes/") || (allowRoot && path == "notes")), components.count <= 32,
      !components.contains(where: { $0.hasPrefix(".") || ["node_modules", "DerivedData"].contains(String($0)) }),
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw WikiError.invalidPath("File management is limited to visible notes/ descendants.")
    }
    return path
  }
  static func moved(_ path: String, from: String, to: String) -> String {
    path == from ? to : path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path
  }
  static func aliasKey(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
  }
}
