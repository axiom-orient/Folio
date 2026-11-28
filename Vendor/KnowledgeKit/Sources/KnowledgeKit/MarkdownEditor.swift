import Foundation
import Yams

public struct WikiTextPatch: Codable, Sendable {
  public let range: WikiSourceRange
  public let replacement: String
}

public enum WikiMarkdownEditor {
  /// YAML treats these Unicode separators as line breaks even inside a quoted scalar.
  /// All saved knowledge metadata uses the same escaping without changing JSON values.
  package static func jsonMetadataScalar(_ data: Data) throws -> String {
    guard let json = String(data: data, encoding: .utf8) else { throw WikiError.invalidSource("Metadata must be UTF-8 JSON.") }
    let text = json.replacingOccurrences(of: "\u{85}", with: "\\u0085")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
  }

  /// Give an imported note an ID without re-emitting its YAML or changing body bytes.
  /// Existing IDs are preserved; the workspace validates duplicates/types/relations.
  public static func addingStableID(bytes: Data, id: String) throws -> Data {
    let existing = try WikiMarkdownParser.document(relativePath: "notes/import.md", bytes: bytes)
    if existing.stableID != nil { return bytes }
    let source = try SourceText(bytes)
    let metadata = try Frontmatter.read(source)
    let newline = source.newline
    let quoted = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
    let offset: Int
    let insertion: String
    if metadata.bodyLine == 1 {
      offset = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
      insertion = "---\(newline)id: \(quoted)\(newline)---\(newline)\(newline)"
    } else {
      let yaml = source.lines[1..<(metadata.bodyLine - 2)].map(\.text).joined(separator: "\n")
      let parser = try Yams.Parser(yaml: yaml)
      let root = try parser.singleRoot()
      if let mark = root?.mark, mark.line > 0, mark.line < source.lines.count,
        mark.column > 0, mark.column - 1 <= source.lines[mark.line].text.unicodeScalars.count {
        let candidate = source.lines[mark.line].start
          + source.lines[mark.line].text.unicodeScalars.prefix(mark.column - 1).reduce(0) { $0 + String($1).utf8.count }
        if candidate < bytes.count, bytes[candidate] == 123 {
          offset = candidate + 1
          insertion = "\"id\": \(quoted)" + (metadata.fields.isEmpty ? "" : ", ")
        } else {
          offset = source.lines[metadata.bodyLine - 2].start
          insertion = "id: \(quoted)\(newline)"
        }
      } else {
        offset = source.lines[metadata.bodyLine - 2].start
        insertion = "id: \(quoted)\(newline)"
      }
    }
    let result = bytes.prefix(offset) + Data(insertion.utf8) + bytes.suffix(from: offset)
    guard try WikiMarkdownParser.document(relativePath: "notes/import.md", bytes: result).stableID == id.precomposedStringWithCanonicalMapping else {
      throw WikiError.invalidSource("Imported document ID couldn't be assigned safely.")
    }
    return result
  }

