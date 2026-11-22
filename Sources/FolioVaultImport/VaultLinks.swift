import Foundation

/// Pure conversion state: an immutable lookup and diagnostics in source order.
struct VaultLinks {
  let ids: [String: String]
  private let lookup: [String: Set<String>]
  private(set) var issues: [VaultIssue] = []

  init(files: [VaultInputFile]) {
    ids = Dictionary(uniqueKeysWithValues: files.filter(\.isMarkdown).map {
      ($0.relativePath, VaultPaths.stableID($0.relativePath))
    })
    var index: [String: Set<String>] = [:]
    for file in files {
      let path = file.relativePath
      let name = (path as NSString).lastPathComponent
      let candidates = [path, file.isMarkdown ? (path as NSString).deletingPathExtension : path,
        name, (name as NSString).deletingPathExtension]
      for candidate in candidates { index[VaultPaths.key(candidate), default: []].insert(path) }
    }
    lookup = index
  }

  mutating func resolve(_ target: String, source: String) -> String? {
    let raw = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let local = matches(VaultPaths.joined(VaultPaths.parent(source), raw))
    if (raw.contains("/") || raw.hasPrefix(".")), local.count == 1 { return local.first }
    let global = matches(raw)
    if global.count == 1 { return global.first }
    if global.isEmpty, local.count == 1 { return local.first }
    issues.append(VaultIssue(source: source, target: target, reason: global.count > 1 ? "ambiguous" : "missing"))
    return nil
  }

  mutating func convert(_ line: String, source: String, changes: inout [VaultConversion]) -> String {
    var output = ""; var end = 0
    let original = line as NSString
    for match in Self.inlineCode.matches(in: line, range: NSRange(location: 0, length: original.length)) {
      output += convertPlain(original.substring(with: NSRange(location: end, length: match.range.location - end)),
        source: source, changes: &changes)
      output += original.substring(with: match.range)
      end = NSMaxRange(match.range)
    }
    output += convertPlain(original.substring(from: end), source: source, changes: &changes)
    return output
  }

  private func matches(_ key: String) -> Set<String> { lookup[VaultPaths.key(key)] ?? [] }

  private mutating func convertPlain(_ text: String, source: String,
    changes: inout [VaultConversion]) -> String {
    let wiki = Self.replace(text, expression: Self.wiki) { match, original in
      let value = original.substring(with: match.range(at: 1))
      let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
      let target = parts[0]
      guard let resolved = resolve(target, source: source) else { return original.substring(with: match.range) }
      let relative = VaultPaths.relative(from: VaultPaths.parent(source), to: resolved)
      let fragment = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
      let anchor = fragment.count == 2 ? "#" + VaultPaths.quote(String(fragment[1])) : ""
      let label = (parts.count == 2 ? parts[1] : target)
        .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
      changes.append(VaultConversion(from: original.substring(with: match.range), target: resolved, kind: nil))
      return "[\(label)](\(VaultPaths.quote(relative))\(anchor))"
    }
    return Self.replace(wiki, expression: Self.attachment) { match, original in
      let destination = original.substring(with: match.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
      let raw = VaultPaths.unquote(String(destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]))
      guard !raw.isEmpty, !raw.contains(":"), !raw.hasPrefix("/") else { return original.substring(with: match.range) }
      let candidates = matches(VaultPaths.joined(VaultPaths.parent(source), raw))
      guard candidates.count == 1, let target = candidates.first, ids[target] == nil else {
        return original.substring(with: match.range)
      }
      let relative = VaultPaths.relative(from: VaultPaths.notesDirectory + "/" + VaultPaths.parent(source),
        to: VaultPaths.attachmentsDirectory + "/" + target)
      changes.append(VaultConversion(from: original.substring(with: match.range), target: target, kind: "attachment relocation"))
      return original.substring(with: match.range(at: 1)) + "(" + VaultPaths.quote(relative) + ")"
    }
  }

  private static func replace(_ text: String, expression: NSRegularExpression,
    transform: (NSTextCheckingResult, NSString) -> String) -> String {
    let original = text as NSString
    var result = ""; var end = 0
    for match in expression.matches(in: text, range: NSRange(location: 0, length: original.length)) {
      result += original.substring(with: NSRange(location: end, length: match.range.location - end))
      result += transform(match, original); end = NSMaxRange(match.range)
    }
    return result + original.substring(from: end)
  }

  // Conversion recognizes inline code, unescaped wiki links, and Markdown attachment links.
  private static let inlineCode = try! NSRegularExpression(pattern: #"(`+[^`]*`+)"#)
  private static let wiki = try! NSRegularExpression(pattern: #"(?<![\\!])\[\[([^\]\n]+)\]\]"#)
  private static let attachment = try! NSRegularExpression(pattern: #"(!?\[[^\]\n]*\])\(([^)\n]+)\)"#)
}
