import Foundation
import FolioKnowledge
import Markdown

/// A byte-preserving, effect-free merge. Files, revisions and draft admission stay with the caller.
enum FolioDocumentMerge {
  enum Choice: Equatable, Sendable { case edited, received }

  struct Conflict: Identifiable, Sendable {
    let id: Int
    let base: String
    let edited: String
    let received: String
  }

  struct Plan: Sendable {
    let conflicts: [Conflict]
    fileprivate let metadata: String
    fileprivate let segments: [Segment]

    var automaticallyMergedSource: String? {
      conflicts.isEmpty ? resolvedSource(choices: [:]) : nil
    }

    func resolvedSource(choices: [Int: Choice]) -> String? {
      guard Set(choices.keys) == Set(conflicts.map(\.id)) else { return nil }
      let body = segments.map { segment -> String in
        switch segment {
        case .text(let text): return text
        case .conflict(let index):
          return choices[index] == .edited ? conflicts[index].edited : conflicts[index].received
        }
      }.joined()
      let source = FolioEditorContent(source: metadata).replacingBody(with: body)
      return source.utf8.count <= FolioDocumentMerge.maximumSourceBytes ? source : nil
    }
  }

  fileprivate enum Segment: Sendable { case text(String), conflict(Int) }
  private struct Line: Equatable {
    let text: String
    static func == (lhs: Self, rhs: Self) -> Bool { FolioDocumentMerge.sameBytes(lhs.text, rhs.text) }
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
  private struct Content {
    let metadata: String
    let body: String
    let lines: [Line]
    let stableID: String?
  }
  private struct Hunk { let range: Range<Int>; let replacement: [Line] }
  private struct Change { let side: Choice; let hunk: Hunk }
  private static let maximumSourceBytes = 256 * 1024
  private static let maximumLines = 4096

  /// Nil means the safe merge contract cannot establish a result; keep the existing manual route.
  static func plan(base: String, edited: String, received: String) -> Plan? {
    guard let base = content(base), let edited = content(edited), let received = content(received),
      base.stableID == edited.stableID, base.stableID == received.stableID else { return nil }
    let metadata: String
    if sameBytes(edited.metadata, base.metadata) { metadata = received.metadata }
    else if sameBytes(received.metadata, base.metadata) || sameBytes(edited.metadata, received.metadata) {
      metadata = edited.metadata
    } else { return nil }

    if sameBytes(edited.body, received.body) { return complete(metadata: metadata, body: edited.body) }
    if sameBytes(edited.body, base.body) { return complete(metadata: metadata, body: received.body) }
    if sameBytes(received.body, base.body) { return complete(metadata: metadata, body: edited.body) }
    if let body = independentParagraphAppends(base: base, edited: edited, received: received) {
      return complete(metadata: metadata, body: body)
    }

    guard let editedHunks = hunks(from: base.lines, to: edited.lines),
      let receivedHunks = hunks(from: base.lines, to: received.lines) else { return nil }
    let changes = (editedHunks.map { Change(side: .edited, hunk: $0) }
      + receivedHunks.map { Change(side: .received, hunk: $0) }).sorted {
      if $0.hunk.range.lowerBound != $1.hunk.range.lowerBound { return $0.hunk.range.lowerBound < $1.hunk.range.lowerBound }
      // An insertion at a shared boundary must connect both neighboring changes.
      return $0.hunk.range.upperBound < $1.hunk.range.upperBound
    }
    var groups: [[Change]] = []
    for change in changes {
      if let last = groups.last, last.contains(where: { connected($0.hunk.range, change.hunk.range) }) {
        groups[groups.count - 1].append(change)
      } else { groups.append([change]) }
    }
    var cursor = 0
    var segments: [Segment] = []
    var conflicts: [Conflict] = []
    for group in groups {
      guard let lower = group.map(\.hunk.range.lowerBound).min(),
        let upper = group.map(\.hunk.range.upperBound).max(), cursor <= lower else { return nil }
      segments.append(.text(text(base.lines[cursor..<lower])))
      let range = lower..<upper
      let local = group.filter { $0.side == .edited }.map(\.hunk)
      let remote = group.filter { $0.side == .received }.map(\.hunk)
      guard let editedText = applying(local, to: base.lines, in: range),
        let receivedText = applying(remote, to: base.lines, in: range) else { return nil }
      if local.isEmpty { segments.append(.text(receivedText)) }
      else if remote.isEmpty || sameBytes(editedText, receivedText) { segments.append(.text(editedText)) }
      else {
        let index = conflicts.count
        conflicts.append(Conflict(id: index, base: text(base.lines[range]), edited: editedText, received: receivedText))
        segments.append(.conflict(index))
      }
      cursor = upper
    }
    segments.append(.text(text(base.lines[cursor...])))
    let result = Plan(conflicts: conflicts, metadata: metadata, segments: segments)
    // Every possible choice must stay within the source-write limit.
    let largestChoices = Dictionary(uniqueKeysWithValues: conflicts.map {
      ($0.id, $0.edited.utf8.count >= $0.received.utf8.count ? Choice.edited : .received)
    })
    return result.resolvedSource(choices: largestChoices) == nil ? nil : result
  }

