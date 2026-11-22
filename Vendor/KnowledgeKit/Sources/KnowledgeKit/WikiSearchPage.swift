import Foundation

/// Persistable opaque continuation. Its contents are validated against the current source.
public struct WikiSearchCursor: Codable, Hashable, Sendable {
  let token: String
}

public struct WikiSearchPage: Sendable {
  public let hits: [WikiSearchHit]
  public let totalCount: Int
  public let nextCursor: WikiSearchCursor?
  public let coverageComplete: Bool
  public let diagnostics: [WikiDiagnostic]
  public let sourceRevision: String
  public let semanticState: String

  public init(hits: [WikiSearchHit], totalCount: Int, nextCursor: WikiSearchCursor?, coverageComplete: Bool,
    diagnostics: [WikiDiagnostic], sourceRevision: String, semanticState: String
  ) {
    self.hits = hits; self.totalCount = totalCount; self.nextCursor = nextCursor
    self.coverageComplete = coverageComplete; self.diagnostics = diagnostics
    self.sourceRevision = sourceRevision; self.semanticState = semanticState
  }
}

package enum WikiSearchEpoch {
  package static func revision(_ snapshot: WikiSnapshot) throws -> String {
    struct State: Encodable {
      let workspaceID: UUID; let revision: String; let coverageComplete: Bool
      let diagnostics: [WikiDiagnostic]; let stale: [[String]]; let parserVersion: Int
    }
    return try digest(State(workspaceID: snapshot.workspace.id, revision: snapshot.revision,
      coverageComplete: snapshot.coverageComplete, diagnostics: snapshot.diagnostics,
      stale: snapshot.staleDocuments.map { [$0.id, $0.relativePath, $0.revision] }, parserVersion: WikiMarkdownParser.metadataVersion))
  }

  static func digest(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SourceDigest.sha256(try encoder.encode(value))
  }
}

struct WikiSearchContinuation: Codable {
  let version: Int
  let binding: String
  let source: String
  let ranking: String
  let offset: Int

  static func binding(query: String, filter: WikiDocumentFilter, pageSize: Int) throws -> String {
    struct Input: Encodable { let query: String; let filter: WikiDocumentFilter; let pageSize: Int }
    return try WikiSearchEpoch.digest(Input(query: query, filter: filter, pageSize: pageSize))
  }

  static func offset(cursor: WikiSearchCursor?, binding: String, source: String, ranking: String, count: Int) throws -> Int {
    guard let cursor else { return 0 }
    guard cursor.token.utf8.count <= 4096, let bytes = Data(base64Encoded: cursor.token),
      let value = try? JSONDecoder().decode(Self.self, from: bytes), value.version == 1,
      value.offset > 0 else { throw WikiError.invalidSource("Invalid search continuation cursor.") }
    guard value.binding == binding else { throw WikiError.invalidSource("Search cursor does not match the query, filters or page size.") }
    guard value.source == source, value.ranking == ranking else { throw WikiError.changedSource }
    guard value.offset < count else { throw WikiError.invalidSource("Search cursor is outside the result set.") }
    return value.offset
  }

  func cursor() throws -> WikiSearchCursor { WikiSearchCursor(token: try JSONEncoder().encode(self).base64EncodedString()) }
}
