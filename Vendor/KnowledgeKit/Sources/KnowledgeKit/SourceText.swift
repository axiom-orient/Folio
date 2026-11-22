import Foundation

struct SourceText {
  struct Line { let text: String; let start: Int; let contentEnd: Int; let end: Int }
  let lines: [Line]

  init(_ bytes: Data) throws {
    guard bytes.count <= 4 * 1024 * 1024,
      let text = String(data: bytes, encoding: .utf8), !text.contains("\0")
    else { throw WikiError.invalidSource("Expected UTF-8 text of at most 4 MiB.") }
    let raw = [UInt8](bytes)
    var result: [Line] = []; var start = 0; var cursor = 0
    while cursor < raw.count {
      if raw[cursor] == 10 || raw[cursor] == 13 {
        let contentEnd = cursor
        if raw[cursor] == 13, cursor + 1 < raw.count, raw[cursor + 1] == 10 { cursor += 1 }
        cursor += 1
        result.append(Line(text: String(decoding: raw[start..<contentEnd], as: UTF8.self),
          start: start, contentEnd: contentEnd, end: cursor))
        start = cursor
      } else { cursor += 1 }
    }
    result.append(Line(text: String(decoding: raw[start..<raw.count], as: UTF8.self),
      start: start, contentEnd: raw.count, end: raw.count))
    lines = result
  }

  var newline: String { lines.contains { $0.end - $0.contentEnd == 2 } ? "\r\n" : "\n" }

  /// Blank metadata lines so Markdown coordinates still refer to original source lines.
  func markdownBody(startingAt bodyLine: Int) -> String {
    lines.enumerated().map { $0.offset + 1 < bodyLine ? "" : $0.element.text }.joined(separator: "\n")
  }

  func range(startLine: Int, endLine: Int) -> WikiSourceRange {
    WikiSourceRange(lowerBound: lines[startLine - 1].start, upperBound: lines[endLine - 1].end,
      startLine: startLine, endLine: endLine)
  }
}
