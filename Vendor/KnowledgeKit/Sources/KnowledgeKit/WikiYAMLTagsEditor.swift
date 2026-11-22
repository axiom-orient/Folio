import Foundation
import Yams

enum WikiYAMLTagsEditor {
  static func edit(bytes: Data, tags: [String]) throws -> Data {
    let text = try WikiYAMLSource(bytes)
    let encoded = String(decoding: try JSONEncoder().encode(tags), as: UTF8.self)
    if text.bodyLine == 1 {
      guard !tags.isEmpty else { return bytes }
      let start = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
      var result = bytes
      result.insert(contentsOf: Data(("---" + text.newline + "tags: " + encoded + text.newline + "---" + text.newline + text.newline).utf8), at: start)
      return result
    }
    let yaml = text.source.lines[1..<(text.bodyLine - 2)].map(\.text).joined(separator: "\n")
    let parser = try Yams.Parser(yaml: yaml)
    let node = try parser.singleRoot()
    return try withExtendedLifetime(parser) {
      guard let node else { return insertBlock(bytes, text: text, encoded: encoded, tags: tags) }
      guard case .mapping(let mapping) = node else { throw WikiError.invalidSource("Expected YAML mapping.") }
      let start = try text.offset(mapping.mark)
      let flow = start < bytes.count && bytes[start] == 123
      guard let index = mapping.firstIndex(where: { $0.key.scalar?.string == "tags" }) else {
        guard !tags.isEmpty else { return bytes }
        if flow {
          var result = bytes
          result.insert(contentsOf: Data(("\"tags\": " + encoded + (mapping.isEmpty ? "" : ", ")).utf8), at: start + 1)
          return result
        }
        return insertBlock(bytes, text: text, encoded: encoded, tags: tags)
      }
      let pair = mapping[index]
      let key = try text.offset(pair.key.mark); let value = try text.offset(pair.value.mark)
      let next = mapping.index(after: index)
      let bound: Int
      if flow {
        let extent = try text.flow(start)
        bound = extent.commas.first(where: { $0 >= value }) ?? (extent.end - 1)
      }
      else if next < mapping.endIndex, let mark = mapping[next].key.mark { bound = text.source.lines[mark.line].start }
      else { bound = text.source.lines[text.bodyLine - 2].start }
      let end = try text.valueEnd(pair.value, bound: bound)
      guard key < value, value < end, end <= bound else { throw WikiError.invalidSource("Ambiguous tags metadata source.") }
      let blockStart = [124, 62].contains(bytes[value]) ? value : nil
      let comments = try text.comments((tags.isEmpty ? key : value)..<end, blockValueStart: blockStart)
      var range = value..<end; var replacement = encoded
      if tags.isEmpty {
        range = key..<end
        if flow {
          let commas = try text.flow(start).commas
          if let comma = commas.first(where: { $0 >= end }) { range = key..<(comma + 1) }
          else if let comma = commas.last(where: { $0 < key }) { range = comma..<end }
        }
        let retained = try text.comments(range, blockValueStart: blockStart)
        replacement = retained.isEmpty ? "" : text.newline + retained.joined(separator: text.newline) + text.newline
      } else if !comments.isEmpty {
        // Comments inside a replaced sequence remain valid trivia inside its new flow value.
        let line = text.source.lines.last(where: { $0.start <= value })!
        let padding = String(repeating: " ", count: line.text.prefix(while: { $0 == " " }).count + 2)
        replacement = "[" + text.newline + padding + comments.joined(separator: text.newline + padding) + text.newline
          + padding + String(encoded.dropFirst().dropLast()) + "]"
      }
      var result = bytes; result.replaceSubrange(range, with: Data(replacement.utf8))
      return result
    }
  }

  private static func insertBlock(_ bytes: Data, text: WikiYAMLSource, encoded: String, tags: [String]) -> Data {
    guard !tags.isEmpty else { return bytes }
    var result = bytes
    result.insert(contentsOf: Data(("tags: " + encoded + text.newline).utf8), at: text.source.lines[text.bodyLine - 2].start)
    return result
  }
}
