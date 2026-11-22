import Foundation
import FolioKnowledge
import Markdown

struct WikiLinkSourceMetadata {
  struct Link { let target: String; let title: String? }
  let links: [Range<Int>: Link]

  init(bytes: Data) throws {
    let raw = Array(bytes)
    var lines: [(start: Int, text: String)] = []
    var start = 0; var cursor = 0
    while cursor < raw.count {
      if raw[cursor] == 10 || raw[cursor] == 13 {
        lines.append((start, String(decoding: raw[start..<cursor], as: UTF8.self)))
        if raw[cursor] == 13, cursor + 1 < raw.count, raw[cursor + 1] == 10 { cursor += 1 }
        cursor += 1; start = cursor
      } else { cursor += 1 }
    }
    lines.append((start, String(decoding: raw[start...], as: UTF8.self)))
    var body = lines.map(\.text)
    if ["---", "\u{feff}---"].contains(body.first ?? ""), let end = body.indices.dropFirst().first(where: { body[$0] == "---" }) {
      for index in 0...end { body[index] = "" }
    }
    var found: [Range<Int>: Link] = [:]
    var pending: [any Markup] = [Markdown.Document(parsing: body.joined(separator: "\n"))]
    while let node = pending.popLast() {
      let target: String?; let title: String?
      if let link = node as? Markdown.Link { target = link.destination; title = link.title }
      else if let image = node as? Markdown.Image { target = image.source; title = image.title }
      else { target = nil; title = nil }
      if let target, let range = node.range {
        guard range.lowerBound.line > 0, range.upperBound.line <= lines.count else { throw WikiError.invalidSource("Invalid link source coordinates.") }
        let lower = lines[range.lowerBound.line - 1].start + range.lowerBound.column - 1
        let upper = lines[range.upperBound.line - 1].start + range.upperBound.column - 1
        guard lower >= 0, upper >= lower, upper <= bytes.count else { throw WikiError.invalidSource("Invalid link source range.") }
        found[lower..<upper] = Link(target: target, title: title)
      }
      pending.append(contentsOf: node.children.reversed())
    }
    links = found
  }
}
