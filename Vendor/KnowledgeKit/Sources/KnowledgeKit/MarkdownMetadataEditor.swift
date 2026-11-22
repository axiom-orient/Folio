import Foundation
import Markdown

extension WikiMarkdownEditor {
  /// CommonMark escapes apply to ASCII punctuation; formatted Text is otherwise verbatim.
  public static func literalInline(_ text: String) -> String {
    text.map { character in
      guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value else { return String(character) }
      let escaped = (33...47).contains(value) || (58...64).contains(value)
        || (91...96).contains(value) || (123...126).contains(value)
      return (escaped ? "\\" : "") + String(character)
    }.joined()
  }

  /// A complete level-one heading, without a terminating newline.
  public static func literalHeading(_ title: String) -> String { "# " + literalInline(title) }

  /// Patch title/tags together without serializing unrelated YAML or Markdown.
  public static func editingMetadata(bytes: Data, title rawTitle: String?, tags: [String],
    relativePath: String = "notes/metadata.md"
  ) throws -> Data {
    let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    if let title {
      guard !title.isEmpty, title.utf8.count <= 512,
        !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
        throw WikiError.invalidSource("A title must be nonempty, single-line text of at most 512 UTF-8 bytes.")
      }
    }
    let tags = try WikiTags.normalize(tags)
    let before = try WikiMarkdownParser.document(relativePath: relativePath, bytes: bytes)
    let source = try SourceText(bytes); let metadata = try Frontmatter.read(source)
    let newline = source.newline
    let body = source.markdownBody(startingAt: metadata.bodyLine)
    let ast = Markdown.Document(parsing: body)
    var result = bytes
    if let title, title != before.title {
      if let heading = ast.children.compactMap({ $0 as? Heading }).first, let range = heading.range {
        let lower = range.lowerBound.line - 1; let upper = range.upperBound.line - 1
        guard lower >= metadata.bodyLine - 1, upper < source.lines.count else { throw WikiError.invalidSource("Invalid heading coordinates.") }
        let start = source.lines[lower].start; let end = source.lines[upper].contentEnd
        result.replaceSubrange(start..<end, with: Data((String(repeating: "#", count: heading.level) + " " + literalInline(title)).utf8))
      } else {
        var start = metadata.bodyLine > source.lines.count ? bytes.count : source.lines[metadata.bodyLine - 1].start
        if start == 0, bytes.starts(with: [0xef, 0xbb, 0xbf]) { start = 3 }
        result.insert(contentsOf: Data((literalHeading(title) + newline + newline).utf8), at: start)
      }
    }
    // Frontmatter offsets precede body edits, so title publication cannot shift them.
    if tags != before.tags { result = try WikiYAMLTagsEditor.edit(bytes: result, tags: tags) }
    guard result.count <= 256 * 1024 else { throw WikiError.invalidSource("Edited Markdown exceeds 256 KiB.") }
    let after = try WikiMarkdownParser.document(relativePath: relativePath, bytes: result)
    let updatedFields = try Frontmatter.read(SourceText(result)).fields
    guard after.stableID == before.stableID, after.title == (title ?? before.title), after.tags == tags else {
      throw WikiError.invalidSource("Metadata could not be edited without changing document identity or meaning.")
    }
    guard metadata.fields.filter({ $0.key != "tags" }) == updatedFields.filter({ $0.key != "tags" }) else {
      throw WikiError.invalidSource("Metadata edit would change unrelated YAML fields.")
    }
    return result
  }
}
