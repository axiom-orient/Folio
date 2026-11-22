import Markdown
import SwiftUI

/// A table stays a comparison when its columns fit, and becomes labelled rows on narrow readers.
struct WikiMarkdownTable: View {
  let table: Markdown.Table
  @ScaledMetric(relativeTo: .body) private var minimumColumnWidth = 160.0
  @State private var availableWidth = 0.0

  private let columnSpacing = 16.0
  private let cellPadding = 12.0
  private var headers: [any Markup] { Array(table.head.children) }
  private var rows: [[any Markup]] { table.body.rows.map { Array($0.children) } }
  private var columnCount: Int { table.maxColumnCount }

  private var canReflow: Bool {
    columnCount <= 3 && ([headers] + rows).joined().allSatisfy { node in
      guard let cell = node as? Markdown.Table.Cell else { return false }
      return cell.colspan == 1 && cell.rowspan == 1
    }
  }

  private var columnsFit: Bool {
    availableWidth >= minimumColumnWidth * Double(columnCount)
      + columnSpacing * Double(max(0, columnCount - 1)) + cellPadding * 2
  }

  var body: some View {
    Group {
      if !canReflow {
        scrollingTable
      } else if columnCount < 2 || rows.isEmpty || columnsFit {
        fittedTable
      } else {
        labelledRows
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .lineLimit(nil)
    .textSelection(.enabled)
    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { availableWidth = $0 }
  }

  private var fittedTable: some View {
    VStack(alignment: .leading, spacing: 0) {
      fittedRow(headers, isHeader: true)
        .background(.quaternary)
      ForEach(rows.indices, id: \.self) { row in
        Divider()
        fittedRow(rows[row], isHeader: false)
      }
    }
    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
  }

  private func fittedRow(_ cells: [any Markup], isHeader: Bool) -> some View {
    WikiMarkdownTableRowLayout(columnCount: columnCount, spacing: columnSpacing) {
      ForEach(cells.indices, id: \.self) { column in
        cellText(cells[column])
          .fontWeight(isHeader ? .semibold : .regular)
          .multilineTextAlignment(textAlignment(column))
          .frame(maxWidth: .infinity, alignment: alignment(column))
          .accessibilityAddTraits(isHeader ? [.isHeader] : [])
      }
    }
    .padding(cellPadding)
    .accessibilityElement(children: .contain)
  }

  private var labelledRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(rows.indices, id: \.self) { row in
        if row > 0 { Divider() }
        VStack(alignment: .leading, spacing: 12) {
          ForEach(rows[row].indices, id: \.self) { column in
            VStack(alignment: .leading, spacing: 4) {
              if headers.indices.contains(column) {
                cellText(headers[column]).font(.callout).foregroundStyle(.secondary)
              }
              cellText(rows[row][column]).fontWeight(column == 0 ? .semibold : .regular)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
          }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
      }
    }
  }

  /// Keep genuinely wide tables in their authored row/column order.
  private var scrollingTable: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .topLeading, horizontalSpacing: columnSpacing, verticalSpacing: 12) {
        GridRow {
          ForEach(headers.indices, id: \.self) { column in
            cellText(headers[column]).bold().accessibilityAddTraits(.isHeader)
          }
        }
        Divider()
        ForEach(rows.indices, id: \.self) { row in
          GridRow {
            ForEach(rows[row].indices, id: \.self) { column in
              cellText(rows[row][column])
            }
          }
        }
      }.padding(cellPadding)
    }.background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
  }

  private func cellText(_ node: any Markup) -> SwiftUI.Text {
    WikiMarkdownReader.inlineText(source: WikiMarkdownReader.inlineSource(node))
  }

  private func textAlignment(_ column: Int) -> TextAlignment {
    switch table.columnAlignments.indices.contains(column) ? table.columnAlignments[column] : nil {
    case .center: .center
    case .right: .trailing
    default: .leading
    }
  }

  private func alignment(_ column: Int) -> Alignment {
    switch textAlignment(column) {
    case .center: .top
    case .trailing: .topTrailing
    default: .topLeading
    }
  }
}

/// Propose a bounded width to every cell, then let the tallest wrapped cell set the row height.
private struct WikiMarkdownTableRowLayout: Layout {
  let columnCount: Int
  let spacing: Double

  private var totalSpacing: Double { spacing * Double(max(0, columnCount - 1)) }

  private func columnWidth(in width: CGFloat) -> CGFloat {
    max(0, width - totalSpacing) / Double(max(1, columnCount))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let naturalWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    let width = proposal.width ?? naturalWidth * Double(columnCount) + totalSpacing
    let cellWidth = columnWidth(in: width)
    let height = subviews.map { $0.sizeThatFits(.init(width: cellWidth, height: nil)).height }.max() ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let cellWidth = columnWidth(in: bounds.width)
    for (column, cell) in subviews.enumerated() {
      cell.place(at: CGPoint(x: bounds.minX + Double(column) * (cellWidth + spacing), y: bounds.minY),
        anchor: .topLeading, proposal: .init(width: cellWidth, height: nil))
    }
  }
}
