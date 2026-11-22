import Foundation
import Markdown
import Yams

public enum WikiMarkdownParser {
  package static let metadataVersion = 1
  public static func validate(range: WikiSourceRange, bytes: Data) throws {
    _ = try range.extract(from: bytes)
    let source = try SourceText(bytes)
    let start = (source.lines.lastIndex { $0.start <= range.lowerBound } ?? 0) + 1
    let lastByte = range.upperBound > range.lowerBound ? range.upperBound - 1 : range.upperBound
    let end = (source.lines.lastIndex { $0.start <= lastByte } ?? 0) + 1
    let includesEmptyEOF = range.upperBound == bytes.count && range.endLine == source.lines.count && source.lines.last?.text.isEmpty == true
    guard range.startLine == start, range.endLine == end || includesEmptyEOF else {
      throw WikiError.invalidSource("Byte offsets and line coordinates disagree.")
    }
  }

  public static func excerpt(bytes: Data, startLine: Int, maximumLines: Int) throws -> WikiRawExcerpt {
    let source = try SourceText(bytes)
    guard startLine > 0, startLine <= source.lines.count, (1...80).contains(maximumLines) else {
      throw WikiError.invalidSource("Invalid original source line range.")
    }
    let end = min(source.lines.count, startLine + maximumLines - 1)
    let range = source.range(startLine: startLine, endLine: end)
    let excerpt = try range.extract(from: bytes)
    guard excerpt.count <= 65536 else { throw WikiError.invalidSource("Use fewer lines for an oversized source block.") }
    return WikiRawExcerpt(sourceRevision: SourceDigest.sha256(bytes), range: range,
      text: String(decoding: excerpt, as: UTF8.self), hasMore: end < source.lines.count)
  }

  public static func workspace(bytes: Data) throws -> WikiWorkspaceIdentity {
    let fields = try Frontmatter.read(SourceText(bytes)).fields
    guard let kind = fields["kind"], try Frontmatter.string(kind) == "workspace",
      let idNode = fields["id"], let id = UUID(uuidString: try Frontmatter.string(idNode)),
      let schema = fields["schema"], schema.tag.rawValue == "tag:yaml.org,2002:int",
      schema.scalar?.string == "1", let name = fields["name"]
    else { throw WikiError.invalidSource("Expected workspace UUID, kind: workspace and schema: 1.") }
    return WikiWorkspaceIdentity(id: id, name: try Frontmatter.string(name))
  }

