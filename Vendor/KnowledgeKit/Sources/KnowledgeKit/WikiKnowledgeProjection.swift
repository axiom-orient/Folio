import Foundation

/// Opaque derived data. The caller verifies the source revision and decodes its own payload.
public struct WikiKnowledgeDocumentRecord: Sendable, Equatable {
  public let id: String
  public let revision: String
  public let producer: String
  public let payload: String

  public init(id: String, revision: String, producer: String, payload: String) {
    self.id = id; self.revision = revision; self.producer = producer; self.payload = payload
  }
}

public struct WikiKnowledgeBlockRecord: Sendable, Equatable {
  public let id: String
  public let sourceID: String
  public let ordinal: Int
  public let text: String
  public let payload: String
  public let vectorModelID: String?
  public let vectorJSON: String?

  public init(id: String, sourceID: String, ordinal: Int, text: String, payload: String,
    vectorModelID: String? = nil, vectorJSON: String? = nil
  ) {
    self.id = id; self.sourceID = sourceID; self.ordinal = ordinal
    self.text = text; self.payload = payload; self.vectorModelID = vectorModelID; self.vectorJSON = vectorJSON
  }
}

public struct WikiKnowledgeBlockRow: Sendable, Equatable {
  public let rowID: Int64
  public let block: WikiKnowledgeBlockRecord

  public init(rowID: Int64, block: WikiKnowledgeBlockRecord) {
    self.rowID = rowID; self.block = block
  }
}

extension WikiProjection {
  private static let englishQuestionStarters: Set<String> = [
    "what", "which", "who", "whose", "where", "when", "why", "how"
  ]
  private static let koreanQuestionEndings: Set<String> = [
    "뭐야", "뭔가요", "무엇인가요", "무엇입니까", "인가요", "입니까",
    "알려줘", "알려주세요", "설명해줘", "설명해주세요", "되나요"
  ]
  private static let questionFunctionWords: Set<String> = englishQuestionStarters.union(koreanQuestionEndings).union([
    "a", "an", "the", "is", "are", "was", "were", "be", "do", "does", "did", "can", "could",
    "to", "of", "for", "in", "on", "and", "or", "it", "me", "you", "please", "tell",
    "무엇", "어떤", "어떻게", "왜", "좀", "주세요"
  ])

  public func knowledgeDocuments() throws -> [WikiKnowledgeDocumentRecord] {
    try database.rows("SELECT id, revision, producer, payload FROM knowledge_documents ORDER BY id").map { row in
      guard let id = row[0], let revision = row[1], let producer = row[2], let payload = row[3] else {
        throw WikiError.database("Invalid knowledge document record; rebuild the projection.")
      }
      return WikiKnowledgeDocumentRecord(id: id, revision: revision, producer: producer, payload: payload)
    }
  }

  /// Replaces one derived document atomically. Vectors are deliberately cleared;
  /// the source-verifying producer must compute them again for the new blocks.
  public func replaceKnowledgeDocument(_ document: WikiKnowledgeDocumentRecord,
    blocks: [WikiKnowledgeBlockRecord]
  ) throws {
    try Task.checkCancellation()
    try Self.knowledgeIdentity(document.id)
    try Self.knowledgeIdentity(document.revision)
    try Self.knowledgeIdentity(document.producer)
    try Self.knowledgeText(document.payload, maximum: 65_536)
    guard blocks.count <= 100_000 else { throw WikiError.invalidSource("Knowledge documents support at most 100,000 blocks.") }
    var identities: Set<String> = []
    for block in blocks {
      try Task.checkCancellation()
      try Self.knowledgeIdentity(block.id)
      guard block.sourceID == document.id, block.ordinal >= 0,
        identities.insert(block.id).inserted else {
        throw WikiError.invalidSource("Knowledge blocks require matching sources and unique identities and nonnegative ordinals.")
      }
      try Self.knowledgeText(block.text, maximum: 32_768)
      try Self.knowledgeText(block.payload, maximum: 65_536)
      if let modelID = block.vectorModelID { try Self.knowledgeIdentity(modelID) }
      if let vector = block.vectorJSON { try Self.knowledgeText(vector, maximum: 65_536) }
    }
    try database.transaction {
      try database.execute("DELETE FROM knowledge_fts WHERE source_id=?", [.text(document.id)])
      try database.execute("DELETE FROM knowledge_documents WHERE id=?", [.text(document.id)])
      try database.execute("INSERT INTO knowledge_documents (id,revision,producer,payload) VALUES (?,?,?,?)",
        [.text(document.id), .text(document.revision), .text(document.producer), .text(document.payload)])
      for block in blocks {
        try Task.checkCancellation()
        try database.execute("INSERT INTO knowledge_blocks (id,source_id,ordinal,text,payload,vector_model_id,vector_json) VALUES (?,?,?,?,?,NULL,NULL)",
          [.text(block.id), .text(block.sourceID), .integer(Int64(block.ordinal)), .text(block.text), .text(block.payload)])
        try database.execute("INSERT INTO knowledge_fts (block_id,source_id,text) VALUES (?,?,?)",
          [.text(block.id), .text(block.sourceID), .text(block.text)])
      }
      try Task.checkCancellation()
    }
  }

