import FolioKnowledge
import FolioKnowledgeApple
import SwiftUI

struct WikiDocumentLabel: View {
  let document: WikiDocument
  let isDirty: Bool
  var isSelected = false
  var showsFolder = false
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    let preview = self.preview
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(document.title).font(.body.weight(.medium)).foregroundStyle(FolioTheme.text(scheme))
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        if isDirty {
          Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(FolioTheme.accent(scheme))
        }
      }
      if showsFolder {
        Text(folder.isEmpty ? "문서" : folder).font(.subheadline).foregroundStyle(supportingColor)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !preview.isEmpty {
        Text(preview).font(.subheadline).foregroundStyle(supportingColor).lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .lineLimit(nil)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(document.title)
    .accessibilityValue(([isDirty ? "저장하지 않은 편집" : "", showsFolder && folder.isEmpty ? "문서" : folder, preview])
      .filter { !$0.isEmpty }.joined(separator: ", "))
  }
  private var supportingColor: Color { isSelected ? FolioTheme.text(scheme) : FolioTheme.muted(scheme) }
  private var preview: String {
    if WikiAttachmentImport.unmodifiedPDFPath(in: document) != nil { return "PDF" }
    let line = document.sections.lazy.flatMap { $0.sourceText.components(separatedBy: "\n") }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("```") && !$0.hasPrefix("|")
        && !$0.hasPrefix("확인일:") && $0 != "---" } ?? ""
    let bounded = String(line.prefix(240))
    let text = FolioReadingExcerpt.plain(bounded)
    guard let sentenceEnd = text.range(of: #"[.!?。！？](?:\s|$)"#, options: .regularExpression) else { return text }
    return String(text[..<text.index(after: sentenceEnd.lowerBound)])
  }
  private var folder: String {
    let path = (document.relativePath as NSString).deletingLastPathComponent
    return path == "notes" ? "" : WikiFileAction.folderLabel(path)
  }
}

/// Reveal a folder only when titles alone cannot distinguish two list rows.
func folioDuplicateDocumentTitles(_ documents: [WikiDocument]) -> Set<String> {
  var seen = Set<String>()
  var duplicates = Set<String>()
  for document in documents where !seen.insert(document.title).inserted {
    duplicates.insert(document.title)
  }
  return duplicates
}

/// A bounded summary is secondary to the complete document, never its source.
enum FolioReadingExcerpt {
  static func plain(_ text: String) -> String {
    guard text.contains(where: { "\\`*_[]!<>&~:".contains($0) }) else { return text }
    return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      .map { String($0.characters) } ?? text
  }
  static func semantic(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let body = lines.drop(while: { $0.isEmpty || $0.hasPrefix("#") }).joined(separator: "\n")
    return plain(String(body.prefix(320)))
  }
}

struct WikiSearchHitLabel: View {
  let hit: WikiSearchHit
  let query: String
  let snapshot: WikiSnapshot?
  var isSelected = false
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    let excerpt = hit.folioExcerpt(query: query, snapshot: snapshot)
    VStack(alignment: .leading, spacing: 5) {
      Text(hit.title).font(.body.weight(.medium)).foregroundStyle(FolioTheme.text(scheme))
        .fixedSize(horizontal: false, vertical: true)
      if !hit.folioBreadcrumb.isEmpty {
        Text(hit.folioBreadcrumb.joined(separator: " › ")).font(.caption)
          .foregroundStyle(supportingColor).fixedSize(horizontal: false, vertical: true)
      }
      if !excerpt.text.isEmpty {
        Text(excerpt.emphasizing(query)).font(.subheadline).foregroundStyle(supportingColor)
          .lineLimit(3)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .lineLimit(nil)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(([hit.title] + hit.folioBreadcrumb).joined(separator: " › "))
      .accessibilityValue(excerpt.text)
  }
  private var supportingColor: Color { isSelected ? FolioTheme.text(scheme) : FolioTheme.muted(scheme) }
}