  public static func document(relativePath: String, bytes: Data, sectionBudget: Int = 16384) throws -> WikiDocument {
    let path = try WikiPath.validate(relativePath)
    guard ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()), sectionBudget > 0 else {
      throw WikiError.invalidSource("Expected Markdown and a positive section budget.")
    }
    let source = try SourceText(bytes)
    let frontmatter = try Frontmatter.read(source)
    let stableID = try frontmatter.fields["id"].map { try Frontmatter.string($0).precomposedStringWithCanonicalMapping }
    if let stableID {
      guard !stableID.hasPrefix("path:"), !stableID.contains("/"), !stableID.contains("\\"),
        !stableID.contains(where: { $0.isWhitespace || $0.isNewline }) else {
        throw WikiError.invalidSource("Document IDs cannot be paths or contain whitespace.")
      }
    }
    let id = stableID ?? "path:\(path.precomposedStringWithCanonicalMapping)"
    let type = try frontmatter.fields["type"].map(Frontmatter.string)
    let aliases = try frontmatter.fields["aliases"].map(Frontmatter.strings) ?? []
    let tags = try frontmatter.fields["tags"].map { node -> [String] in
      if case .sequence(let children) = node {
        guard children.count <= 64 else { throw WikiError.invalidSource("Tags accept at most 64 entries.") }
        return try WikiTags.normalize(children.map(Frontmatter.string))
      }
      return try WikiTags.normalize([Frontmatter.string(node)])
    } ?? []
    var declarations: [WikiRelationDeclaration] = []
    if let relations = frontmatter.fields["relations"], case .mapping(let entries) = relations {
      for pair in entries {
        let predicate = try Frontmatter.string(pair.key)
        let start = min(source.lines.count, max(1, (pair.key.mark?.line ?? 1) + 1))
        for target in try Frontmatter.strings(pair.value) {
          let end = min(source.lines.count, max(start, (pair.value.sequence?.last?.mark?.line ?? pair.value.mark?.line ?? 1) + 1))
          declarations.append(WikiRelationDeclaration(predicate: predicate, target: target, origin: .frontmatter,
            range: source.range(startLine: start, endLine: end)))
        }
      }
    } else if frontmatter.fields["relations"] != nil { throw WikiError.invalidSource("Expected relations mapping.") }
    let body = source.markdownBody(startingAt: frontmatter.bodyLine)
    let ast = Markdown.Document(parsing: body)
    let headings = ast.children.compactMap { node -> (Int, String, Int)? in
      guard let heading = node as? Heading, let range = heading.range else { return nil }
      return (heading.level, heading.plainText, range.lowerBound.line)
    }
    let title = headings.first?.1 ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    var boundaries: [(line: Int, headingPath: [String])] = []
    if frontmatter.bodyLine < (headings.first?.2 ?? source.lines.count + 1), frontmatter.bodyLine <= source.lines.count {
      boundaries.append((frontmatter.bodyLine, []))
    }
    var chain: [(Int, String)] = []
    for (level, heading, line) in headings {
      chain.removeAll { $0.0 >= level }; chain.append((level, heading))
      boundaries.append((line, chain.map { $0.1 }))
    }
    let blockStarts = ast.children.compactMap { $0.range?.lowerBound.line }
    var sections: [WikiSection] = []
    for (index, boundary) in boundaries.enumerated() {
      let endLine = index + 1 < boundaries.count ? boundaries[index + 1].line - 1 : source.lines.count
      var starts = [boundary.line]; var partStart = boundary.line
      for line in blockStarts where line > boundary.line && line <= endLine {
        if source.lines[line - 1].start - source.lines[partStart - 1].start > sectionBudget {
          starts.append(line); partStart = line
        }
      }
      for (part, start) in starts.enumerated() {
        let end = part + 1 < starts.count ? starts[part + 1] - 1 : endLine
        let range = source.range(startLine: start, endLine: end)
        let raw = try range.extract(from: bytes)
        let text = String(decoding: raw, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        let sectionID = SourceDigest.sha256("\(id)\0\(boundary.headingPath.joined(separator: "\0"))\0\(index):\(part)")
        sections.append(WikiSection(id: sectionID, documentID: id, ordinal: sections.count,
          headingPath: boundary.headingPath, range: range, sourceText: text,
          searchText: ([title, boundary.headingPath.joined(separator: " > "), text]).joined(separator: "\n\n"),
          contentHash: SourceDigest.sha256(raw)))
      }
    }
    var pending: [any Markup] = [ast]
    while let node = pending.popLast() {
      try Task.checkCancellation()
      let destination: String?
      if let link = node as? Link { destination = link.destination }
      else if let image = node as? Image, let target = image.source,
        let resolved = WikiPath.resolveLink(target, from: path),
        !["md", "markdown"].contains(URL(fileURLWithPath: resolved).pathExtension.lowercased()) {
        destination = target
      }
      else { destination = nil }
      if let target = destination, let location = node.range {
        let first = location.lowerBound; let last = location.upperBound
        guard first.line > 0, last.line <= source.lines.count, last.line >= first.line else {
          throw WikiError.invalidSource("Markdown link has an invalid source range.")
        }
        let lower = source.lines[first.line - 1].start + first.column - 1
        let upper = source.lines[last.line - 1].start + last.column - 1
        let range = WikiSourceRange(lowerBound: lower, upperBound: upper,
          startLine: first.line, endLine: last.line)
        _ = try range.extract(from: bytes)
        declarations.append(WikiRelationDeclaration(predicate: "references", target: target,
          origin: .markdownLink, range: range))
      }
      pending.append(contentsOf: node.children.reversed())
    }
    if sections.isEmpty {
      let range = source.range(startLine: 1, endLine: source.lines.count)
      sections = [WikiSection(id: SourceDigest.sha256("\(id)\0whole-source"), documentID: id, ordinal: 0,
        headingPath: [], range: range, sourceText: String(decoding: bytes, as: UTF8.self),
        searchText: title, contentHash: SourceDigest.sha256(bytes))]
    }
    return WikiDocument(id: id, stableID: stableID, relativePath: path, title: title, type: type,
      aliases: aliases, tags: tags, revision: SourceDigest.sha256(bytes), sections: sections, declarations: declarations)
  }
}