  /// Insert only the requested declaration; preserve unrelated YAML, comments,
  /// body spelling and line endings. The caller validates ontology and source CAS.
  public static func addRelation(bytes: Data, predicate: String, targetID: String) throws -> WikiTextPatch? {
    guard !predicate.isEmpty, predicate.utf8.count <= 512, !targetID.isEmpty, targetID.utf8.count <= 512,
      !predicate.contains("\0"), !targetID.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" }) else {
      throw WikiError.invalidSource("Invalid explicit relation predicate/target ID.")
    }
    let source = try SourceText(bytes)
    let metadata = try Frontmatter.read(source)
    let newline = source.newline
    func quote(_ text: String) throws -> String { String(decoding: try JSONEncoder().encode(text), as: UTF8.self) }
    func insertion(_ offset: Int, _ text: String) -> WikiTextPatch {
      let line = (source.lines.lastIndex { $0.start <= offset } ?? 0) + 1
      return WikiTextPatch(range: WikiSourceRange(lowerBound: offset, upperBound: offset, startLine: line, endLine: line), replacement: text)
    }
    func offset(_ mark: Mark) throws -> Int {
      // Yams marks are 1-based UnicodeScalar columns, unlike swift-markdown's UTF-8 columns.
      guard mark.line > 0, mark.line < source.lines.count else { throw WikiError.invalidSource("Invalid YAML source mark.") }
      let line = source.lines[mark.line]
      guard mark.column > 0, mark.column - 1 <= line.text.unicodeScalars.count else { throw WikiError.invalidSource("Invalid YAML column.") }
      return line.start + line.text.unicodeScalars.prefix(mark.column - 1).reduce(0) { $0 + String($1).utf8.count }
    }
    func closeDelimiter(from start: Int, open: UInt8, close: UInt8) throws -> (offset: Int, lastByte: UInt8?) {
      let raw = [UInt8](bytes)
      guard start < raw.count, raw[start] == open else { throw WikiError.invalidSource("YAML source mark does not match its container.") }
      var cursor = start + 1; var depth = 1; var quote: UInt8?; var last: UInt8?
      while cursor < raw.count {
        let byte = raw[cursor]
        if let active = quote {
          if active == 34, byte == 92 { cursor += 2; continue }
          if byte == active {
            if active == 39, cursor + 1 < raw.count, raw[cursor + 1] == 39 { cursor += 2; continue }
            quote = nil
          }
        } else if byte == 34 || byte == 39 { quote = byte }
        else if byte == 35 && (cursor == start + 1 || [9, 10, 13, 32, 44].contains(raw[cursor - 1])) {
          while cursor < raw.count && raw[cursor] != 10 && raw[cursor] != 13 { cursor += 1 }; continue
        } else if byte == open { depth += 1 }
        else if byte == close { depth -= 1; if depth == 0 { return (cursor, last) } }
        if ![9, 10, 13, 32].contains(byte) { last = byte }
        cursor += 1
      }
      throw WikiError.invalidSource("Cannot locate the YAML container boundary.")
    }
    let quotedTarget = try quote(targetID)
    guard let relationsNode = metadata.fields["relations"] else {
      let declaration = "relations:\(newline)  \(try quote(predicate)): [\(quotedTarget)]\(newline)"
      if metadata.bodyLine == 1 { return insertion(0, "---\(newline)\(declaration)---\(newline)\(newline)") }
      return insertion(source.lines[metadata.bodyLine - 2].start, declaration)
    }
    let relations = try Frontmatter.mapping(relationsNode)
    if let sequenceNode = relations[predicate] {
      let values = try Frontmatter.strings(sequenceNode)
      if values.contains(targetID) { return nil }
      guard case .sequence(let sequence) = sequenceNode, let mark = sequence.mark else {
        throw WikiError.invalidSource("Relation sequence has no source mark.")
      }
      let start = try offset(mark)
      // Emitter style is not source authority. Inspect the original delimiter at the verified mark.
      if start < bytes.count, bytes[start] == 91 {
        let end = try closeDelimiter(from: start, open: 91, close: 93)
        return insertion(end.offset, (values.isEmpty || end.lastByte == 44 ? "" : ", ") + quotedTarget)
      }
      guard let last = sequence.last?.mark, last.line < source.lines.count else { throw WikiError.invalidSource("Cannot locate relation sequence end.") }
      return insertion(source.lines[last.line].end, String(repeating: " ", count: max(0, mark.column - 1)) + "- \(quotedTarget)\(newline)")
    }
    guard case .mapping(let mapping) = relationsNode, let mark = mapping.mark else {
      throw WikiError.invalidSource("Relations mapping has no source mark.")
    }
    let declaration = "\(try quote(predicate)): [\(quotedTarget)]"
    let start = try offset(mark)
    if start < bytes.count, bytes[start] == 123 {
      let end = try closeDelimiter(from: start, open: 123, close: 125)
      return insertion(end.offset, (relations.isEmpty || end.lastByte == 44 ? "" : ", ") + declaration)
    }
    return insertion(source.lines[mark.line].start, String(repeating: " ", count: max(0, mark.column - 1)) + declaration + newline)
  }
}