  public func retainKnowledgeDocuments(_ ids: Set<String>) throws {
    let scope = try Self.knowledgeScope(ids)
    try Task.checkCancellation()
    try database.transaction {
      try database.execute("DELETE FROM knowledge_fts WHERE source_id IS NULL OR source_id NOT IN (SELECT value FROM json_each(?))", [.text(scope)])
      try database.execute("DELETE FROM knowledge_documents WHERE id NOT IN (SELECT value FROM json_each(?))", [.text(scope)])
    }
  }

  /// A global SQLite rowid cursor, independent of each document's ordinal.
  /// Restart pagination after replacing, retaining or resetting the projection.
  public func knowledgeBlockPage(afterRowID: Int64 = 0, limit: Int = 256,
    sourceIDs: Set<String>? = nil
  ) throws -> [WikiKnowledgeBlockRow] {
    guard afterRowID >= 0, (1...1_000).contains(limit) else {
      throw WikiError.invalidSource("Expected a nonnegative knowledge cursor and limit 1...1,000.")
    }
    let scope = try sourceIDs.map(Self.knowledgeScope)
    if sourceIDs?.isEmpty == true { return [] }
    let filter = scope == nil ? "" : " AND source_id IN (SELECT value FROM json_each(?))"
    var values: [ProjectionDatabase.Value] = [.integer(afterRowID)]
    if let scope { values.append(.text(scope)) }
    values.append(.integer(Int64(limit)))
    return try database.rows("SELECT rowid,id,source_id,ordinal,text,payload,vector_model_id,vector_json FROM knowledge_blocks WHERE rowid>?" + filter + " ORDER BY rowid LIMIT ?", values).map { row in
      guard let rowID = row[0].flatMap(Int64.init), rowID > 0 else {
        throw WikiError.database("Invalid knowledge block cursor; rebuild the projection.")
      }
      return WikiKnowledgeBlockRow(rowID: rowID, block: try Self.knowledgeBlock(Array(row.dropFirst())))
    }
  }

