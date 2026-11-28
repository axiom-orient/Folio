import Foundation

/// Derived terminology data. Apple consumers validate and decode the evidence payloads.
public struct WikiOntologyMentionRecord: Sendable, Equatable {
  public let id: String
  public let sourceID: String
  /// The source's indexRevision, including its owning document revision.
  public let sourceRevision: String
  public let payload: String
  public init(id: String, sourceID: String, sourceRevision: String, payload: String) {
    self.id = id; self.sourceID = sourceID; self.sourceRevision = sourceRevision; self.payload = payload
  }
}

public struct WikiOntologyProjectionRecord: Sendable, Equatable {
  public let id: String
  public let revision: String
  public let payload: String
  public let labels: [WikiConceptLabel]
  public let mentions: [WikiOntologyMentionRecord]
  public init(id: String, revision: String, payload: String, labels: [WikiConceptLabel], mentions: [WikiOntologyMentionRecord]) {
    self.id = id; self.revision = revision; self.payload = payload; self.labels = labels; self.mentions = mentions
  }
}

public struct WikiOntologyConceptMatch: Sendable, Equatable {
  public let id: String
  public let revision: String
  public let payload: String
  public let matchedLabel: String
}

public struct WikiOntologyConceptMatches: Sendable, Equatable {
  public let matches: [WikiOntologyConceptMatch]
  public let complete: Bool
}

extension WikiProjection {
  /// Availability is separate from an empty, not-yet-built manifest.
  public func ontologyComponentAvailable() throws -> Bool {
    try database.ensureOntologyComponent()
  }

  /// Rebuilds only this derived component; durable candidate and writer state are elsewhere.
  public func replaceOntologyRecords(_ records: [WikiOntologyProjectionRecord], manifestRevision: String) throws {
    guard !database.readOnly, try database.ensureOntologyComponent(forWriting: true) else { throw WikiError.database("Ontology projection is read-only or unavailable.") }
    try Self.ontologyText(manifestRevision, maximum: 512)
    guard !manifestRevision.isEmpty, records.count <= 100_000, Set(records.map(\.id)).count == records.count else {
      throw WikiError.invalidSource("Expected unique ontology records and a manifest revision.")
    }
    for record in records {
      try Task.checkCancellation()
      try Self.ontologyText(record.id, maximum: 512); try Self.ontologyText(record.revision, maximum: 512)
      try Self.ontologyText(record.payload, maximum: 65_536)
      guard !record.id.isEmpty, !record.revision.isEmpty,
        let fields = try WikiJSONValue.parse(Data(record.payload.utf8)).objectValue,
        try WikiOntologyRecord(fields: fields).recordID == record.id,
        record.labels.count <= 64, record.mentions.count <= 256,
        Set(record.mentions.map(\.id)).count == record.mentions.count else {
        throw WikiError.invalidSource("Invalid ontology projection record.")
      }
      for label in record.labels {
        try Self.ontologyText(label.language, maximum: 64)
        try Self.ontologyText(label.preferred, maximum: 512)
        guard !label.language.isEmpty, !Self.ontologyKey(label.preferred).isEmpty, label.aliases.count <= 256 else {
          throw WikiError.invalidSource("Concept labels require language and a preferred name.")
        }
        for alias in label.aliases { try Self.ontologyText(alias, maximum: 512); guard !Self.ontologyKey(alias).isEmpty else { throw WikiError.invalidSource("Empty concept alias.") } }
      }
      for mention in record.mentions {
        try Self.ontologyText(mention.id, maximum: 512); try Self.ontologyText(mention.sourceID, maximum: 512)
        try Self.ontologyText(mention.sourceRevision, maximum: 512); try Self.ontologyText(mention.payload, maximum: 65_536)
        guard !mention.id.isEmpty, !mention.sourceID.isEmpty, !mention.sourceRevision.isEmpty else {
          throw WikiError.invalidSource("Concept mentions require source-bound identities.")
        }
      }
    }
    try database.transaction {
      try database.clearOntologyComponent()
      for record in records {
        try Task.checkCancellation()
        try database.execute("INSERT INTO ontology_records(id,revision,payload) VALUES (?,?,?)", [.text(record.id), .text(record.revision), .text(record.payload)])
        for label in record.labels {
          for name in [label.preferred] + label.aliases {
            let key = Self.ontologyKey(name)
            let phrase: ProjectionDatabase.Value = Self.isOntologyPhrase(key) ? .text(key) : .null
            try database.execute("INSERT OR IGNORE INTO ontology_labels(record_id,label_key,phrase_key,label) VALUES (?,?,?,?)",
              [.text(record.id), .text(key), phrase, .text(name)])
          }
        }
        for mention in record.mentions {
          try database.execute("INSERT INTO ontology_mentions(record_id,id,source_id,source_revision,payload) VALUES (?,?,?,?,?)",
            [.text(record.id), .text(mention.id), .text(mention.sourceID), .text(mention.sourceRevision), .text(mention.payload)])
        }
      }
      try database.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES ('ontology_manifest',?)", [.text(manifestRevision)])
    }
  }

