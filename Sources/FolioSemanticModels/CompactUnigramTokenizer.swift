import Foundation
import FolioKnowledge

/// A storage optimization for the two pinned XLM-R pipelines, not a general
/// tokenizer. Scalar trie, Float32 Viterbi, unknown fusion and normalization
/// follow swift-transformers 1.4.0. No vocabulary Strings/dictionaries are
/// materialized at runtime. The immutable table can be reclaimed as clean pages.
/// Adapted from Hugging Face / Pedro Cuenca (2024), Apache-2.0; see bundled
/// LICENSE-SwiftTransformers.txt and TOKENIZER_SOURCE.json.
package struct CompactUnigramTokenizer: Sendable {
  package enum Pipeline: Sendable { case embedding, relevance }
  private let table: Data
  private let edgeStart: Int
  private let unknownScore: Float
  private let normalizer: CompactCharsmap
  private let pipeline: Pipeline
  private let specialPattern: NSRegularExpression
  private let whitespace = try! NSRegularExpression(pattern: #"\S+"#)
  private let spaces = try! NSRegularExpression(pattern: " {2,}")

  package init(root: URL, pipeline: Pipeline) throws {
    let table = try Data(contentsOf: root.appendingPathComponent("Unigram.foliotokens"), options: .mappedIfSafe)
    guard table.count >= 32, table.prefix(8) == Data("FOLIOTK1".utf8) else { throw Self.invalid() }
    let nodes = Int(Self.u32(table, 8)); let edges = Int(Self.u32(table, 12))
    guard nodes > 0, nodes <= 2_000_000, edges == nodes - 1,
      Self.u32(table, 16) == 250002, Self.u32(table, 20) == 3,
      table.count == 32 + nodes * 16 + edges * 8 else { throw Self.invalid() }
    let edgeStart = 32 + nodes * 16
    // Validate once before any scoped reads. The format is a forward tree;
    // child labels are strictly increasing so binary search has one result.
    for node in 0..<nodes {
      let at = 32 + node * 16
      let first = Int(Self.u32(table, at)); let count = Int(Self.u32(table, at + 4))
      let leaf = Self.u32(table, at + 8); let score = Float(bitPattern: Self.u32(table, at + 12))
      guard first <= edges, count <= edges - first, leaf == .max || leaf < 250002, score.isFinite else { throw Self.invalid() }
      var previous: UInt32?
      for e in first..<(first + count) {
        let label = Self.u32(table, edgeStart + e * 8); let child = Int(Self.u32(table, edgeStart + e * 8 + 4))
        guard Unicode.Scalar(label) != nil, previous.map({ $0 < label }) ?? true, child > node, child < nodes else { throw Self.invalid() }
        previous = label
      }
    }
    let unknown = Float(bitPattern: Self.u32(table, 24))
    guard unknown.isFinite, unknown < 0 else { throw Self.invalid() }
    self.table = table; self.edgeStart = edgeStart; unknownScore = unknown
    normalizer = try CompactCharsmap(Data(contentsOf: root.appendingPathComponent("Precompiled.charsmap")))
    self.pipeline = pipeline
    specialPattern = try NSRegularExpression(pattern: pipeline == .relevance
      ? #"(?:<pad>)|(?:</s>)|(?:<unk>)|\s*(<mask>)|(?:<s>)"#
      : #"(?:<pad>)|(?:</s>)|(?:<unk>)|(?:<mask>)|(?:<s>)"#)
  }

  func encode(text: String, addSpecialTokens: Bool = true) -> [Int] {
    let nsText = text as NSString
    var ids: [Int] = []; var start = 0
    for match in specialPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
      if match.range.location > start { ids += ordinary(nsText.substring(with: NSRange(location: start, length: match.range.location - start))) }
      let range = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
      switch nsText.substring(with: range) {
      case "<s>": ids.append(0)
      case "<pad>": ids.append(1)
      case "</s>": ids.append(2)
      case "<unk>": ids.append(3)
      case "<mask>": ids.append(250001)
      default: preconditionFailure("Static special-token pattern disagrees with its IDs")
      }
      start = NSMaxRange(match.range)
    }
    if start < nsText.length { ids += ordinary(nsText.substring(from: start)) }
    return addSpecialTokens ? [0] + ids + [2] : ids
  }

  private func ordinary(_ input: String) -> [Int] {
    var text = normalizer.normalize(input)
    if pipeline == .embedding {
      text = spaces.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }
    let parts: [String]
    if pipeline == .relevance {
      let ns = text as NSString
      parts = whitespace.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    } else { parts = [text] }
    return parts.flatMap { part -> [Int] in
      guard !part.isEmpty else { return [] }
      let replaced = part.replacingOccurrences(of: " ", with: "▁", options: .literal)
      let prefixed = replaced.unicodeScalars.first?.value == 0x2581 ? replaced : "▁" + replaced
      // Metaspace split uses MergedWithNext, including adjacent separators.
      // Match literal scalar boundaries even when a following combining mark
      // joins the metaspace into one Swift grapheme cluster.
      return prefixed.unicodeScalars.split(omittingEmptySubsequences: false, whereSeparator: { $0.value == 0x2581 })
        .dropFirst().flatMap { segment("▁" + String(String.UnicodeScalarView($0))) }
    }
  }

  private struct Node { let id: Int; let previous: Int; let score: Float }
  private func segment(_ text: String) -> [Int] {
    let scalars = text.unicodeScalars.map(\.value)
    var nodes = [Node(id: 0, previous: -1, score: 0)]
    var endings = [[Int]](repeating: [], count: scalars.count + 1); endings[0] = [0]
    func insert(_ id: Int, _ score: Float, _ begin: Int, _ end: Int) {
      var previous = -1; var best: Float = 0
      // Preserve upstream Float32 addition and first-wins ties, including cases
      // where rounding makes distinct predecessor scores equal after addition.
      for candidate in endings[begin] {
        let sum = nodes[candidate].score + score
        if previous == -1 || sum > best { best = sum; previous = candidate }
      }
      nodes.append(Node(id: id, previous: previous, score: best)); endings[end].append(nodes.count - 1)
    }
    table.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      func read(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
      for begin in scalars.indices {
        var node = 0; var single = false
        for end in begin..<scalars.count {
          let at = 32 + node * 16
          let first = Int(read(at)); let count = Int(read(at + 4))
          var low = first; var high = first + count
          while low < high {
            let mid = low + (high - low) / 2
            if read(edgeStart + mid * 8) < scalars[end] { low = mid + 1 } else { high = mid }
          }
          guard low < first + count, read(edgeStart + low * 8) == scalars[end] else { break }
          node = Int(read(edgeStart + low * 8 + 4))
          let leaf = read(32 + node * 16 + 8)
          if leaf != .max {
            insert(Int(leaf), Float(bitPattern: read(32 + node * 16 + 12)), begin, end + 1)
            if end == begin { single = true }
          }
        }
        if !single { insert(3, unknownScore, begin, begin + 1) }
      }
    }
    var last = -1; var best: Float = 0
    for candidate in endings[scalars.count] where last == -1 || nodes[candidate].score > best { last = candidate; best = nodes[candidate].score }
    var reversed: [Int] = []
    while last > 0 { reversed.append(nodes[last].id); last = nodes[last].previous }
    var result: [Int] = []
    for id in reversed.reversed() where id != 3 || result.last != 3 { result.append(id) }
    return result
  }

  private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
    data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
  }
  private static func invalid() -> WikiError { .invalidSource("Invalid compiled tokenizer table.") }
}

