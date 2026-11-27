import Foundation

/// Conservative grouping of located text. This layer preserves every emitted
/// string and rectangle. It does not assign cell roles or interpret mathematics.
enum WikiPDFLayout {
  private enum RepeatedShape { case cells, columns }

  /// Returns no groups when a page has no recognizable structure. Otherwise
  /// each nonblank, geometrically valid input appears once in the result.
  static func groups(_ regions: [WikiPDFTextRegion]) throws -> [[WikiPDFTextRegion]] {
    try Task.checkCancellation()
    let rows = try visualRows(regions)
    let shapes = rows.map(shape)
    var repeated = Array<RepeatedShape?>(repeating: nil, count: rows.count)
    for index in rows.indices.dropFirst() {
      try Task.checkCancellation()
      guard let shape = shapes[index], shape == shapes[index - 1],
        aligned(rows[index - 1], rows[index]) else { continue }
      repeated[index - 1] = shape
      repeated[index] = shape
    }
    guard repeated.contains(where: { $0 != nil }) || rows.contains(where: { $0.contains(where: isEquation) }) else {
      return []
    }

    var output: [[WikiPDFTextRegion]] = []
    var activeColumns: [Int] = []
    for index in rows.indices {
      try Task.checkCancellation()
      let row = rows[index]
      switch repeated[index] {
      case .cells:
        activeColumns = []
        output.append(row)
      case .columns:
        if index == 0 || repeated[index - 1] != .columns || !aligned(rows[index - 1], row) {
          activeColumns = []
        }
        for (column, line) in row.enumerated() {
          if activeColumns.indices.contains(column), canExtend(output[activeColumns[column]], with: line) {
            output[activeColumns[column]].append(line)
          } else {
            if activeColumns.indices.contains(column) { activeColumns[column] = output.count }
            else { activeColumns.append(output.count) }
            output.append([line])
          }
        }
      case nil:
        activeColumns = []
        output.append(contentsOf: row.map { [$0] })
      }
    }
    return output
  }

  private static func visualRows(_ regions: [WikiPDFTextRegion]) throws -> [[WikiPDFTextRegion]] {
    let located = regions.filter { $0.bounds.isNormalized && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let ordered = located.sorted {
      let a = middleY($0), b = middleY($1)
      return a == b ? precedesHorizontally($0, $1) : a > b
    }
    var rows: [[WikiPDFTextRegion]] = []
    for region in ordered {
      try Task.checkCancellation()
      // Keep the first center as the comparison point so short adjacent lines
      // cannot drift into a single row through a chain of slightly offset boxes.
      if let first = rows.last?.first,
        abs(middleY(first) - middleY(region)) <= min(first.bounds.height, region.bounds.height) * 0.4 {
        rows[rows.count - 1].append(region)
      } else { rows.append([region]) }
    }
    return rows.map { $0.sorted(by: precedesHorizontally) }
  }

  private static func shape(_ row: [WikiPDFTextRegion]) -> RepeatedShape? {
    guard (2...8).contains(row.count), !row.contains(where: isEquation) else { return nil }
    let gaps = zip(row, row.dropFirst()).map { left, right in right.bounds.x - (left.bounds.x + left.bounds.width) }
    if row.count == 2, row.allSatisfy({ $0.bounds.width >= 0.18 }), gaps[0] >= 0.035 {
      return .columns
    }
    // Two short fields need a tighter width limit than rows with three or more
    // fields. This avoids joining aligned lines from facing prose columns.
    let maximumFieldWidth = row.count == 2 ? 0.16 : 0.22
    if row.allSatisfy({ $0.bounds.width <= maximumFieldWidth }), gaps.allSatisfy({ $0 >= 0.015 }) {
      return .cells
    }
    return nil
  }

  private static func aligned(_ first: [WikiPDFTextRegion], _ second: [WikiPDFTextRegion]) -> Bool {
    guard first.count == second.count, let upper = first.first, let lower = second.first,
      abs(middleY(upper) - middleY(lower)) <= 0.14 else { return false }
    return zip(first, second).allSatisfy { a, b in abs(a.bounds.x - b.bounds.x) <= 0.028 }
  }

  private static func canExtend(_ column: [WikiPDFTextRegion], with line: WikiPDFTextRegion) -> Bool {
    guard column.count < 4, let previous = column.last else { return false }
    return abs(middleY(previous) - middleY(line)) <= max(previous.bounds.height, line.bounds.height) * 2.6
      && column.reduce(line.text.utf8.count) { $0 + $1.text.utf8.count + 1 } <= 1_200
  }

  private static func isEquation(_ region: WikiPDFTextRegion) -> Bool {
    let text = region.text
    guard (3...180).contains(text.utf8.count), region.bounds.width <= 0.62 else { return false }
    if text.contains(where: { "∫∑∏√≠≤≥≈∂∞".contains($0) }) { return true }
    let sides = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
    guard sides.count == 2, !sides[1].isEmpty, sides[0].count <= 28 else { return false }
    return sides[0].count == 1 || sides[0].contains { "+−-*/^(){}²³".contains($0) }
  }

  private static func middleY(_ region: WikiPDFTextRegion) -> Double {
    region.bounds.y + region.bounds.height / 2
  }

  private static func precedesHorizontally(_ first: WikiPDFTextRegion, _ second: WikiPDFTextRegion) -> Bool {
    let a = first.bounds, b = second.bounds
    if a.x != b.x { return a.x < b.x }
    if a.y != b.y { return a.y > b.y }
    if a.width != b.width { return a.width < b.width }
    if a.height != b.height { return a.height < b.height }
    return first.text.utf8.lexicographicallyPrecedes(second.text.utf8)
  }
}
