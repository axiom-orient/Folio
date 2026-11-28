import Foundation
import FolioKnowledge

/// The quote is a literal byte sequence from one admitted evidence item, not a generated citation.
public struct WikiKnowledgeAssertionCitation: Codable, Hashable, Sendable {
  public let evidenceID: String
  public let quote: String
  public init(evidenceID: String, quote: String) { self.evidenceID = evidenceID; self.quote = quote }
}

/// Caller interpretation is retained explicitly and never substitutes for the original quote.
public struct WikiKnowledgeAssertionText: Codable, Hashable, Sendable {
  public enum Origin: String, Codable, Hashable, Sendable { case quoted, interpretation }
  public let text: String
  public let citations: [WikiKnowledgeAssertionCitation]
  public let origin: Origin
  public init(text: String, citations: [WikiKnowledgeAssertionCitation], origin: Origin = .quoted) {
    self.text = text; self.citations = citations; self.origin = origin
  }
}

public struct WikiKnowledgeAssertionEvidence: Codable, Hashable, Sendable {
  public enum Role: String, Codable, Hashable, Sendable { case support, context, refute }
  public let evidence: WikiKnowledgeEvidence
  public let role: Role
  public init(evidence: WikiKnowledgeEvidence, role: Role = .support) {
    self.evidence = evidence; self.role = role
  }
}

