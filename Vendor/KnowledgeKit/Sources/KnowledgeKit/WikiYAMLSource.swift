import Foundation
import Yams

/// Source coordinates and lexical boundaries complement Yams' semantic validation.
struct WikiYAMLSource {
  let source: SourceText
  let raw: [UInt8]
  let bodyLine: Int
  let newline: String

  init(_ bytes: Data) throws {
    source = try SourceText(bytes); raw = Array(bytes)
    bodyLine = try Frontmatter.read(source).bodyLine
    newline = source.newline
  }

  func offset(_ mark: Mark?) throws -> Int {
    guard let mark, mark.line > 0, mark.line < source.lines.count, mark.column > 0 else {
      throw WikiError.invalidSource("YAML metadata has no unambiguous source coordinates.")
    }
    let line = source.lines[mark.line]
    guard mark.column - 1 <= line.text.unicodeScalars.count else { throw WikiError.invalidSource("Invalid YAML source column.") }
    return line.start + line.text.unicodeScalars.prefix(mark.column - 1).reduce(0) { $0 + String($1).utf8.count }
  }

  func valueEnd(_ node: Node, bound: Int) throws -> Int {
    let start = try offset(node.mark)
    guard start < bound, bound <= raw.count else { throw WikiError.invalidSource("Ambiguous YAML metadata extent.") }
    if raw[start] == 34 || raw[start] == 39 { return try quotedEnd(start) }
    if raw[start] == 91 || raw[start] == 123 { return try flow(start).end }
    if case .sequence(let children) = node {
      guard !children.isEmpty else { throw WikiError.invalidSource("Cannot locate an empty block sequence.") }
      return try children.enumerated().map { index, child in
        let end: Int
        if index + 1 < children.count {
          guard let mark = children[index + 1].mark, mark.line < source.lines.count else { throw WikiError.invalidSource("Invalid tags sequence coordinates.") }
          end = source.lines[mark.line].start
        } else { end = bound }
        return try valueEnd(child, bound: end)
      }.max()!
    }
    let block = raw[start] == 124 || raw[start] == 62
    var last = start
    for line in source.lines where line.start < bound && line.contentEnd > start {
      let lower = max(start, line.start); let upper = min(bound, line.contentEnd)
      let comment = block && line.start > start ? nil : commentStart(lower..<upper)
      var end = comment ?? upper
      while end > lower, [9, 32].contains(raw[end - 1]) { end -= 1 }
      if end > lower { last = end }
    }
    guard last > start else { throw WikiError.invalidSource("Cannot locate YAML metadata value.") }
    return last
  }

  func quotedEnd(_ start: Int) throws -> Int {
    let quote = raw[start]; var cursor = start + 1
    while cursor < raw.count {
      if quote == 34, raw[cursor] == 92 { cursor += 2; continue }
      if raw[cursor] == quote {
        if quote == 39, cursor + 1 < raw.count, raw[cursor + 1] == 39 { cursor += 2; continue }
        return cursor + 1
      }
      cursor += 1
    }
    throw WikiError.invalidSource("Unterminated YAML metadata string.")
  }

  func flow(_ start: Int) throws -> (end: Int, commas: [Int]) {
    var stack: [UInt8] = []; var commas: [Int] = []; var cursor = start; var tokenStart = true
    while cursor < raw.count {
      let byte = raw[cursor]
      if (byte == 34 || byte == 39), tokenStart { cursor = try quotedEnd(cursor); tokenStart = false; continue }
      if byte == 35, cursor == start || [9, 10, 13, 32, 44, 91, 123].contains(raw[cursor - 1]) {
        while cursor < raw.count, ![10, 13].contains(raw[cursor]) { cursor += 1 }; continue
      }
      if byte == 91 || byte == 123 { stack.append(byte) }
      else if byte == 93 || byte == 125 {
        guard stack.popLast() == (byte == 93 ? 91 : 123) else { throw WikiError.invalidSource("Mismatched YAML metadata delimiter.") }
        if stack.isEmpty { return (cursor + 1, commas) }
      } else if byte == 44, stack.count == 1 { commas.append(cursor) }
      tokenStart = nextTokenState(byte, at: cursor, current: tokenStart); cursor += 1
    }
    throw WikiError.invalidSource("Unterminated YAML metadata container.")
  }

  func comments(_ range: Range<Int>, blockValueStart: Int? = nil) throws -> [String] {
    var result: [String] = []; var cursor = range.lowerBound; var tokenStart = true
    while cursor < range.upperBound {
      let byte = raw[cursor]
      if let blockValueStart, cursor > blockValueStart,
        raw[blockValueStart..<cursor].contains(where: { $0 == 10 || $0 == 13 }) { break }
      if (byte == 34 || byte == 39), tokenStart { cursor = try quotedEnd(cursor); tokenStart = false; continue }
      if byte == 35, cursor == range.lowerBound || [9, 10, 13, 32, 44, 91, 123].contains(raw[cursor - 1]) {
        let start = cursor
        while cursor < range.upperBound, ![10, 13].contains(raw[cursor]) { cursor += 1 }
        result.append(String(decoding: raw[start..<cursor], as: UTF8.self)); continue
      }
      tokenStart = nextTokenState(byte, at: cursor, current: tokenStart); cursor += 1
    }
    return result
  }

  private func commentStart(_ range: Range<Int>) -> Int? {
    range.first { raw[$0] == 35 && ($0 == range.lowerBound || [9, 32].contains(raw[$0 - 1])) }
  }

  private func nextTokenState(_ byte: UInt8, at index: Int, current: Bool) -> Bool {
    if [10, 13, 44, 91, 123].contains(byte) { return true }
    if [9, 32].contains(byte) { return current }
    if byte == 58, index + 1 < raw.count, [9, 10, 13, 32, 34, 39, 91, 123].contains(raw[index + 1]) { return true }
    if byte == 45, current, index + 1 < raw.count, [9, 32].contains(raw[index + 1]) { return true }
    return false
  }
}
