import Foundation
import FolioKnowledge
import Markdown

/// A display projection of one search reference. It never borrows text from a newer source.
struct FolioSearchExcerpt {
  let text: String

  init(hit: WikiSearchHit, query: String, snapshot: WikiSnapshot?) {
    let terms = Self.terms(in: query)
    if !terms.isEmpty, let section = Self.verifiedSection(for: hit, in: snapshot),
      let paragraph = Self.matchingParagraph(in: Document(parsing: section.sourceText), terms: terms) {
      text = paragraph
    } else {
      let snippet = hit.folioSnippet
      text = (try? AttributedString(markdown: snippet,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        .map { String($0.characters) } ?? snippet
    }
  }

  func emphasizing(_ query: String) -> AttributedString {
    var result = AttributedString(text)
    for term in Self.terms(in: query) {
      var remaining = text.startIndex..<text.endIndex
      while let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
        range: remaining, locale: Self.searchLocale) {
        if let lower = AttributedString.Index(match.lowerBound, within: result),
          let upper = AttributedString.Index(match.upperBound, within: result) {
          result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        remaining = match.upperBound..<text.endIndex
      }
    }
    return result
  }

  private static let searchLocale = Locale(identifier: "en_US_POSIX")

  private static func terms(in query: String) -> [String] {
    Array(Set(query.precomposedStringWithCanonicalMapping
      .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }))
      .sorted()
  }

  private static func verifiedSection(for hit: WikiSearchHit, in snapshot: WikiSnapshot?) -> WikiSection? {
    let reference = hit.reference
    guard let snapshot, snapshot.workspace.id == reference.workspaceID,
      let document = snapshot.documents.first(where: { $0.id == reference.documentID }),
      document.revision == reference.sourceRevision, document.relativePath == reference.relativePath,
      let section = document.sections.first(where: { $0.id == reference.sectionID }),
      section.documentID == reference.documentID, section.range == reference.range,
      section.contentHash == reference.excerptSHA256,
      SourceDigest.sha256(section.sourceText) == reference.excerptSHA256
    else { return nil }
    return section
  }

  private static func matchingParagraph(in markup: any Markup, terms: [String]) -> String? {
    if let paragraph = markup as? Paragraph {
      let text = paragraph.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
      if terms.contains(where: {
        text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], locale: searchLocale) != nil
      }) { return text }
    }
    for child in markup.children {
      if let paragraph = matchingParagraph(in: child, terms: terms) { return paragraph }
    }
    return nil
  }
}

extension WikiSearchHit {
  var folioBreadcrumb: [String] { breadcrumb.first == title ? Array(breadcrumb.dropFirst()) : breadcrumb }
  func folioExcerpt(query: String, snapshot: WikiSnapshot?) -> FolioSearchExcerpt {
    FolioSearchExcerpt(hit: self, query: query, snapshot: snapshot)
  }
  var folioSnippet: String {
    let lines = snippet.components(separatedBy: "\n").drop(while: { first in
      let line = first.trimmingCharacters(in: .whitespacesAndNewlines)
      let heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
      return line.isEmpty || (line.hasPrefix("#") && (heading == title || breadcrumb.contains(heading)))
    })
    let excerpt = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return excerpt == title || breadcrumb.contains(excerpt) ? "" : excerpt
  }
}
