import Foundation

struct WikiSearchQuery {
  let normalized: String
  let expression: String

  init(_ query: String, allowEmpty: Bool, legacyTermLimit: Bool = false) throws {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (allowEmpty || !trimmed.isEmpty), query.utf8.count <= 512, !query.contains("\0") else {
      throw WikiError.invalidSource("Expected a search query of at most 512 UTF-8 bytes.")
    }
    normalized = Self.normalize(trimmed)
    let allTerms = Array(Set(normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty })).sorted()
    let terms = legacyTermLimit ? Array(allTerms.prefix(32)) : allTerms
    // MATCH grammar is generated only from literal, quoted human query terms.
    expression = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " OR ")
  }

  static func normalize(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
  }
}

struct WikiSearchRanking {
  let snapshot: WikiSnapshot
  let sections: [String: (WikiDocument, WikiSection)]
  let ids: [String]
  let provenance: [String: Set<WikiSearchSource>]

  init(snapshot: WikiSnapshot, query: WikiSearchQuery, filter: WikiDocumentFilter,
    fts: [String], semantic: [String] = [], candidateSource: WikiSearchSource = .semantic,
    compactCandidates: Bool = true
  ) {
    self.snapshot = snapshot
    let documents = snapshot.documents.filter(filter.matches)
    let sections = Dictionary(uniqueKeysWithValues: documents.flatMap { document in document.sections.map { ($0.id, (document, $0)) } })
    self.sections = sections
    func ordered(_ left: String, _ right: String) -> Bool {
      guard let lhs = sections[left], let rhs = sections[right] else { return left < right }
      return (lhs.0.relativePath, lhs.1.ordinal, left) < (rhs.0.relativePath, rhs.1.ordinal, right)
    }
    if query.normalized.isEmpty {
      ids = sections.keys.sorted(by: ordered); provenance = [:]; return
    }
    let exactDocuments = Set(documents.filter { document in
      ([document.id, document.title, document.relativePath] + document.aliases).contains { WikiSearchQuery.normalize($0) == query.normalized }
    }.map(\.id))
    let exact = sections.keys.filter { exactDocuments.contains(sections[$0]!.0.id) }.sorted(by: ordered)
    var scores: [String: Double] = [:]; var provenance: [String: Set<WikiSearchSource>] = [:]
    for (arm, candidates) in [(WikiSearchSource.exact, exact), (.fts, fts), (candidateSource, semantic)] {
      let ids = compactCandidates ? candidates.filter { sections[$0] != nil } : candidates
      var seen = Set<String>()
      for (rank, id) in ids.enumerated() where sections[id] != nil && seen.insert(id).inserted {
        scores[id, default: 0] += 1.0 / Double(60 + rank + 1)
        provenance[id, default: []].insert(arm)
      }
    }
    ids = scores.keys.sorted { left, right in
      let leftExact = provenance[left]?.contains(.exact) == true; let rightExact = provenance[right]?.contains(.exact) == true
      if leftExact != rightExact { return leftExact }
      if scores[left] != scores[right] { return scores[left, default: 0] > scores[right, default: 0] }
      return ordered(left, right)
    }
    self.provenance = provenance
  }

  func hits(_ range: Range<Int>) -> [WikiSearchHit] {
    range.compactMap { rank in
      let id = ids[rank]
      guard let (document, section) = sections[id] else { return nil }
      return WikiSearchHit(title: document.title, breadcrumb: section.headingPath, snippet: String(section.sourceText.prefix(512)),
        reference: WikiEvidenceReference(workspaceID: snapshot.workspace.id, document: document, section: section),
        provenance: provenance[id] ?? [], fusedRank: rank + 1)
    }
  }
}
