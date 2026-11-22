import Foundation
import FolioKnowledge
import Yams

struct VaultMarkdown {
  let data: Data
  let type: String
  let conversions: [VaultConversion]
  let parent: VaultParentRelation?

  init(file: VaultInputFile, links: inout VaultLinks) throws {
    guard let text = String(data: file.data, encoding: .utf8) else {
      throw VaultImportError.invalid("Markdown 원본은 UTF-8 문서여야 합니다.")
    }
    let lines = VaultPaths.lines(text)
    let header: String
    let body: [String]
    if let first = lines.first,
      first.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}").union(.whitespacesAndNewlines)) == "---" {
      guard let end = lines.indices.dropFirst().first(where: {
        lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
      }) else { throw VaultImportError.invalid("닫히지 않은 YAML frontmatter가 있습니다.") }
      header = lines[1..<end].joined(); body = Array(lines.dropFirst(end + 1))
    } else { header = ""; body = lines }

    let separation = header.isEmpty || header.utf8.last == 0x0A ? "" : "\n"
    if !header.isEmpty {
      // Use Folio's restricted YAML grammar before Yams materializes values.
      // This also bounds aliases, nesting, frontmatter bytes, and duplicate keys.
      do {
        _ = try WikiMarkdownParser.document(relativePath: file.relativePath,
          bytes: Data(("---\n" + header + separation + "---\n").utf8))
      } catch { throw VaultImportError.invalid("원본 frontmatter를 Folio 메타데이터로 읽을 수 없습니다.") }
    }

    let fields: [String: Any]
    do {
      let parsed = try Yams.load(yaml: header)
      guard parsed == nil || parsed is [String: Any] else {
        throw VaultImportError.invalid("YAML frontmatter는 키와 값으로 구성되어야 합니다.")
      }
      fields = parsed as? [String: Any] ?? [:]
    } catch let error as VaultImportError { throw error }
    catch { throw VaultImportError.invalid("YAML frontmatter를 해석하지 못했습니다.") }
    guard !fields.keys.contains("id"), !fields.keys.contains("relations") else {
      throw VaultImportError.invalid("기존 id·relations는 자동으로 덮어쓰지 않습니다. 명시적 마이그레이션이 필요합니다.")
    }
    if let value = fields["type"] {
      guard let value = value as? String, !value.isEmpty else {
        throw VaultImportError.invalid("frontmatter의 type은 비어 있지 않은 문자열이어야 합니다.")
      }
      type = value
    } else { type = "document" }

    var relation: VaultParentRelation?
    if let target = Self.parentTarget(header, fields: fields),
      let resolved = links.resolve(target, source: file.relativePath), links.ids[resolved] != nil {
      relation = VaultParentRelation(target: resolved)
    }
    parent = relation
    var additions = "id: " + (try VaultPaths.jsonString(VaultPaths.stableID(file.relativePath))) + "\n"
    if !fields.keys.contains("type") { additions += "type: document\n" }
    var relationHeader = ""
    if let relation, let parentID = links.ids[relation.target] {
      relationHeader = "relations:\n  part_of: [" + (try VaultPaths.jsonString(parentID)) + "]\n"
    }

    var converted: [String] = []; var changes: [VaultConversion] = []
    var fence: (marker: Character, length: Int)?
    for line in body {
      if let marker = Self.capture(Self.fence, in: line), let character = marker.first {
        if fence == nil { fence = (character, marker.count) }
        else if fence?.marker == character, marker.count >= (fence?.length ?? 0) { fence = nil }
        converted.append(line)
      } else {
        converted.append(fence == nil ? links.convert(line, source: file.relativePath, changes: &changes) : line)
      }
    }
    data = Data(("---\n" + additions + header + separation + relationHeader + "---\n" + converted.joined()).utf8)
    conversions = changes
  }

  private static func parentTarget(_ header: String, fields: [String: Any]) -> String? {
    if let raw = capture(parent, in: header) {
      return String(raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }
    // Semantic fallback handles quoted YAML keys while preserving legacy unquoted [[parent]].
    if let value = fields["parent"] as? String, value.hasPrefix("[["), let end = value.range(of: "]]") {
      return String(value[value.index(value.startIndex, offsetBy: 2)..<end.lowerBound]
        .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }
    return nil
  }

  private static func capture(_ expression: NSRegularExpression, in text: String) -> String? {
    let text = text as NSString
    guard let match = expression.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { return nil }
    return text.substring(with: match.range(at: 1))
  }

  private static let parent = try! NSRegularExpression(pattern: #"^parent:\s*["']?\[\[([^\]\n]+)\]\]"#,
    options: .anchorsMatchLines)
  private static let fence = try! NSRegularExpression(pattern: #"^\s{0,3}(`{3,}|~{3,})"#)
}
