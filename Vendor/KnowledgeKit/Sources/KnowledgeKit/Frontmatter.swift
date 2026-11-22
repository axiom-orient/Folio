import Foundation
import Yams

/// Adapted from SEMI's restricted source reader; domain state never stores Yams/Markdown types.
enum Frontmatter {
  static func read(_ source: SourceText) throws -> (fields: [String: Node], bodyLine: Int) {
    guard source.lines.first?.text == "---" || source.lines.first?.text == "\u{feff}---" else {
      return ([:], 1)
    }
    guard let end = source.lines.dropFirst().firstIndex(where: { $0.text == "---" }),
      source.lines[end].end <= 65536
    else { throw WikiError.invalidSource("Unterminated or oversized YAML frontmatter.") }
    let yaml = source.lines[1..<end].map(\.text).joined(separator: "\n")
    let parser = try Yams.Parser(yaml: yaml)
    guard let node = try parser.singleRoot() else { return ([:], end + 2) }
    // Node.anchor is weak. Keep its parser-owned anchor store alive until validation finishes.
    return try withExtendedLifetime(parser) {
      var budget = 4096
      try validate(node, depth: 0, budget: &budget)
      return (try mapping(node), end + 2)
    }
  }

  private static func validate(_ node: Node, depth: Int, budget: inout Int) throws {
    budget -= 1
    guard depth <= 12, budget >= 0, node.anchor == nil,
      ["tag:yaml.org,2002:str", "tag:yaml.org,2002:map", "tag:yaml.org,2002:seq",
       "tag:yaml.org,2002:null", "tag:yaml.org,2002:bool", "tag:yaml.org,2002:int",
       "tag:yaml.org,2002:float", "tag:yaml.org,2002:timestamp"].contains(node.tag.rawValue)
    else { throw WikiError.invalidSource("Unsupported YAML tag, anchor or nesting.") }
    switch node {
    case .mapping(let entries):
      var keys = Set<String>()
      for pair in entries {
        let key = try string(pair.key)
        guard key != "<<", keys.insert(key).inserted else {
          throw WikiError.invalidSource("Duplicate/merge YAML key: \(key)")
        }
        try validate(pair.value, depth: depth + 1, budget: &budget)
      }
    case .sequence(let children):
      for child in children { try validate(child, depth: depth + 1, budget: &budget) }
    case .alias: throw WikiError.invalidSource("YAML aliases are unsupported.")
    case .scalar: break
    }
  }

  static func mapping(_ node: Node) throws -> [String: Node] {
    guard case .mapping(let entries) = node else { throw WikiError.invalidSource("Expected YAML mapping.") }
    var result: [String: Node] = [:]
    for pair in entries {
      let key = try string(pair.key)
      guard result.updateValue(pair.value, forKey: key) == nil else {
        throw WikiError.invalidSource("Duplicate YAML key: \(key)")
      }
    }
    return result
  }

  static func string(_ node: Node) throws -> String {
    guard node.tag.rawValue == "tag:yaml.org,2002:str", let value = node.scalar?.string,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 512,
      !value.contains("\0")
    else { throw WikiError.invalidSource("Expected a nonempty YAML string of at most 512 bytes.") }
    return value
  }

  static func strings(_ node: Node) throws -> [String] {
    guard case .sequence(let children) = node, children.count <= 256 else {
      throw WikiError.invalidSource("Expected a YAML string array with at most 256 entries.")
    }
    let strings = try children.map(string)
    guard Set(strings).count == strings.count else { throw WikiError.invalidSource("Duplicate YAML array entry.") }
    return strings
  }
}