  /// Nil means this component is absent, belongs to an older store epoch or needs rebuilding.
  public func ontologyManifestRevision() throws -> String? {
    guard try database.ensureOntologyComponent() else { return nil }
    return try database.rows("SELECT value FROM metadata WHERE key='ontology_manifest'").first?.first ?? nil
  }

  /// A single phrase arm. No particle stemming or fuzzy merging is performed.
  public func ontologyConceptMatches(query: String, sourceIDs: Set<String>, limit: Int = 60) throws -> WikiOntologyConceptMatches {
    guard (1...60).contains(limit) else { throw WikiError.invalidSource("Concept matching limit must be 1...60.") }
    try Self.ontologyText(query, maximum: 8_192)
    guard try database.ensureOntologyComponent(), !sourceIDs.isEmpty else { return .init(matches: [], complete: true) }
    let scope = try Self.ontologyScope(sourceIDs)
    let exact = Self.ontologyKey(query)
    let characters = CharacterSet.alphanumerics.union(.nonBaseCharacters)
    let words = " " + exact.unicodeScalars.map { characters.contains($0) ? String($0) : " " }.joined()
      .split(whereSeparator: \.isWhitespace).joined(separator: " ") + " "
    let sql = """
      SELECT r.id,r.revision,r.payload,MIN(l.label),
        MIN(CASE WHEN l.label_key=? THEN 0 ELSE 1 END) AS exact_rank,MAX(length(l.label_key)) AS phrase_length
      FROM ontology_records r JOIN ontology_labels l ON l.record_id=r.id
      WHERE (l.label_key=? OR (l.phrase_key IS NOT NULL AND instr(?,' ' || l.phrase_key || ' ')>0))
        AND EXISTS (SELECT 1 FROM ontology_mentions m JOIN knowledge_documents d ON d.id=m.source_id
          WHERE m.record_id=r.id AND m.source_id IN (SELECT value FROM json_each(?)))
      GROUP BY r.id,r.revision,r.payload
      ORDER BY exact_rank,phrase_length DESC,r.id LIMIT ?
      """
    let rows = try database.rows(sql, [.text(exact), .text(exact), .text(words), .text(scope), .integer(Int64(limit + 1))])
    let matches = try rows.prefix(limit).map { row -> WikiOntologyConceptMatch in
      guard let id = row[0], let revision = row[1], let payload = row[2], let label = row[3] else {
        throw WikiError.database("Invalid ontology match; rebuild the component.")
      }
      return .init(id: id, revision: revision, payload: payload, matchedLabel: label)
    }
    return .init(matches: matches, complete: rows.count <= limit)
  }

  /// Caller can ask for limit+1 to report expansion truncation before sending its bounded arm.
  public func ontologyMentions(recordIDs: Set<String>, sourceIDs: Set<String>, limit: Int = 60) throws -> [WikiOntologyMentionRecord] {
    guard (1...1_000).contains(limit) else { throw WikiError.invalidSource("Mention limit must be 1...1,000.") }
    guard try database.ensureOntologyComponent(), !recordIDs.isEmpty, !sourceIDs.isEmpty else { return [] }
    let records = try Self.ontologyScope(recordIDs), sources = try Self.ontologyScope(sourceIDs)
    let sql = """
      SELECT m.id,m.source_id,m.source_revision,m.payload
      FROM ontology_mentions m JOIN knowledge_documents d ON d.id=m.source_id AND d.revision=m.source_revision
      WHERE m.record_id IN (SELECT value FROM json_each(?)) AND m.source_id IN (SELECT value FROM json_each(?))
      GROUP BY m.id,m.source_id,m.source_revision,m.payload ORDER BY m.id,m.source_id LIMIT ?
      """
    return try database.rows(sql, [.text(records), .text(sources), .integer(Int64(limit))]).map { row in
      guard let id = row[0], let sourceID = row[1], let revision = row[2], let payload = row[3] else {
        throw WikiError.database("Invalid ontology mention; rebuild the component.")
      }
      return .init(id: id, sourceID: sourceID, sourceRevision: revision, payload: payload)
    }
  }

  private static func ontologyText(_ value: String, maximum: Int) throws {
    guard value.utf8.count <= maximum, !value.contains("\0") else { throw WikiError.invalidSource("Ontology value exceeds its byte limit or contains a null character.") }
  }
  private static func ontologyScope(_ ids: Set<String>) throws -> String {
    guard ids.count <= 100_000 else { throw WikiError.invalidSource("Ontology source selection is too large.") }
    var minimumBytes = 2
    for id in ids {
      try ontologyText(id, maximum: 512)
      guard !id.isEmpty else { throw WikiError.invalidSource("Empty ontology identity.") }
      minimumBytes += id.utf8.count + 3
      guard minimumBytes <= 1_048_576 else { throw WikiError.invalidSource("Ontology source selection exceeds 1 MiB.") }
    }
    let bytes = try JSONEncoder().encode(ids.sorted())
    guard bytes.count <= 1_048_576 else { throw WikiError.invalidSource("Ontology source selection exceeds 1 MiB.") }
    return String(decoding: bytes, as: UTF8.self)
  }
  private static func ontologyKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
  private static func isOntologyPhrase(_ value: String) -> Bool {
    let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(.whitespaces)
    return value.unicodeScalars.allSatisfy(allowed.contains)
  }
}
