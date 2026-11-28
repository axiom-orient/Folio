import Foundation
import Yams

/// JSON values retain number tokens so editing known fields cannot round future metadata.
public indirect enum WikiJSONValue: Sendable, Equatable {
  case object([String: WikiJSONValue]), array([WikiJSONValue]), string(String), number(String), bool(Bool), null

  public var objectValue: [String: WikiJSONValue]? { if case .object(let value) = self { value } else { nil } }
  public var arrayValue: [WikiJSONValue]? { if case .array(let value) = self { value } else { nil } }
  public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
  public var integerValue: Int? { if case .number(let value) = self { Int(value) } else { nil } }

  public static func parse(_ data: Data) throws -> WikiJSONValue {
    guard data.count <= 65_536, String(data: data, encoding: .utf8) != nil else {
      throw WikiError.invalidSource("Knowledge metadata requires UTF-8 JSON of at most 65,536 bytes.")
    }
    var parser = JSONReader(bytes: Array(data))
    let value = try parser.value(depth: 0)
    parser.whitespace()
    guard parser.offset == parser.bytes.count else { throw WikiError.invalidSource("Trailing JSON metadata.") }
    return value
  }

  public func encoded() throws -> Data {
    var budget = 4_096
    func encode(_ value: WikiJSONValue, depth: Int) throws -> String {
      budget -= 1
      guard depth <= 32, budget >= 0 else { throw WikiError.invalidSource("JSON metadata nesting or item limit exceeded.") }
      switch value {
      case .null: return "null"
      case .bool(let value): return value ? "true" : "false"
      case .string(let value): return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
      case .number(let token):
        var reader = JSONReader(bytes: Array(token.utf8))
        guard try reader.number() == token, reader.offset == reader.bytes.count else {
          throw WikiError.invalidSource("Invalid JSON number token.")
        }
        return token
      case .array(let values): return "[" + (try values.map { try encode($0, depth: depth + 1) }).joined(separator: ",") + "]"
      case .object(let fields):
        return "{" + (try fields.sorted { $0.key < $1.key }.map { pair in
          try encode(.string(pair.key), depth: depth + 1) + ":" + encode(pair.value, depth: depth + 1)
        }).joined(separator: ",") + "}"
      }
    }
    let result = Data(try encode(self, depth: 0).utf8)
    guard result.count <= 65_536 else { throw WikiError.invalidSource("Knowledge metadata exceeds 65,536 bytes.") }
    return result
  }
}

private struct JSONReader {
  let bytes: [UInt8]
  var offset = 0
  var budget = 4_096

  mutating func whitespace() { while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
  mutating func value(depth: Int) throws -> WikiJSONValue {
    budget -= 1; whitespace()
    guard depth <= 32, budget >= 0, offset < bytes.count else { throw invalid() }
    switch bytes[offset] {
    case 34: return .string(try string())
    case 123:
      offset += 1; whitespace(); var values: [String: WikiJSONValue] = [:]
      if consume(125) { return .object(values) }
      while true {
        whitespace(); let key = try string(); whitespace()
        guard consume(58), values[key] == nil else { throw invalid() }
        values[key] = try value(depth: depth + 1); whitespace()
        if consume(125) { return .object(values) }
        guard consume(44) else { throw invalid() }
      }
    case 91:
      offset += 1; whitespace(); var values: [WikiJSONValue] = []
      if consume(93) { return .array(values) }
      while true {
        values.append(try value(depth: depth + 1)); whitespace()
        if consume(93) { return .array(values) }
        guard consume(44) else { throw invalid() }
      }
    case 116: try literal("true"); return .bool(true)
    case 102: try literal("false"); return .bool(false)
    case 110: try literal("null"); return .null
    default: return .number(try number())
    }
  }
  mutating func string() throws -> String {
    guard consume(34) else { throw invalid() }
    let start = offset - 1
    while offset < bytes.count {
      let byte = bytes[offset]; offset += 1
      if byte == 34 {
        return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
      }
      if byte == 92 { guard offset < bytes.count else { throw invalid() }; offset += 1 }
      else if byte < 32 { throw invalid() }
    }
    throw invalid()
  }
  mutating func number() throws -> String {
    let start = offset
    _ = consume(45)
    guard offset < bytes.count else { throw invalid() }
    if consume(48) {
      if offset < bytes.count, (48...57).contains(bytes[offset]) { throw invalid() }
    } else {
      guard offset < bytes.count, (49...57).contains(bytes[offset]) else { throw invalid() }
      while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
    }
    if consume(46) { try digits() }
    if offset < bytes.count, bytes[offset] == 101 || bytes[offset] == 69 {
      offset += 1
      if offset < bytes.count, bytes[offset] == 43 || bytes[offset] == 45 { offset += 1 }
      try digits()
    }
    return String(decoding: bytes[start..<offset], as: UTF8.self)
  }
  mutating func digits() throws {
    let start = offset
    while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
    guard offset > start else { throw invalid() }
  }
  mutating func literal(_ text: String) throws {
    let token = Array(text.utf8)
    guard offset + token.count <= bytes.count, Array(bytes[offset..<(offset + token.count)]) == token else { throw invalid() }
    offset += token.count
  }
  mutating func consume(_ byte: UInt8) -> Bool {
    guard offset < bytes.count, bytes[offset] == byte else { return false }; offset += 1; return true
  }
  func invalid() -> WikiError { .invalidSource("Invalid, duplicate or oversized JSON knowledge metadata.") }
}

public struct WikiConceptLabel: Codable, Hashable, Sendable {
  public let language: String
  public let preferred: String
  public let aliases: [String]
  public init(language: String, preferred: String, aliases: [String] = []) {
    self.language = language; self.preferred = preferred; self.aliases = aliases
  }
  private enum CodingKeys: String, CodingKey { case language, preferred, aliases }
  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    language = try fields.decode(String.self, forKey: .language)
    preferred = try fields.decode(String.self, forKey: .preferred)
    aliases = try fields.decodeIfPresent([String].self, forKey: .aliases) ?? []
  }
}