  private static func content(_ source: String) -> Content? {
    guard source.utf8.count <= maximumSourceBytes, !source.contains("\0"),
      lines(source).count <= maximumLines else { return nil }
    let presented = FolioEditorContent(source: source)
    let first = source.components(separatedBy: "\n").first?.trimmingCharacters(in: CharacterSet(charactersIn: "\r\u{feff}"))
    guard first != "---" || !presented.metadata.isEmpty else { return nil }
    let bodyLines = lines(presented.body)
    guard bodyLines.count <= maximumLines,
      let parsed = try? WikiMarkdownParser.document(relativePath: "notes/merge.md",
        bytes: Data((presented.metadata + "\n# Metadata\n").utf8)) else { return nil }
    return Content(metadata: presented.metadata, body: presented.body, lines: bodyLines, stableID: parsed.stableID)
  }

  private static func lines(_ source: String) -> [Line] {
    guard !source.isEmpty else { return [] }
    let parts = source.components(separatedBy: "\n")
    return parts.enumerated().compactMap { index, part in
      if index == parts.count - 1 { return part.isEmpty ? nil : Line(text: part) }
      return Line(text: part + "\n")
    }
  }

  private static func sameBytes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
  private static func text(_ lines: some Sequence<Line>) -> String { lines.map(\.text).joined() }
  private static func complete(metadata: String, body: String) -> Plan? {
    let result = Plan(conflicts: [], metadata: metadata, segments: [.text(body)])
    return result.automaticallyMergedSource == nil ? nil : result
  }

  private static func independentParagraphAppends(base: Content, edited: Content, received: Content) -> String? {
    let baseBytes = Array(base.body.utf8)
    guard !baseBytes.isEmpty, baseBytes.last == 10,
      edited.body.utf8.starts(with: baseBytes), received.body.utf8.starts(with: baseBytes),
      Array(Document(parsing: base.body).children).last is Paragraph else { return nil }
    let local = String(decoding: edited.body.utf8.dropFirst(baseBytes.count), as: UTF8.self)
    let remote = String(decoding: received.body.utf8.dropFirst(baseBytes.count), as: UTF8.self)
    func appendedParagraphs(_ suffix: String) -> [Paragraph]? {
      guard suffix.utf8.last == 10,
        base.lines.last?.isBlank == true || lines(suffix).first?.isBlank == true else { return nil }
      let blocks = Array(Document(parsing: suffix).children)
      let paragraphs = blocks.compactMap { $0 as? Paragraph }
      return !paragraphs.isEmpty && paragraphs.count == blocks.count ? paragraphs : nil
    }
    let localText = local.trimmingCharacters(in: .whitespacesAndNewlines)
    let remoteText = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let localParagraphs = appendedParagraphs(local), let remoteParagraphs = appendedParagraphs(remote),
      !localText.isEmpty, !remoteText.isEmpty,
      !localParagraphs.contains(where: { local in remoteParagraphs.contains { $0.plainText == local.plainText } }),
      !localText.utf8.starts(with: remoteText.utf8), !remoteText.utf8.starts(with: localText.utf8) else { return nil }
    return received.body + local
  }

  private static func hunks(from base: [Line], to result: [Line]) -> [Hunk]? {
    let difference = result.difference(from: base)
    let removals = Set(difference.removals.compactMap { change -> Int? in
      if case .remove(let offset, _, _) = change { return offset }; return nil
    })
    let insertions = Set(difference.insertions.compactMap { change -> Int? in
      if case .insert(let offset, _, _) = change { return offset }; return nil
    })
    var baseIndex = 0; var resultIndex = 0
    var start: Int?; var replacement: [Line] = []; var output: [Hunk] = []
    func flush() {
      if let start { output.append(Hunk(range: start..<baseIndex, replacement: replacement)) }
      start = nil; replacement = []
    }
    while baseIndex < base.count || resultIndex < result.count {
      if baseIndex < base.count, removals.contains(baseIndex) {
        if start == nil { start = baseIndex }; baseIndex += 1
      } else if resultIndex < result.count, insertions.contains(resultIndex) {
        if start == nil { start = baseIndex }; replacement.append(result[resultIndex]); resultIndex += 1
      } else {
        guard baseIndex < base.count, resultIndex < result.count, base[baseIndex] == result[resultIndex] else { return nil }
        flush(); baseIndex += 1; resultIndex += 1
      }
    }
    flush()
    return output.flatMap { hunk -> [Hunk] in
      // Equal-length replacements have an exact line mapping. Keep an adjacent,
      // independent edit outside the smallest line that needs a content choice.
      guard hunk.range.count > 1, hunk.range.count == hunk.replacement.count else { return [hunk] }
      return hunk.replacement.enumerated().map { offset, line in
        let index = hunk.range.lowerBound + offset
        return Hunk(range: index..<(index + 1), replacement: [line])
      }
    }
  }

  private static func connected(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
    if lhs.isEmpty { return rhs.lowerBound <= lhs.lowerBound && lhs.lowerBound <= rhs.upperBound }
    if rhs.isEmpty { return lhs.lowerBound <= rhs.lowerBound && rhs.lowerBound <= lhs.upperBound }
    return lhs.overlaps(rhs)
  }

  private static func applying(_ hunks: [Hunk], to base: [Line], in range: Range<Int>) -> String? {
    var cursor = range.lowerBound; var output = ""
    for hunk in hunks.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
      guard cursor <= hunk.range.lowerBound, hunk.range.upperBound <= range.upperBound else { return nil }
      output += text(base[cursor..<hunk.range.lowerBound]) + text(hunk.replacement)
      cursor = hunk.range.upperBound
    }
    return output + text(base[cursor..<range.upperBound])
  }
}
