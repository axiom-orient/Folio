import Markdown
import SwiftUI

/// Render GFM structure. HTML remains selectable source; relative links go through the workspace owner.
struct WikiMarkdownReader: View, Equatable {
  let source: String
  let titleToOmit: String?
  init(source: String, titleToOmit: String? = nil) { self.source = source; self.titleToOmit = titleToOmit }
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.source.utf8.elementsEqual(rhs.source.utf8)
      && lhs.titleToOmit.map { Array($0.utf8) } == rhs.titleToOmit.map { Array($0.utf8) }
  }
  var body: some View {
    let nodes = Array(Document(parsing: source).children)
    let omitFirst = (nodes.first as? Heading).map { $0.plainText == titleToOmit } ?? false
    WikiMarkdownBlocks(nodes: omitFirst ? Array(nodes.dropFirst()) : nodes)
  }

  /// Formatting a break on its own loses the formatter's queued newline.
  static func inlineSource(_ node: any Markup, preservesSoftBreaks: Bool = false) -> String {
    node.children.map { child in
      if child is SoftBreak { return preservesSoftBreaks ? "\n" : " " }
      if child is LineBreak { return "\n" }
      return child.detachedFromParent.format()
    }.joined()
  }

  static func inlineText(source: String) -> SwiftUI.Text {
    if !source.contains(where: { "\\`*_[]!<>&~:".contains($0) }) { return SwiftUI.Text(verbatim: source) }
    return SwiftUI.Text((try? AttributedString(markdown: source, options:
      .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source))
  }
}
private struct WikiMarkdownBlocks: View {
  let nodes: [any Markup]
  var preservesSoftBreaks = false
  @ScaledMetric(relativeTo: .title2) private var headingSize = 22.0
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      ForEach(nodes.indices, id: \.self) { index in block(nodes[index]) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func inline(_ node: any Markup) -> SwiftUI.Text {
    WikiMarkdownReader.inlineText(source: node.format())
  }
  private func inlineChildren(_ node: any Markup) -> SwiftUI.Text {
    WikiMarkdownReader.inlineText(source: WikiMarkdownReader.inlineSource(node, preservesSoftBreaks: preservesSoftBreaks))
  }
  @ViewBuilder private func block(_ node: any Markup) -> some View {
    if let heading = node as? Heading {
      inlineChildren(heading)
        .font(.system(size: heading.level == 1 ? headingSize * 1.18 : heading.level == 2 ? headingSize : headingSize * 0.86))
        .fontWeight(.semibold).textSelection(.enabled).accessibilityAddTraits(.isHeader)
    } else if let code = node as? CodeBlock {
      ScrollView(.horizontal) {
        SwiftUI.Text(code.code).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(12)
      }.background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    } else if let table = node as? Markdown.Table {
      WikiMarkdownTable(table: table)
    } else if node is UnorderedList || node is OrderedList {
      let children = Array(node.children)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(children.indices, id: \.self) { i in
          HStack(alignment: .top, spacing: 8) {
            let checkbox = (children[i] as? ListItem)?.checkbox
            SwiftUI.Text(checkbox.map { $0 == .checked ? "☑" : "☐" }
              ?? (node as? OrderedList).map { "\($0.startIndex + UInt(i))." } ?? "•")
            WikiMarkdownBlocks(nodes: Array(children[i].children), preservesSoftBreaks: preservesSoftBreaks)
          }
        }
      }.padding(.leading, 8)
    } else if node is BlockQuote {
      HStack(alignment: .top) {
        Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
        WikiMarkdownBlocks(nodes: Array(node.children), preservesSoftBreaks: true)
      }.fixedSize(horizontal: false, vertical: true)
    } else if node is ThematicBreak { Divider() }
    else if node is Paragraph { inlineChildren(node).textSelection(.enabled) }
    else { inline(node).textSelection(.enabled) }
  }
}