private struct CompactCharsmap: Sendable {
    private let trie: [UInt32]
    private let replacements: [UInt8]

    /// Layout: `[u32 LE trie size in bytes][trie: u32 LE units][replacements]`.
    ///
    /// - Throws: `TokenizerError.malformedPrecompiledCharsmap` when the data is truncated,
    ///   the trie is empty, or the replacements are not valid UTF-8, as `Precompiled::from` fails.
    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else {
            throw WikiError.invalidSource("missing trie size")
        }
        func u32(at offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        guard u32(at: 0).isMultiple(of: 4) else { throw WikiError.invalidSource("unaligned trie size") }
        let unitCount = Int(u32(at: 0)) / 4
        let blobStart = 4 + unitCount * 4
        guard unitCount > 0 else {
            throw WikiError.invalidSource("empty trie")
        }
        guard blobStart <= bytes.count else {
            throw WikiError.invalidSource("trie extends past the end of the data")
        }
        guard String(bytes: bytes[blobStart...], encoding: .utf8) != nil else {
            throw WikiError.invalidSource("replacements are not valid UTF-8")
        }
        trie = (0..<unitCount).map { u32(at: 4 + $0 * 4) }
        replacements = Array(bytes[blobStart...])
    }

    /// The replacement for the *shortest* prefix of `key` found in the trie, as
    /// `Precompiled::transform` returns the first `common_prefix_search` result.
    func transform(_ key: some Sequence<UInt8>) -> String? {
        func hasLeaf(_ unit: UInt32) -> Bool { (unit >> 8) & 1 == 1 }
        func value(_ unit: UInt32) -> Int { Int(unit & ((1 << 31) - 1)) }
        func label(_ unit: UInt32) -> UInt32 { unit & ((1 << 31) | 0xFF) }
        func offset(_ unit: UInt32) -> Int { Int((unit >> 10) << ((unit & (1 << 9)) >> 6)) }

        var position = offset(trie[0])
        for byte in key {
            if byte == 0 { break }
            position ^= Int(byte)
            guard position < trie.count, label(trie[position]) == UInt32(byte) else { return nil }
            let unit = trie[position]
            position ^= offset(unit)
            if hasLeaf(unit) {
                guard position < trie.count else { return nil }
                let start = value(trie[position])
                guard start <= replacements.count else { return nil }
                let end = replacements[start...].firstIndex(of: 0) ?? replacements.count
                return String(decoding: replacements[start..<end], as: UTF8.self)
            }
        }
        return nil
    }
    func normalize(_ text: String) -> String {
        var output = ""
        for grapheme in text {
            if grapheme.utf8.count < 6, let replacement = transform(grapheme.utf8) {
                output += replacement
                continue
            }
            for scalar in grapheme.unicodeScalars {
                if let replacement = transform(scalar.utf8) {
                    output += replacement
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }

}