/// One sourced claim. Review, source currentness and objective truth remain separate concepts.
public struct WikiKnowledgeAssertion: Codable, Hashable, Sendable, Identifiable {
  /// New input contract. Host UTF-8 byte caps and original-source checks also apply.
  public static let inputSchemaJSON = #"""
  {
    "type":"object","additionalProperties":false,
    "properties":{
      "recordID":{"type":"string","minLength":1,"maxLength":512,"description":"Stable record ID, NFC, not a path; host also limits UTF-8 bytes."},
      "statement":{"$ref":"#/$defs/AssertionText"},
      "polarity":{"type":"string","enum":["unspecified","affirmed","negated"],"description":"Caller classification, not automatic logical entailment. Use unspecified when unassessed."},
      "conceptIDs":{"type":"array","maxItems":32,"uniqueItems":true,"items":{"type":"string","minLength":1,"maxLength":512}},
      "conditions":{"type":"array","maxItems":32,"items":{"$ref":"#/$defs/AssertionText"}},
      "value":{"anyOf":[{"$ref":"#/$defs/AssertionText"},{"type":"null"}],"description":"Literal source value; origin must be quoted. No inferred normalization or conversion."},
      "unit":{"anyOf":[{"$ref":"#/$defs/AssertionText"},{"type":"null"}],"description":"Literal source unit, with the same physical source as the claim/value."},
      "edition":{"anyOf":[{"$ref":"#/$defs/AssertionText"},{"type":"null"}],"description":"Confirmed literal edition wording, not a file revision or inferred publication date."},
      "evidence":{"type":"array","minItems":1,"maxItems":64,"items":{"$ref":"#/$defs/AssertionEvidence"}},
      "state":{"type":"string","enum":["draft","accepted"],"description":"Acceptance is a caller review choice, not a truth certificate."}
    },
    "required":["recordID","statement","polarity","conceptIDs","conditions","evidence","state"],
    "$defs":{
      "AssertionCitation":{"type":"object","additionalProperties":false,"properties":{
        "evidenceID":{"type":"string","minLength":1,"maxLength":512},
        "quote":{"type":"string","minLength":1,"maxLength":16384,"description":"Exact contiguous original UTF-8 wording. Do not clip signs, decimals, exponents, or word fragments."}
      },"required":["evidenceID","quote"]},
      "AssertionText":{"type":"object","additionalProperties":false,"properties":{
        "text":{"type":"string","minLength":1,"maxLength":8192,"description":"Host caps statement at 8192 UTF-8 bytes, conditions at 2048 and value/unit/edition at 1024."},
        "citations":{"type":"array","minItems":1,"maxItems":64,"uniqueItems":true,"items":{"$ref":"#/$defs/AssertionCitation"}},
        "origin":{"type":"string","enum":["quoted","interpretation"],"description":"Quoted text must be a complete literal phrase in an eligible citation. Interpretation is explicitly unproven caller assessment."}
      },"required":["text","citations","origin"]},
      "AssertionEvidence":{"type":"object","additionalProperties":false,"properties":{
        "evidence":{"type":"object","description":"Reuse the complete returned WikiKnowledgeEvidence without changes. The source owner validates its bytes, scope, page/region and producer."},
        "role":{"type":"string","enum":["support","context","refute"]}
      },"required":["evidence","role"]}
    }
  }
  """#
  public enum Polarity: String, Codable, Hashable, Sendable { case unspecified, affirmed, negated }
  public enum State: String, Codable, Hashable, Sendable { case draft, accepted }
  public let id: String
  public let statement: WikiKnowledgeAssertionText
  /// A caller assessment; the literal statement and its negation are preserved in the citations.
  public let polarity: Polarity
  public let conceptIDs: [String]
  public let conditions: [WikiKnowledgeAssertionText]
  public let value: WikiKnowledgeAssertionText?
  public let unit: WikiKnowledgeAssertionText?
  public let edition: WikiKnowledgeAssertionText?
  public let evidence: [WikiKnowledgeAssertionEvidence]
  public let state: State

  public init(id: String, statement: WikiKnowledgeAssertionText, polarity: Polarity = .unspecified,
    conceptIDs: [String] = [], conditions: [WikiKnowledgeAssertionText] = [],
    value: WikiKnowledgeAssertionText? = nil, unit: WikiKnowledgeAssertionText? = nil,
    edition: WikiKnowledgeAssertionText? = nil, evidence: [WikiKnowledgeAssertionEvidence], state: State = .accepted
  ) {
    self.id = id; self.statement = statement; self.polarity = polarity; self.conceptIDs = conceptIDs
    self.conditions = conditions; self.value = value; self.unit = unit; self.edition = edition
    self.evidence = evidence; self.state = state
  }
  private enum CodingKeys: String, CodingKey {
    case id = "recordID", statement, polarity, conceptIDs, conditions, value, unit, edition, evidence, state
  }

  public var title: String { statement.text.components(separatedBy: .newlines).joined(separator: " ") }

  /// Exact typed content identity. Only the record's assigned ID is excluded.
  /// Source revisions, quotation roles, interpretation and review state remain part of the identity.
  public func contentDigest() throws -> String {
    guard var fields = try WikiJSONValue.parse(JSONEncoder().encode(self)).objectValue else {
      throw WikiError.invalidSource("주장 내용을 확인하지 못했습니다.")
    }
    fields.removeValue(forKey: "recordID")
    return SourceDigest.sha256(try WikiJSONValue.object(fields).encoded())
  }

  public var allEvidence: [WikiKnowledgeEvidence] {
    var seen = Set<String>()
    return evidence.map(\.evidence).filter { seen.insert($0.id).inserted }
  }

  /// Selects the original evidence that actually carries a field, not an arbitrary first citation.
  /// The workspace still checks current bytes before displaying or opening the source.
  public func sourceEvidence(for field: WikiKnowledgeAssertionText) throws -> [WikiKnowledgeEvidence] {
    _ = try validated()
    guard ([statement] + conditions + [value, unit, edition].compactMap { $0 }).contains(field) else {
      throw WikiError.invalidSource("주장에 속하지 않는 항목입니다.")
    }
    let items = Dictionary(uniqueKeysWithValues: evidence.map { ($0.evidence.id, $0) })
    let resolved = try resolve(field, items: items, maximum: field == statement ? 8_192 : 2_048, statement: field == statement)
    var seen = Set<String>()
    return resolved.enumerated().sorted {
      let left = $0.element.role == .support ? 0 : 1, right = $1.element.role == .support ? 0 : 1
      return left == right ? $0.offset < $1.offset : left < right
    }.map { $0.element.evidence }.filter { seen.insert($0.id).inserted }
  }

  package func accepting() -> Self {
    .init(id: id, statement: statement, polarity: polarity, conceptIDs: conceptIDs, conditions: conditions,
      value: value, unit: unit, edition: edition, evidence: evidence, state: .accepted)
  }

  /// New caller/model payloads are strict. Stored records use decode(_:) so future metadata is preserved.
  public static func decodeInput(_ data: Data) throws -> Self {
    let raw = try WikiJSONValue.parse(data)
    let value = try JSONDecoder().decode(Self.self, from: data)
    let encoded = try WikiJSONValue.parse(JSONEncoder().encode(value))
    try strictKeys(raw, matching: encoded)
    return try value.validated()
  }

  package static func validateInputShape(_ input: WikiJSONValue, matching encoded: WikiJSONValue) throws {
    try strictKeys(input, matching: encoded)
  }

  package static func decode(_ record: WikiOntologyRecord) throws -> Self {
    guard record.schemaVersion == 1, record.role == "assertion" else {
      throw WikiError.unavailable("지원하지 않는 주장 레코드 형식입니다.")
    }
    let value = try JSONDecoder().decode(Self.self, from: record.encoded())
    guard value.id == record.recordID else { throw WikiError.changedSource }
    return try value.validated()
  }

  package func validated() throws -> Self {
    try Self.identity(id)
    guard conceptIDs.count <= 32, Set(conceptIDs).count == conceptIDs.count,
      conditions.count <= 32, !evidence.isEmpty, evidence.count <= 64,
      Set(evidence.map { $0.evidence.id }).count == evidence.count else {
      throw WikiError.invalidSource("주장의 개념·조건·원문 근거 수를 확인해 주세요.")
    }
    for concept in conceptIDs { try Self.identity(concept) }
    guard evidence.allSatisfy({ !$0.evidence.id.isEmpty && $0.evidence.id.utf8.count <= 512
      && !$0.evidence.text.isEmpty && $0.evidence.text.utf8.count <= 16_384 }) else {
      throw WikiError.invalidSource("주장 근거가 저장 가능한 범위를 넘습니다.")
    }
    let items = Dictionary(uniqueKeysWithValues: evidence.map { ($0.evidence.id, $0) })
    let supporting = try validate(statement, items: items, maximum: 8_192, statement: true)
    guard !supporting.isEmpty else { throw WikiError.invalidSource("주장에는 지지 역할의 원문 근거가 필요합니다.") }
    if statement.origin == .quoted, let value {
      guard try Self.literalQuote(value.text, occursIn: statement.text) else {
        throw WikiError.invalidSource("직접 인용한 주장에 명시된 값을 선택해 주세요. 다른 행의 값을 결합할 수 없습니다.")
      }
    }
    var common = supporting
    for facet in [value, unit, edition].compactMap({ $0 }) {
      guard facet.origin == .quoted else {
        throw WikiError.invalidSource("값·단위·판본은 원문에 있는 표현으로 기록해 주세요.")
      }
      common.formIntersection(try validate(facet, items: items, maximum: 1_024, statement: false))
    }
    for condition in conditions {
      let sources = try validate(condition, items: items, maximum: 2_048, statement: false)
      if condition.origin == .quoted { common.formIntersection(sources) }
    }
    guard !common.isEmpty else {
      throw WikiError.invalidSource("주장·조건·값·단위·판본이 같은 원문을 근거로 하는지 확인해 주세요.")
    }
    return self
  }

  private struct PhysicalSource: Hashable {
    let scope: String
    let path: String
    let revision: String
    init(_ evidence: WikiKnowledgeEvidence) {
      scope = evidence.source.scopeID; path = evidence.source.relativePath; revision = evidence.source.revision
    }
  }

  private func validate(_ field: WikiKnowledgeAssertionText, items: [String: WikiKnowledgeAssertionEvidence],
    maximum: Int, statement isStatement: Bool
  ) throws -> Set<PhysicalSource> {
    Set(try resolve(field, items: items, maximum: maximum, statement: isStatement)
      .filter { !isStatement || $0.role == .support }.map { PhysicalSource($0.evidence) })
  }

  private func resolve(_ field: WikiKnowledgeAssertionText, items: [String: WikiKnowledgeAssertionEvidence],
    maximum: Int, statement isStatement: Bool
  ) throws -> [WikiKnowledgeAssertionEvidence] {
    guard !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      field.text.utf8.count <= maximum, !field.text.contains("\0"),
      !field.citations.isEmpty, field.citations.count <= 64,
      Set(field.citations).count == field.citations.count else {
      throw WikiError.invalidSource("주장과 각 항목에는 원문 문구를 연결해 주세요.")
    }
    var resolved: [WikiKnowledgeAssertionEvidence] = []
    var citedQuotes: [String] = []
    let numbers = try Self.numericTokens(field.text)
    let isUnit = unit.map { $0 == field } ?? false
    for citation in field.citations {
      guard let item = items[citation.evidenceID], !citation.quote.isEmpty,
        citation.quote.utf8.count <= 16_384, !citation.quote.contains("\0"),
        try Self.literalQuote(citation.quote, occursIn: item.evidence.text, unit: isUnit) else {
        throw WikiError.invalidSource("인용 문구와 원문 근거가 일치하지 않습니다.")
      }
      let eligible = field.origin == .interpretation || !isStatement ? item.role != .refute : item.role == .support
      if !isStatement, !eligible {
        throw WikiError.invalidSource("반박 근거를 값·조건의 지지로 사용할 수 없습니다.")
      }
      guard eligible else { continue }
      citedQuotes.append(citation.quote)
      if field.origin == .interpretation {
        resolved.append(item)
      } else if try Self.literalQuote(field.text, occursIn: citation.quote, unit: isUnit),
        numbers.allSatisfy(Set(try Self.numericTokens(citation.quote)).contains) {
        // Only the exact literal-bearing source can support a quoted facet.
        // An unrelated second citation cannot bridge values across two books.
        resolved.append(item)
      }
    }
    guard !resolved.isEmpty else {
      throw WikiError.invalidSource("직접 인용한 항목은 지지 문구 안의 완전한 표현이어야 합니다.")
    }
    let allowedNumbers = Set(try citedQuotes.flatMap(Self.numericTokens))
    guard numbers.allSatisfy({ allowedNumbers.contains($0) }) else {
      throw WikiError.invalidSource("수치의 부호·소수점·지수를 원문과 같은 표현으로 기록해 주세요.")
    }
    return resolved
  }

  /// Preserve literal tokens: 42 cannot be derived from -42, 4.2, or 42e3 by substring clipping.
  private static func numericExpression() throws -> NSRegularExpression {
    let pattern = #"(?<![\p{L}0-9_+\-−–—.,])[+\-−–—]?(?:[0-9]+(?:[.,][0-9]+)*|[.,][0-9]+)(?:[eE][+\-−]?[0-9]+)?(?![0-9_eE]|[.,][0-9])"#
    return try NSRegularExpression(pattern: pattern)
  }
  private static func numericTokens(_ text: String) throws -> [String] {
    let regex = try numericExpression()
    let string = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range) }
  }

  /// A quote cannot obtain a positive value by clipping the minus sign from the source token.
  private static func literalQuote(_ quote: String, occursIn text: String, unit: Bool = false) throws -> Bool {
    guard Data(text.utf8).range(of: Data(quote.utf8)) != nil else { return false }
    let regex = try numericExpression(), source = text as NSString, quoted = quote as NSString
    let word = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "_"))
    let scalars = text.unicodeScalars
    let firstIsWord = quote.unicodeScalars.first.map(word.contains) ?? false
    let lastIsWord = quote.unicodeScalars.last.map(word.contains) ?? false
    // Korean suffixes attach directly to Latin units and numbers: "20 °C에서", "42이다".
    // This is only an ASCII-token → Hangul boundary, not Korean word segmentation.
    let endsInASCIIToken = quote.unicodeScalars.last.map {
      (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value)
    } ?? false
    let sourceTokens = regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
    let quoteTokens = regex.matches(in: quote, range: NSRange(location: 0, length: quoted.length)).map(\.range)
    var search = NSRange(location: 0, length: source.length)
    while search.length > 0 {
      let occurrence = source.range(of: quote, options: .literal, range: search)
      guard occurrence.location != NSNotFound, let range = Range(occurrence, in: text),
        let start = range.lowerBound.samePosition(in: scalars), let end = range.upperBound.samePosition(in: scalars) else { return false }
      let leading = !firstIsWord || start == scalars.startIndex || !word.contains(scalars[scalars.index(before: start)])
      let trailing = !lastIsWord || end == scalars.endIndex || !word.contains(scalars[end])
        || (endsInASCIIToken && Self.isHangul(scalars[end]))
      let compoundClipped: Bool
      if unit {
        let parentheses = CharacterSet(charactersIn: "()（）")
        let operators = CharacterSet(charactersIn: "/∕*·⋅^⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁽⁾")
        let before = start == scalars.startIndex ? nil : scalars[scalars.index(before: start)]
        let after = end == scalars.endIndex ? nil : scalars[end]
        var previous = start
        while previous > scalars.startIndex, scalars[scalars.index(before: previous)].properties.isWhitespace {
          previous = scalars.index(before: previous)
        }
        var next = end
        while next < scalars.endIndex, scalars[next].properties.isWhitespace { next = scalars.index(after: next) }
        let operatorBefore = previous > scalars.startIndex && operators.contains(scalars[scalars.index(before: previous)])
        let operatorAfter = next < scalars.endIndex && operators.contains(scalars[next])
        compoundClipped = before.map(parentheses.contains) == true || after.map(parentheses.contains) == true
          || operatorBefore || operatorAfter
      } else { compoundClipped = false }
      let clipped = sourceTokens.contains { token in
        NSIntersectionRange(token, occurrence).length > 0
          && (token.location < occurrence.location || NSMaxRange(token) > NSMaxRange(occurrence))
      }
      if leading && trailing && !clipped && !compoundClipped, quoteTokens.allSatisfy({ token in
        sourceTokens.contains(NSRange(location: occurrence.location + token.location, length: token.length))
      }) { return true }
      let next = occurrence.location + 1
      search = NSRange(location: next, length: source.length - next)
    }
    return false
  }

  private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7A3, 0xD7B0...0xD7FF, 0xFFA0...0xFFDC: true
    default: false
    }
  }

  private static func identity(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 512, !value.hasPrefix("path:"),
      value == value.precomposedStringWithCanonicalMapping,
      !value.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" || $0 == "\0" }) else {
      throw WikiError.invalidSource("주장과 개념에는 안정적인 식별자가 필요합니다.")
    }
  }

  /// Shape comparison rejects unknown keys at every nested level without a second evidence schema.
  private static func strictKeys(_ input: WikiJSONValue, matching encoded: WikiJSONValue, path: [String] = []) throws {
    switch (input, encoded) {
    case (.object(let raw), .object(let typed)):
      let nullable: Set<String>
      switch path {
      case []: nullable = ["value", "unit", "edition"]
      case ["evidence", "*", "evidence"]: nullable = ["pdfRegion"]
      case ["evidence", "*", "evidence", "pdfRegion"]: nullable = ["imageIndex"]
      default: nullable = []
      }
      guard Set(raw.keys).subtracting(typed.keys).isSubset(of: nullable),
        raw.filter({ !typed.keys.contains($0.key) }).allSatisfy({ $0.value == .null }) else {
        throw WikiError.invalidSource("주장 입력에 허용되지 않은 필드가 있습니다.")
      }
      for (key, value) in raw {
        if let expected = typed[key] { try strictKeys(value, matching: expected, path: path + [key]) }
      }
    case (.array(let raw), .array(let typed)):
      guard raw.count == typed.count else { throw WikiError.invalidSource("주장 입력 배열이 올바르지 않습니다.") }
      for (value, expected) in zip(raw, typed) { try strictKeys(value, matching: expected, path: path + ["*"]) }
    default: break
    }
  }
}
