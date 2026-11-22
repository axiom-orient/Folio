import CryptoKit
import Foundation

public enum WikiError: Error, LocalizedError, Sendable, Equatable {
  case invalidSource(String)
  case invalidPath(String)
  case changedSource
  case unavailable(String)
  case conflict(String)
  case database(String)

  public var errorDescription: String? {
    switch self {
    case .invalidSource(let message), .invalidPath(let message), .unavailable(let message),
      .conflict(let message), .database(let message): message
    case .changedSource: "The source changed. Search/read it again before continuing."
    }
  }
}

public enum SourceDigest {
  public static func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  public static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
}

/// Half-open offsets into original UTF-8 bytes; lines are 1-based, inclusive.
public struct WikiSourceRange: Codable, Hashable, Sendable {
  public let lowerBound: Int
  public let upperBound: Int
  public let startLine: Int
  public let endLine: Int

  public init(lowerBound: Int, upperBound: Int, startLine: Int, endLine: Int) {
    self.lowerBound = lowerBound; self.upperBound = upperBound
    self.startLine = startLine; self.endLine = endLine
  }
  public func extract(from bytes: Data) throws -> Data {
    guard lowerBound >= 0, upperBound >= lowerBound, upperBound <= bytes.count,
      startLine > 0, endLine >= startLine
    else { throw WikiError.invalidSource("Invalid original-byte range.") }
    return bytes.subdata(in: lowerBound..<upperBound)
  }
}

public struct WikiSection: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let documentID: String
  public let ordinal: Int
  public let headingPath: [String]
  public let range: WikiSourceRange
  public let sourceText: String
  public let searchText: String
  public let contentHash: String
}

public struct WikiDocument: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let stableID: String?
  public let relativePath: String
  public let title: String
  public let type: String?
  public let aliases: [String]
  public let tags: [String]
  /// Cached records from an older parser must be refreshed from authoritative bytes.
  package let metadataVersion: Int
  public let revision: String
  public let sections: [WikiSection]
  public let declarations: [WikiRelationDeclaration]

  enum CodingKeys: String, CodingKey {
    case id, stableID, relativePath, title, type, aliases, tags, metadataVersion, revision, sections, declarations
  }

  init(id: String, stableID: String?, relativePath: String, title: String, type: String?, aliases: [String],
    tags: [String], revision: String, sections: [WikiSection], declarations: [WikiRelationDeclaration]
  ) {
    self.id = id; self.stableID = stableID; self.relativePath = relativePath; self.title = title
    self.type = type; self.aliases = aliases; self.tags = tags; metadataVersion = WikiMarkdownParser.metadataVersion
    self.revision = revision; self.sections = sections; self.declarations = declarations
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id); stableID = try values.decodeIfPresent(String.self, forKey: .stableID)
    relativePath = try values.decode(String.self, forKey: .relativePath); title = try values.decode(String.self, forKey: .title)
    type = try values.decodeIfPresent(String.self, forKey: .type); aliases = try values.decode([String].self, forKey: .aliases)
    tags = try WikiTags.normalize(values.decodeIfPresent([String].self, forKey: .tags) ?? [])
    metadataVersion = values.contains(.tags) ? (try values.decodeIfPresent(Int.self, forKey: .metadataVersion) ?? 0) : 0
    revision = try values.decode(String.self, forKey: .revision); sections = try values.decode([WikiSection].self, forKey: .sections)
    declarations = try values.decode([WikiRelationDeclaration].self, forKey: .declarations)
  }
}

public struct WikiRelationDeclaration: Codable, Hashable, Sendable {
  public enum Origin: String, Codable, Sendable { case frontmatter, markdownLink }
  public let predicate: String
  public let target: String
  public let origin: Origin
  public let range: WikiSourceRange
}

public struct WikiRelation: Codable, Hashable, Sendable {
  public enum Status: String, Codable, Sendable { case valid, invalid, unresolved }
  public let sourceID: String
  public let sourceRevision: String
  public let predicate: String
  public let targetID: String
  public let targetRevision: String?
  public let ontologyRevision: String?
  public let origin: WikiRelationDeclaration.Origin
  public let range: WikiSourceRange
  public let status: Status
  public let diagnostic: String?
}

