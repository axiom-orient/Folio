import Foundation
import FolioKnowledgeSQLite

/// Owned only by WikiProjection's actor. No connection crosses an isolation boundary.
final class ProjectionDatabase {
  enum Value { case text(String), integer(Int64), null }
  private var handle: OpaquePointer?

  init(url: URL, readOnly: Bool = false) throws {
    let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open projection."
      if let handle { sqlite3_close(handle) }; handle = nil
      throw WikiError.database(message)
    }
    sqlite3_busy_timeout(handle, 3000)
    if readOnly {
      guard try rows("SELECT value FROM metadata WHERE key='schema'").first?.first == "1" else {
        throw WikiError.database("Unsupported read-only projection schema.")
      }
      return
    }
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA foreign_keys=ON")
    try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    let version = try rows("SELECT value FROM metadata WHERE key='schema'").first?.first
    guard version == nil || version == "1" else { throw WikiError.database("Unsupported projection schema; rebuild from source.") }
    try execute("INSERT OR IGNORE INTO metadata VALUES ('schema','1')")
    try execute("INSERT OR IGNORE INTO metadata VALUES ('store_id',?)", [.text(UUID().uuidString)])
    try execute("CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, revision TEXT NOT NULL, active INTEGER NOT NULL, payload TEXT NOT NULL)")
    try execute("CREATE TABLE IF NOT EXISTS sections (id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, payload TEXT NOT NULL)")
    try execute("CREATE VIRTUAL TABLE IF NOT EXISTS fts_sections USING fts5(section_id UNINDEXED, search_text, tokenize='unicode61')")
    try execute("CREATE TABLE IF NOT EXISTS index_jobs (adapter TEXT NOT NULL, subject TEXT NOT NULL, desired_hash TEXT NOT NULL, generation INTEGER NOT NULL, operation TEXT NOT NULL, payload TEXT, state TEXT NOT NULL, last_error TEXT, PRIMARY KEY(adapter, subject))")
    try execute("CREATE TABLE IF NOT EXISTS derived_values (producer TEXT NOT NULL, subject TEXT NOT NULL, source_revision TEXT NOT NULL, input_hash TEXT NOT NULL, value_json TEXT NOT NULL, PRIMARY KEY(producer,subject))")
    try execute("CREATE TABLE IF NOT EXISTS knowledge_documents (id TEXT PRIMARY KEY, revision TEXT NOT NULL, producer TEXT NOT NULL, payload TEXT NOT NULL)")
    try execute("CREATE TABLE IF NOT EXISTS knowledge_blocks (id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES knowledge_documents(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, text TEXT NOT NULL, payload TEXT NOT NULL, vector_model_id TEXT, vector_json TEXT)")
    try execute("CREATE INDEX IF NOT EXISTS knowledge_blocks_source ON knowledge_blocks(source_id)")
    try execute("CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(block_id UNINDEXED, source_id UNINDEXED, text, tokenize='unicode61')")
  }

  deinit { if let handle { sqlite3_close(handle) } }

  private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw WikiError.database(String(cString: sqlite3_errmsg(handle)))
    }
    do {
      for (offset, value) in values.enumerated() {
        let index = Int32(offset + 1); let result: Int32
        switch value {
        case .text(let text):
          result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
        case .null: result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw WikiError.database("Cannot bind SQLite argument.") }
      }
      return statement
    } catch { sqlite3_finalize(statement); throw error }
  }

  func execute(_ sql: String, _ values: [Value] = []) throws {
    let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
    var code = sqlite3_step(statement)
    while code == SQLITE_ROW { code = sqlite3_step(statement) }
    guard code == SQLITE_DONE else { throw WikiError.database(String(cString: sqlite3_errmsg(handle))) }
  }

  func rows(_ sql: String, _ values: [Value] = []) throws -> [[String?]] {
    let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
    var result: [[String?]] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return result }
      guard code == SQLITE_ROW else { throw WikiError.database(String(cString: sqlite3_errmsg(handle))) }
      result.append((0..<sqlite3_column_count(statement)).map { index in
        sqlite3_column_text(statement, index).map { String(cString: $0) }
      })
    }
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do { let result = try body(); try execute("COMMIT"); return result }
    catch { try? execute("ROLLBACK"); throw error }
  }
}