/// Versioned metadata, independent of Apple-specific evidence types.
public struct WikiOntologyRecord: Sendable, Equatable {
  public let fields: [String: WikiJSONValue]
  public let schemaVersion: Int
  public let role: String
  public let recordID: String

  public init(fields: [String: WikiJSONValue]) throws {
    guard let version = fields["schemaVersion"]?.integerValue, version > 0,
      let role = fields["role"]?.stringValue, !role.isEmpty, role.utf8.count <= 64, !role.contains("\0"),
      let id = fields["recordID"]?.stringValue, !id.isEmpty, id.utf8.count <= 512,
      !id.hasPrefix("path:"), !id.contains("/"), !id.contains("\\"), !id.contains("\0"),
      !id.contains(where: { $0.isWhitespace || $0.isNewline }), id == id.precomposedStringWithCanonicalMapping
    else { throw WikiError.invalidSource("Knowledge records require a schema version, role and stable record ID.") }
    self.fields = fields; schemaVersion = version; self.role = role; recordID = id
    _ = try encoded()
  }

  public func encoded() throws -> Data { try WikiJSONValue.object(fields).encoded() }

  public static func read(bytes: Data) throws -> WikiOntologyRecord? {
    let metadata = try Frontmatter.read(SourceText(bytes))
    guard let entry = metadata.fields["folio_ontology_record"] else { return nil }
    guard entry.tag.rawValue == "tag:yaml.org,2002:str", let text = entry.scalar?.string,
      let fields = try WikiJSONValue.parse(Data(text.utf8)).objectValue,
      let id = try metadata.fields["id"].map({ try Frontmatter.string($0) }) else {
      throw WikiError.invalidSource("Knowledge record requires a JSON string and stable document ID.")
    }
    let record = try WikiOntologyRecord(fields: fields)
    guard record.recordID == id else { throw WikiError.invalidSource("Knowledge record ID does not match its document.") }
    return record
  }

  public func frontmatterLine() throws -> String {
    "folio_ontology_record: " + (try yamlScalar()) + "\n"
  }

  private func yamlScalar() throws -> String {
    try WikiMarkdownEditor.jsonMetadataScalar(encoded())
  }

  /// Changes only the metadata scalar. Unknown YAML, comments and body bytes remain authoritative.
  public static func replacingRecord(in bytes: Data, with record: WikiOntologyRecord) throws -> Data {
    let source = try SourceText(bytes), metadata = try Frontmatter.read(source)
    guard let id = try metadata.fields["id"].map({ try Frontmatter.string($0) }), id == record.recordID else {
      throw WikiError.invalidSource("Knowledge record updates require the existing stable document ID.")
    }
    let scalar = try record.yamlScalar()
    let raw = Array(bytes)
    func offset(_ mark: Mark) throws -> Int {
      guard mark.line > 0, mark.line < source.lines.count, mark.column > 0,
        mark.column - 1 <= source.lines[mark.line].text.unicodeScalars.count else { throw WikiError.invalidSource("Invalid knowledge metadata mark.") }
      return source.lines[mark.line].start
        + source.lines[mark.line].text.unicodeScalars.prefix(mark.column - 1).reduce(0) { $0 + String($1).utf8.count }
    }
    let result: Data
    if let entry = metadata.fields["folio_ontology_record"] {
      guard entry.tag.rawValue == "tag:yaml.org,2002:str", let mark = entry.mark else {
        throw WikiError.invalidSource("Knowledge metadata must be a string scalar.")
      }
      let start = try offset(mark)
      guard start < raw.count, raw[start] == 39 || raw[start] == 34 else {
        throw WikiError.invalidSource("Use a quoted knowledge metadata scalar before updating this record.")
      }
      let quote = raw[start]; var end = start + 1
      while end < raw.count {
        if raw[end] == quote {
          if quote == 39, end + 1 < raw.count, raw[end + 1] == quote { end += 2; continue }
          end += 1; break
        }
        if quote == 34, raw[end] == 92 { end += 2 } else { end += 1 }
      }
      guard end <= raw.count, end > start + 1, raw[end - 1] == quote else {
        throw WikiError.invalidSource("Unterminated knowledge metadata scalar.")
      }
      result = bytes.prefix(start) + Data(scalar.utf8) + bytes.suffix(from: end)
    } else {
      // New records are created with a stable ID, so frontmatter already exists.
      let yaml = source.lines[1..<(metadata.bodyLine - 2)].map(\.text).joined(separator: "\n")
      let parser = try Yams.Parser(yaml: yaml)
      let root = try parser.singleRoot()
      if let mark = root?.mark, raw[try offset(mark)] == 123 {
        let start = try offset(mark) + 1
        let insertion = "\"folio_ontology_record\": " + scalar + (metadata.fields.isEmpty ? "" : ", ")
        result = bytes.prefix(start) + Data(insertion.utf8) + bytes.suffix(from: start)
      } else {
        let start = source.lines[metadata.bodyLine - 2].start
        result = bytes.prefix(start) + Data(("folio_ontology_record: " + scalar + source.newline).utf8) + bytes.suffix(from: start)
      }
    }
    guard try read(bytes: result) == record else { throw WikiError.invalidSource("Knowledge metadata patch did not preserve its payload.") }
    return result
  }
}
