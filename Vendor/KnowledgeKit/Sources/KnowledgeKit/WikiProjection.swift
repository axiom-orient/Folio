import Foundation

public actor WikiProjection {
  let database: ProjectionDatabase
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()
  private var scanGenerations: [UUID: UInt64] = [:]
  private var cachedSnapshot: WikiSnapshot?
  private var cachedSnapshotToken: String?
  private var reconciledAdapters: Set<String> = []

  public init(databaseURL: URL, readOnly: Bool = false) throws {
    database = try ProjectionDatabase(url: databaseURL, readOnly: readOnly)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; self.encoder = encoder
  }

  public func snapshot() throws -> WikiSnapshot? {
    let token = try database.rows("SELECT value FROM metadata WHERE key='snapshot_token'").first?.first ?? nil
    if let token, token == cachedSnapshotToken, let cachedSnapshot { return cachedSnapshot }
    guard let row = try database.rows("SELECT snapshot.value, token.value FROM metadata snapshot LEFT JOIN metadata token ON token.key='snapshot_token' WHERE snapshot.key='snapshot'").first,
      let value = row[0] else { cachedSnapshot = nil; cachedSnapshotToken = nil; reconciledAdapters = []; return nil }
    let decoded = try decoder.decode(WikiSnapshot.self, from: Data(value.utf8))
    let documents = decoded.documents
    let sections = documents.flatMap(\.sections)
    guard Set(documents.map(\.id)).count == documents.count,
      (documents + decoded.staleDocuments).allSatisfy({ Array($0.id.utf8) == Array($0.id.precomposedStringWithCanonicalMapping.utf8) }),
      Set(documents.map(\.relativePath)).count == documents.count,
      Set(sections.map(\.id)).count == sections.count,
      documents.allSatisfy({ document in document.sections.allSatisfy { section in
        section.documentID == document.id && section.range.lowerBound >= 0 && section.range.upperBound >= section.range.lowerBound
          && section.range.upperBound - section.range.lowerBound == section.sourceText.utf8.count
          && section.contentHash == SourceDigest.sha256(section.sourceText)
      } }) else { throw WikiError.database("Projection integrity failed; rebuild it from source.") }
    cachedSnapshot = decoded; cachedSnapshotToken = row[1]; reconciledAdapters = []
    return decoded
  }

  /// Explicit local-cache recovery. Source and operation receipts are untouched.
  public func reset() throws {
    try database.transaction {
      try database.execute("DELETE FROM fts_sections")
      try database.execute("DELETE FROM documents")
      try database.execute("DELETE FROM index_jobs")
      try database.execute("DELETE FROM derived_values")
      try database.execute("DELETE FROM knowledge_fts")
      try database.execute("DELETE FROM knowledge_documents")
      try database.execute("DELETE FROM metadata WHERE key IN ('snapshot','snapshot_token')")
      try database.execute("UPDATE metadata SET value=? WHERE key='store_id'", [.text(UUID().uuidString)])
    }
    cachedSnapshot = nil; cachedSnapshotToken = nil; reconciledAdapters = []
  }

  public func storeID() throws -> String {
    guard let value = try database.rows("SELECT value FROM metadata WHERE key='store_id'").first?.first ?? nil else {
      throw WikiError.database("Missing projection identity.")
    }
    return value
  }

  @discardableResult
  public func apply(_ scan: WikiScan, adapters: [String] = ["spotlight"], sequence: WikiScanSequence? = nil) throws -> WikiSnapshot {
    try Task.checkCancellation()
    let previous = try snapshot()
    guard previous == nil || previous?.workspace.id == scan.workspace.id else {
      throw WikiError.database("A projection cannot be shared by different workspaces.")
    }
    if let sequence, let applied = scanGenerations[sequence.ownerID], sequence.generation <= applied, let previous {
      return previous
    }
    let incomingPaths = Set(scan.documents.map(\.relativePath))
    var active = scan.documents; var stale: [WikiDocument] = []
    for document in previous?.documents ?? [] where !incomingPaths.contains(document.relativePath) {
      if scan.observedPaths.contains(document.relativePath) { stale.append(document) }
      else if !scan.enumerationComplete { active.append(document) }
    }
    for document in previous?.staleDocuments ?? [] where !incomingPaths.contains(document.relativePath) {
      if scan.observedPaths.contains(document.relativePath) || !scan.enumerationComplete { stale.append(document) }
    }
    let result = WikiSnapshot(workspace: scan.workspace, documents: active, staleDocuments: stale,
      ontology: scan.ontology, ontologyUnavailable: scan.ontologyUnavailable,
      diagnostics: scan.diagnostics, coverageComplete: scan.enumerationComplete)
    // A refresh still scans and hashes the source. Skip only rebuilding an
    // identical projection that this owner already reconciled for these adapters.
    // Revision alone omits stale documents, diagnostics and incomplete coverage.
    let unchanged = previous.map { old in
      old.workspace == result.workspace && old.documents == result.documents
        && old.staleDocuments == result.staleDocuments && old.ontology == result.ontology
        && old.ontologyUnavailable == result.ontologyUnavailable && old.relations == result.relations
        && old.diagnostics == result.diagnostics && old.coverageComplete == result.coverageComplete
        && old.revision == result.revision
    } ?? false
    if unchanged, cachedSnapshotToken != nil, Set(adapters).isSubset(of: reconciledAdapters), let previous {
      if let sequence { scanGenerations[sequence.ownerID] = sequence.generation }
      return previous
    }
    let oldItems = Dictionary(uniqueKeysWithValues: (previous?.indexedItems() ?? []).map { ($0.id, $0) })
    let newItems = Dictionary(uniqueKeysWithValues: result.indexedItems().map { ($0.id, $0) })
    let currentIDs = Set(result.documents.map(\.id))
    let records = result.documents + result.staleDocuments.filter { !currentIDs.contains($0.id) }
    let previousRecords = (previous?.documents ?? []) + (previous?.staleDocuments ?? [])
    let oldByID = Dictionary(previousRecords.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let oldActive = Set(previous?.documents.map(\.id) ?? [])
    let changedIDs = Set(records.filter { document in
      oldByID[document.id] != document || oldActive.contains(document.id) != currentIDs.contains(document.id)
    }.map(\.id))
    let removedIDs = Set(oldByID.keys).subtracting(records.map(\.id))
    let needsSnapshotWrite = !unchanged || cachedSnapshotToken == nil
    let snapshotToken = unchanged ? (cachedSnapshotToken ?? UUID().uuidString) : UUID().uuidString
    try database.transaction {
      // Delete every changed path first so moves/path swaps cannot collide with an old UNIQUE row.
      for id in changedIDs.union(removedIDs) {
        try database.execute("DELETE FROM fts_sections WHERE section_id IN (SELECT id FROM sections WHERE document_id=?)", [.text(id)])
        try database.execute("DELETE FROM documents WHERE id=?", [.text(id)])
      }
      for document in records where changedIDs.contains(document.id) {
        try database.execute("INSERT INTO documents VALUES (?,?,?,?,?)", [.text(document.id), .text(document.relativePath),
          .text(document.revision), .integer(currentIDs.contains(document.id) ? 1 : 0), .text(try json(document))])
        for section in document.sections {
          try database.execute("INSERT INTO sections VALUES (?,?,?,?)", [.text(section.id), .text(document.id),
            .integer(Int64(section.ordinal)), .text(try json(section))])
          if currentIDs.contains(document.id) {
            try database.execute("INSERT INTO fts_sections VALUES (?,?)", [.text(section.id), .text(section.searchText)])
          }
        }
      }
      for adapter in Set(adapters) {
        for (id, item) in newItems {
          try desire(adapter: adapter, subject: id, hash: item.desiredHash, operation: .upsert, item: item)
        }
        for (id, old) in oldItems where newItems[id] == nil {
          try desire(adapter: adapter, subject: id, hash: "deleted:\(old.desiredHash)", operation: .delete, item: nil)
        }
      }
      if needsSnapshotWrite {
        try database.execute("INSERT OR REPLACE INTO metadata VALUES ('snapshot',?)", [.text(try json(result))])
        try database.execute("INSERT OR REPLACE INTO metadata VALUES ('snapshot_token',?)", [.text(snapshotToken)])
      }
    }
    if let sequence { scanGenerations[sequence.ownerID] = sequence.generation }
    cachedSnapshot = result; cachedSnapshotToken = snapshotToken
    if unchanged { reconciledAdapters.formUnion(adapters) } else { reconciledAdapters = Set(adapters) }
    return result
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private func desire(adapter: String, subject: String, hash: String, operation: WikiIndexJob.Operation, item: WikiIndexItem?) throws {
    let payload = try item.map(json)
    try database.execute("""
      INSERT INTO index_jobs VALUES (?,?,?,1,?,?,'pending',NULL)
      ON CONFLICT(adapter,subject) DO UPDATE SET
        desired_hash=excluded.desired_hash, generation=index_jobs.generation+1,
        operation=excluded.operation, payload=excluded.payload, state='pending', last_error=NULL
      WHERE index_jobs.desired_hash != excluded.desired_hash OR index_jobs.operation != excluded.operation
      """, [.text(adapter), .text(subject), .text(hash), .text(operation.rawValue), payload.map(ProjectionDatabase.Value.text) ?? .null])
  }

  public func pendingJobs(adapter: String, limit: Int = 100) throws -> [WikiIndexJob] {
    guard (1...1000).contains(limit) else { throw WikiError.invalidSource("Invalid index batch limit.") }
    let epoch = try storeID()
    return try database.rows("SELECT subject, desired_hash, generation, operation, payload, last_error FROM index_jobs WHERE adapter=? AND state='pending' ORDER BY subject LIMIT ?",
      [.text(adapter), .integer(Int64(limit))]).map { row in
      guard let subject = row[0], let hash = row[1], let generation = row[2].flatMap(Int64.init),
        let operation = row[3].flatMap(WikiIndexJob.Operation.init(rawValue:)) else {
        throw WikiError.database("Invalid index job.")
      }
      let item = try row[4].map { try decoder.decode(WikiIndexItem.self, from: Data($0.utf8)) }
      return WikiIndexJob(adapter: adapter, storeID: epoch, subjectID: subject, desiredHash: hash,
        generation: generation, operation: operation, item: item, lastError: row[5])
    }
  }

  public func isCurrent(_ job: WikiIndexJob) throws -> Bool {
    !(try database.rows("SELECT 1 FROM index_jobs WHERE adapter=? AND subject=? AND desired_hash=? AND generation=? AND (SELECT value FROM metadata WHERE key='store_id')=?",
      [.text(job.adapter), .text(job.subjectID), .text(job.desiredHash), .integer(job.generation), .text(job.storeID)])).isEmpty
  }

  /// An old worker cannot acknowledge a newer desired source, even after suspension/reconnect.
  public func acknowledge(_ job: WikiIndexJob, error: String? = nil) throws {
    try database.execute("UPDATE index_jobs SET state=?, last_error=? WHERE adapter=? AND subject=? AND desired_hash=? AND generation=? AND (SELECT value FROM metadata WHERE key='store_id')=?",
      [.text(error == nil ? "applied" : "pending"), error.map(ProjectionDatabase.Value.text) ?? .null,
        .text(job.adapter), .text(job.subjectID), .text(job.desiredHash), .integer(job.generation), .text(job.storeID)])
  }

  public func requestReindex(adapter: String, subjects: Set<String>? = nil) throws {
    if let subjects {
      for subject in subjects {
        try database.execute("UPDATE index_jobs SET state='pending', generation=generation+1 WHERE adapter=? AND subject=?",
          [.text(adapter), .text(subject)])
      }
    } else {
      try database.execute("UPDATE index_jobs SET state='pending', generation=generation+1 WHERE adapter=?", [.text(adapter)])
    }
  }

  public func search(_ query: String, limit: Int = 10, semanticSectionIDs: [String] = [],
    semanticState: String = "unavailable", candidateSource: WikiSearchSource = .semantic
  ) throws -> WikiSearchResult {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 512,
      (1...100).contains(limit), semanticSectionIDs.count <= 1000 else {
      throw WikiError.invalidSource("Expected nonempty query, bounded candidates and limit 1...100.")
    }
    guard let snapshot = try snapshot() else {
      throw WikiError.unavailable("Workspace has not been scanned.")
    }
    let query = try WikiSearchQuery(query, allowEmpty: false, legacyTermLimit: true)
    // Preserve the existing bounded adapter contract; complete local paging uses no candidate cap.
    let ranking = WikiSearchRanking(snapshot: snapshot, query: query, filter: .init(),
      fts: try ftsCandidates(query, legacyLimit: true), semantic: semanticSectionIDs,
      candidateSource: candidateSource, compactCandidates: false)
    let hits = ranking.hits(0..<min(limit, ranking.ids.count))
    return WikiSearchResult(hits: hits, diagnostics: snapshot.diagnostics,
      coverageComplete: snapshot.coverageComplete, semanticState: semanticState, resultsTruncated: ranking.ids.count > hits.count)
  }

  package func removeLegacySemanticValues() throws {
    try database.execute("DELETE FROM derived_values WHERE substr(producer,1,15)='folio.semantic/' AND instr(substr(producer,16),'/')=0")
  }

  /// Internal producer namespace cleanup; source and write receipts are untouched.
  package func retainDerivedProducer(_ producer: String, namespace: String) throws {
    try database.execute("DELETE FROM derived_values WHERE substr(producer,1,?)=? AND producer != ?",
      [.integer(Int64(namespace.count)), .text(namespace), .text(producer)])
  }

  public func derivedValues(producer: String, subjects: Set<String>? = nil) throws -> [WikiDerivedValue] {
    if let subjects, subjects.isEmpty { return [] }
    if let subjects, subjects.count > 512 { throw WikiError.invalidSource("Derived cache selection exceeds 512 subjects.") }
    let selected = subjects?.sorted()
    let clause = selected.map { " AND subject IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? ""
    let values: [ProjectionDatabase.Value] = [.text(producer)] + (selected ?? []).map(ProjectionDatabase.Value.text)
    return try database.rows("SELECT subject, source_revision, input_hash, value_json FROM derived_values WHERE producer=?" + clause, values).map { row in
      guard let subject = row[0], let revision = row[1], let hash = row[2], let json = row[3] else {
        throw WikiError.database("Invalid derived cache record.")
      }
      return WikiDerivedValue(subjectID: subject, sourceRevision: revision, inputHash: hash, valueJSON: json)
    }
  }

  @discardableResult
  public func storeDerivedValue(_ value: WikiDerivedValue, producer: String) throws -> Bool {
    guard !producer.isEmpty, producer.utf8.count <= 256, value.valueJSON.utf8.count <= 65536 else {
      throw WikiError.invalidSource("Invalid derived-cache producer/payload.")
    }
    guard let snapshot = try snapshot(),
      let document = snapshot.documents.first(where: { $0.sections.contains { $0.id == value.subjectID } }),
      let section = document.sections.first(where: { $0.id == value.subjectID }),
      document.revision == value.sourceRevision, SourceDigest.sha256(section.searchText) == value.inputHash else { return false }
    try database.execute("INSERT OR REPLACE INTO derived_values VALUES (?,?,?,?,?)", [.text(producer), .text(value.subjectID),
      .text(value.sourceRevision), .text(value.inputHash), .text(value.valueJSON)])
    return true
  }

  public func removeDerivedValues(producer: String, retaining subjects: Set<String>) throws {
    try database.transaction {
      // Deletion needs only identities, never the large vector JSON payloads.
      for row in try database.rows("SELECT subject FROM derived_values WHERE producer=?", [.text(producer)]) {
        guard let subject = row[0], !subjects.contains(subject) else { continue }
        try database.execute("DELETE FROM derived_values WHERE producer=? AND subject=?", [.text(producer), .text(subject)])
      }
    }
  }
}

public struct WikiDerivedValue: Sendable {
  public let subjectID: String
  public let sourceRevision: String
  public let inputHash: String
  public let valueJSON: String
  public init(subjectID: String, sourceRevision: String, inputHash: String, valueJSON: String) {
    self.subjectID = subjectID; self.sourceRevision = sourceRevision; self.inputHash = inputHash; self.valueJSON = valueJSON
  }
}
