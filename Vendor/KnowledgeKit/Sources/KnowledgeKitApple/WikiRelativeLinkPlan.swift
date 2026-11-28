import Foundation
import FolioKnowledge

/// Destination-only byte patches preserve labels, titles, comments and line endings.
/// Unsupported reference-style rewrites are refused before filesystem effects.
enum WikiRelativeLinkPlan {
  private struct Patch { let range: Range<Int>; let replacement: Data }

  static func rewrite(bytes: Data, document: WikiDocument, newPath: String,
    from: String, to: String) throws -> Data {
    var patches: [Patch] = []
    let metadata = try WikiLinkSourceMetadata(bytes: bytes)
    for declaration in document.declarations where declaration.origin == .markdownLink {
      let target = declaration.target
      guard !target.hasPrefix("#"), !target.contains("\\") else { continue }
      let split = target.firstIndex(where: { $0 == "#" || $0 == "?" }) ?? target.endIndex
      let path = String(target[..<split]); let suffix = String(target[split...])
      guard !path.isEmpty, let resolved = WikiPath.resolveLink(path, from: document.relativePath) else { continue }
      let relocated = WikiFilePaths.moved(resolved, from: from, to: to)
      guard relocated != resolved || parent(newPath) != parent(document.relativePath) else { continue }
      let encoded = quote(relative(from: parent(newPath), to: relocated)) + suffix
      let markup = try declaration.range.extract(from: bytes)
      let syntax = try destinationRange(in: markup)
      let range: Range<Int>; let replacement: Data
      if let destination = syntax.destination { range = destination; replacement = Data(encoded.utf8) }
      else {
        let originalRange = declaration.range.lowerBound..<declaration.range.upperBound
        guard let link = metadata.links[originalRange], link.target == target else { throw unsupported() }
        let title = link.title.map { " \"" + escapedTitle($0) + "\"" } ?? ""
        range = 0..<markup.count
        replacement = markup.prefix(syntax.labelEnd) + Data(("(" + encoded + title + ")").utf8)
      }
      let absolute = (declaration.range.lowerBound + range.lowerBound)..<(declaration.range.lowerBound + range.upperBound)
      if patches.contains(where: { $0.range == absolute }) { continue }
      guard !patches.contains(where: { $0.range.overlaps(absolute) }), patches.count < 8192 else {
        throw WikiError.unavailable("Overlapping or excessive Markdown link rewrites require an explicit edit.")
      }
      patches.append(Patch(range: absolute, replacement: replacement))
    }
    var result = bytes
    for patch in patches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { result.replaceSubrange(patch.range, with: patch.replacement) }
    return result
  }

  private static func destinationRange(in bytes: Data) throws -> (destination: Range<Int>?, labelEnd: Int) {
    let raw = Array(bytes)
    var cursor = raw.first == 33 ? 1 : 0
    guard cursor < raw.count, raw[cursor] == 91 else { throw unsupported() }
    var depth = 1; cursor += 1
    while cursor < raw.count && depth > 0 {
      if raw[cursor] == 92 { cursor += 2; continue }
      if raw[cursor] == 91 { depth += 1 }
      if raw[cursor] == 93 { depth -= 1 }
      cursor += 1
    }
    guard depth == 0 else { throw unsupported() }
    let labelEnd = cursor
    while cursor < raw.count && whitespace(raw[cursor]) { cursor += 1 }
    guard cursor < raw.count, raw[cursor] == 40 else { return (nil, labelEnd) }
    cursor += 1
    while cursor < raw.count && whitespace(raw[cursor]) { cursor += 1 }
    if cursor < raw.count, raw[cursor] == 60 {
      cursor += 1; let start = cursor
      while cursor < raw.count {
        if raw[cursor] == 92 { cursor += 2; continue }
        if raw[cursor] == 62 { return (start..<cursor, labelEnd) }
        cursor += 1
      }
      throw unsupported()
    }
    let start = cursor; depth = 0
    while cursor < raw.count {
      let byte = raw[cursor]
      if byte == 92 { cursor += 2; continue }
      if byte == 40 { depth += 1 }
      if byte == 41 {
        if depth == 0 { return (start..<cursor, labelEnd) }
        depth -= 1
      }
      if whitespace(byte), depth == 0 { return (start..<cursor, labelEnd) }
      cursor += 1
    }
    throw unsupported()
  }

  private static func unsupported() -> WikiError { .unavailable("A relative reference-style or unsupported Markdown link needs an explicit edit before moving this item.") }
  private static func escapedTitle(_ title: String) -> String {
    title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  }
  private static func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
  private static func parent(_ path: String) -> [String] { path.split(separator: "/").dropLast().map(String.init) }
  private static func relative(from source: [String], to target: String) -> String {
    let target = target.split(separator: "/").map(String.init)
    var shared = 0
    while shared < min(source.count, target.count), source[shared] == target[shared] { shared += 1 }
    let components = Array(repeating: "..", count: source.count - shared) + target.dropFirst(shared)
    let path = components.joined(separator: "/")
    return components.first?.contains(":") == true ? "./" + path : path
  }
  private static func quote(_ path: String) -> String {
    path.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")) ?? path
  }
}