public struct WikiDiagnostic: Codable, Hashable, Sendable {
  public let path: String
  public let reason: String
  public init(path: String, reason: String) { self.path = path; self.reason = reason }
}

public struct WikiWorkspaceIdentity: Codable, Hashable, Sendable {
  public let id: UUID
  public let name: String
}

public struct WikiEvidenceReference: Codable, Hashable, Sendable {
  public let workspaceID: UUID
  public let documentID: String
  public let sectionID: String
  public let relativePath: String
  public let sourceRevision: String
  public let range: WikiSourceRange
  public let excerptSHA256: String

  public init(workspaceID: UUID, document: WikiDocument, section: WikiSection) {
    self.workspaceID = workspaceID; documentID = document.id; sectionID = section.id
    relativePath = document.relativePath; sourceRevision = document.revision
    range = section.range; excerptSHA256 = section.contentHash
  }

  /// Search projections are candidates. Current bytes are the evidence authority.
  public func resolve(currentBytes: Data) throws -> String {
    try resolve(currentBytes: currentBytes, verifiedSourceRevision: SourceDigest.sha256(currentBytes))
  }

  /// The source owner may reuse one digest across a batch bound to these exact bytes.
  package func resolve(currentBytes: Data, verifiedSourceRevision: String) throws -> String {
    guard verifiedSourceRevision == sourceRevision else { throw WikiError.changedSource }
    let excerpt = try range.extract(from: currentBytes)
    guard SourceDigest.sha256(excerpt) == excerptSHA256,
      let text = String(data: excerpt, encoding: .utf8)
    else { throw WikiError.invalidSource("Evidence digest/range mismatch.") }
    return text
  }
}

public enum WikiSearchSource: String, Codable, Hashable, Sendable { case exact, fts, spotlight, semantic }

public struct WikiSearchHit: Codable, Sendable, Identifiable {
  public var id: String { reference.sectionID }
  public let title: String
  public let breadcrumb: [String]
  public let snippet: String
  public let reference: WikiEvidenceReference
  public let provenance: Set<WikiSearchSource>
  public let fusedRank: Int
}

public struct WikiSearchResult: Codable, Sendable {
  public let hits: [WikiSearchHit]
  public let diagnostics: [WikiDiagnostic]
  public let coverageComplete: Bool
  public let semanticState: String
  public let resultsTruncated: Bool

  public init(hits: [WikiSearchHit], diagnostics: [WikiDiagnostic], coverageComplete: Bool,
    semanticState: String, resultsTruncated: Bool
  ) {
    self.hits = hits; self.diagnostics = diagnostics; self.coverageComplete = coverageComplete
    self.semanticState = semanticState; self.resultsTruncated = resultsTruncated
  }
}

public struct WikiRawExcerpt: Codable, Sendable {
  public let sourceRevision: String
  public let range: WikiSourceRange
  public let text: String
  public let hasMore: Bool
}

public enum WikiPath {
  public static func validate(_ path: String) throws -> String {
    guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"),
      !path.contains("\\"), !path.contains("\0"),
      !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
        $0.isEmpty || $0 == "." || $0 == ".."
      })
    else { throw WikiError.invalidPath(path) }
    return path
  }

  public static func resolveLink(_ link: String, from source: String) -> String? {
    guard !link.contains(":"), !link.hasPrefix("/"), !link.contains("\\") else { return nil }
    let path = String(link.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
    guard let decoded = path.removingPercentEncoding,
      !decoded.contains(":"), !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains("\0")
    else { return nil }
    if decoded.isEmpty { return source }
    var components = source.split(separator: "/").dropLast().map(String.init)
    for component in decoded.split(separator: "/") {
      if component == "." { continue }
      if component == ".." {
        guard !components.isEmpty else { return nil }; components.removeLast()
      } else { components.append(String(component)) }
    }
    return try? validate(components.joined(separator: "/"))
  }
}
