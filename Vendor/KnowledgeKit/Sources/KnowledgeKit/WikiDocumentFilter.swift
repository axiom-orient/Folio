import Foundation

public enum WikiDocumentTypeFilter: Codable, Hashable, Sendable {
  case all
  case untyped
  case named(String)
}

/// Immutable document predicates shared by browsing and paginated search.
public struct WikiDocumentFilter: Codable, Hashable, Sendable {
  public let folder: String?
  public let tag: String?
  public let documentType: WikiDocumentTypeFilter

  public init(folder: String? = nil, tag: String? = nil, documentType: WikiDocumentTypeFilter = .all) {
    self.folder = folder?.precomposedStringWithCanonicalMapping
    self.tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    self.documentType = documentType
  }

  public func matches(_ document: WikiDocument) -> Bool {
    if let folder, !document.relativePath.hasPrefix(folder + "/") { return false }
    if let tag, !document.tags.contains(where: { WikiTags.key($0) == WikiTags.key(tag) }) { return false }
    switch documentType {
    case .all: return true
    case .untyped: return document.type == nil
    case .named(let type): return document.type == type
    }
  }

  package func validate() throws {
    if let folder { _ = try WikiPath.validate(folder) }
    if let tag { _ = try WikiTags.normalize([tag]) }
    if case .named(let type) = documentType {
      guard !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, type.utf8.count <= 512,
        !type.contains("\0") else { throw WikiError.invalidSource("Expected a nonempty document type of at most 512 UTF-8 bytes.") }
    }
  }
}