  public func searchKnowledgeBlocks(_ query: String, sourceIDs: Set<String>? = nil,
    limit: Int = 60
  ) throws -> [WikiKnowledgeBlockRecord] {
    guard (1...1_000).contains(limit), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WikiError.invalidSource("Expected a nonempty knowledge query and limit 1...1,000.")
    }
    try Self.knowledgeText(query, maximum: 8_192)
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    let characters = CharacterSet.alphanumerics.union(.nonBaseCharacters)
    let tokens = normalized.components(separatedBy: characters.inverted).filter { !$0.isEmpty }
    var terms = Set(tokens)
    guard terms.count <= 256 else { throw WikiError.invalidSource("Knowledge queries support at most 256 distinct terms; shorten the question.") }
    // Keep short keyword searches literal. In a natural question, matching
    // only a function word should not surface an unrelated block as evidence.
    let looksLikeQuestion = normalized.hasSuffix("?") || normalized.hasSuffix("？")
      || tokens.first.map(Self.englishQuestionStarters.contains) == true
      || tokens.last.map(Self.koreanQuestionEndings.contains) == true
    if tokens.count > 1 && looksLikeQuestion { terms.subtract(Self.questionFunctionWords) }
    let scope = try sourceIDs.map(Self.knowledgeScope)
    if terms.isEmpty || sourceIDs?.isEmpty == true { return [] }
    let expression = terms.sorted().map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " OR ")
    let filter = scope == nil ? "" : " AND b.source_id IN (SELECT value FROM json_each(?))"
    var values: [ProjectionDatabase.Value] = [.text(expression)]
    if let scope { values.append(.text(scope)) }
    values.append(.integer(Int64(limit)))
    let sql = """
      SELECT b.id,b.source_id,b.ordinal,b.text,b.payload,b.vector_model_id,b.vector_json
      FROM knowledge_fts JOIN knowledge_blocks b
      ON b.id=knowledge_fts.block_id AND b.source_id=knowledge_fts.source_id AND b.text=knowledge_fts.text
      WHERE knowledge_fts MATCH ?
      """ + filter + " ORDER BY bm25(knowledge_fts),b.id LIMIT ?"
    return try database.rows(sql, values).map(Self.knowledgeBlock)
  }

  /// The existence check and update are one actor-isolated transaction. A removed
  /// block cannot receive a vector; callers supply content/revision-bound block IDs.
  @discardableResult
  public func storeKnowledgeVector(blockID: String, modelID: String, valueJSON: String) throws -> Bool {
    try Self.knowledgeIdentity(blockID)
    try Self.knowledgeIdentity(modelID)
    try Self.knowledgeText(valueJSON, maximum: 65_536)
    try Task.checkCancellation()
    return try database.transaction {
      try database.execute("UPDATE knowledge_blocks SET vector_model_id=?,vector_json=? WHERE id=?",
        [.text(modelID), .text(valueJSON), .text(blockID)])
      return try database.rows("SELECT changes()").first?.first == "1"
    }
  }

  public func knowledgeBlockCount(sourceIDs: Set<String>? = nil) throws -> Int {
    if sourceIDs?.isEmpty == true { return 0 }
    let values: [ProjectionDatabase.Value] = try sourceIDs.map { [.text(try Self.knowledgeScope($0))] } ?? []
    let filter = values.isEmpty ? "" : " WHERE source_id IN (SELECT value FROM json_each(?))"
    guard let row = try database.rows("SELECT count(*) FROM knowledge_blocks" + filter, values).first,
      let value = row[0], let count = Int(value) else {
      throw WikiError.database("Cannot count knowledge blocks.")
    }
    return count
  }

  private static func knowledgeIdentity(_ value: String) throws {
    guard !value.isEmpty else { throw WikiError.invalidSource("Knowledge identities must not be empty.") }
    try knowledgeText(value, maximum: 512)
  }

  private static func knowledgeText(_ value: String, maximum: Int) throws {
    guard value.utf8.count <= maximum, !value.contains("\0") else {
      throw WikiError.invalidSource("Knowledge value exceeds its \(maximum)-byte limit or contains a null character.")
    }
  }

  /// One bound JSON value avoids SQLite's variable limit for large source scopes.
  private static func knowledgeScope(_ identities: Set<String>) throws -> String {
    guard identities.count <= 100_000 else { throw WikiError.invalidSource("Knowledge source selection is too large.") }
    var minimumBytes = 2
    for identity in identities {
      try knowledgeIdentity(identity)
      minimumBytes += identity.utf8.count + 3
      guard minimumBytes <= 1_048_576 else { throw WikiError.invalidSource("Knowledge source selection exceeds 1 MiB.") }
    }
    let bytes = try JSONEncoder().encode(identities.sorted())
    guard bytes.count <= 1_048_576 else { throw WikiError.invalidSource("Knowledge source selection exceeds 1 MiB.") }
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func knowledgeBlock(_ row: [String?]) throws -> WikiKnowledgeBlockRecord {
    guard row.count == 7, let id = row[0], let sourceID = row[1],
      let ordinal = row[2].flatMap(Int.init), ordinal >= 0, let text = row[3], let payload = row[4],
      (row[5] == nil) == (row[6] == nil) else {
      throw WikiError.database("Invalid knowledge block record; rebuild the projection.")
    }
    return WikiKnowledgeBlockRecord(id: id, sourceID: sourceID, ordinal: ordinal, text: text,
      payload: payload, vectorModelID: row[5], vectorJSON: row[6])
  }
}
