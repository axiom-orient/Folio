import Foundation
import PDFKit
import FolioKnowledge

/// Coordinates in the unrotated PDF crop box, normalized to 0...1 with a
/// bottom-left origin. A PDF viewer can map them back through that crop box.
public struct WikiPDFBounds: Codable, Hashable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }

  /// Use when reading an untrusted derived record, not as proof of extraction
  /// fidelity. A text-layer region can still contain errors in the source PDF.
  public var isNormalized: Bool {
    [x, y, width, height].allSatisfy(\.isFinite)
      && x >= 0 && y >= 0 && width > 0 && height > 0
      && x <= 1 && y <= 1 && width <= 1 && height <= 1
      && x + width <= 1 + 1e-12 && y + height <= 1 + 1e-12
  }
}

public struct WikiPDFTextRegion: Codable, Hashable, Sendable {
  public let text: String
  public let bounds: WikiPDFBounds
  // Only extractor-confirmed ranges can anchor a highlight in a quotation.
  let byteRange: Range<Int>?

  public init(text: String, bounds: WikiPDFBounds) {
    self.init(text: text, bounds: bounds, byteRange: nil)
  }

  init(text: String, bounds: WikiPDFBounds, byteRange: Range<Int>?) {
    self.text = text; self.bounds = bounds; self.byteRange = byteRange
  }
}

public struct WikiPDFPage: Codable, Hashable, Sendable {
  public enum Extraction: String, Codable, Hashable, Sendable {
    /// PDFKit's original text layer, not a claim that the PDF contains true facts.
    case textLayer
    /// Machine-read text from a rendered page. Compare it with the original image.
    case ocrUnreviewed
    /// No usable text layer. This includes scanned images and empty pages.
    case unreadable
  }

  public let pageIndex: Int
  public let label: String
  public let text: String
  public let regions: [WikiPDFTextRegion]
  public let extraction: Extraction

  public init(pageIndex: Int, label: String, text: String,
    regions: [WikiPDFTextRegion], extraction: Extraction
  ) {
    self.pageIndex = pageIndex; self.label = label; self.text = text
    self.regions = regions; self.extraction = extraction
  }
}

struct WikiPDFKnowledgePage {
  struct Region {
    let page: WikiPDFPage
    let identity: WikiPDFEvidenceRegion
  }
  let native: WikiPDFPage
  let regions: [Region]
  let includesNative: Bool
  var recognitionFailed = false
  var imageScanIncomplete = false
}

/// Extracts only admitted bytes. It owns no file URL, workspace, writer or
/// network capability, and no PDFKit object escapes this synchronous operation.
public enum WikiPDFExtractor {
  public static let identifier = "apple-pdf-text.v2"

  /// Nil selects every page; an explicit set preserves original page indices and
  /// order. Missing text remains an explicit page result rather than a silently
  /// omitted page. Callers must report that incomplete extraction coverage.
  public static func extract(_ bytes: Data, pageIndices: Set<Int>? = nil) throws -> [WikiPDFPage] {
    var pages: [WikiPDFPage] = []
    try forEachPage(bytes, pageIndices: pageIndices) { pages.append($0) }
    return pages
  }

  /// The index consumes one page at a time, without retaining all line regions.
  static func forEachPage(_ bytes: Data, pageIndices: Set<Int>? = nil,
    _ consume: (WikiPDFPage) throws -> Void) throws {
    try visitPages(bytes, pageIndices: pageIndices) { _, native in try consume(native) }
  }

  /// A nil enhancement set enables OCR and layout for every selected page.
  /// Legacy citations request only the original PDFKit representation.
  static func forEachKnowledgePage(_ bytes: Data, pageIndices: Set<Int>? = nil,
    enhancedPages: Set<Int>? = nil, mixedImageIndices: [Int: Set<Int>]? = nil,
    _ consume: (WikiPDFKnowledgePage) throws -> Void) throws {
    try visitPages(bytes, pageIndices: pageIndices) { page, native in
      guard let page, enhancedPages?.contains(native.pageIndex) ?? true else {
        try consume(.init(native: native, regions: [], includesNative: true))
        return
      }
      let canGroup = page.rotation.isMultiple(of: 360)
      if native.extraction == .textLayer {
        let positions = try positionedText(on: page, native: native)
        let groups = canGroup ? try WikiPDFLayout.groups(positions.runs) : []
        let hasAllText = groups.isEmpty ? false : positions.runs.map(\.text).joined().filter { !$0.isWhitespace }.utf8
          .elementsEqual(native.text.filter { !$0.isWhitespace }.utf8)
        var result = WikiPDFKnowledgePage(native: native,
          regions: makeRegions(groups, native: native, kind: .layout), includesNative: !hasAllText)
        if mixedImageIndices == nil || mixedImageIndices?[native.pageIndex]?.isEmpty == false {
          let images = try recognizeImages(on: page, native: native, existing: positions.runs + positions.tokens,
            selected: mixedImageIndices?[native.pageIndex], canGroup: canGroup)
          result = .init(native: native, regions: result.regions + images.regions,
            includesNative: !hasAllText, recognitionFailed: images.failed, imageScanIncomplete: images.incomplete)
        }
        try consume(result)
      } else {
        let observations: [WikiPDFTextRegion]
        do { observations = try WikiPDFOCR.recognize(page) }
        catch is CancellationError { throw CancellationError() }
        catch {
          try Task.checkCancellation()
          try consume(.init(native: native, regions: [], includesNative: false, recognitionFailed: true))
          return
        }
        let regions = try recognizedRegions(observations, native: native, canGroup: canGroup, imageIndex: nil)
        try consume(.init(native: native, regions: regions, includesNative: false))
      }
    }
  }

  private static func recognizeImages(on page: PDFPage, native: WikiPDFPage, existing: [WikiPDFTextRegion],
    selected: Set<Int>?, canGroup: Bool) throws -> (regions: [WikiPDFKnowledgePage.Region], failed: Bool, incomplete: Bool) {
    let scan = try WikiPDFImageRegions.regions(in: page)
    var result: [WikiPDFKnowledgePage.Region] = []
    var failed = false
    for (index, rectangle) in scan.regions.enumerated() where selected?.contains(index) ?? true {
      try Task.checkCancellation()
      do {
        result += try autoreleasepool {
          let observations = try WikiPDFOCR.recognize(page, in: rectangle, excluding: existing)
          return try recognizedRegions(observations, native: native, canGroup: canGroup, imageIndex: index)
        }
      } catch is CancellationError { throw CancellationError() }
      catch { failed = true }
    }
    return (result, failed, scan.incomplete)
  }

  private static func recognizedRegions(_ observations: [WikiPDFTextRegion], native: WikiPDFPage,
    canGroup: Bool, imageIndex: Int?) throws -> [WikiPDFKnowledgePage.Region] {
    let groups = canGroup ? try WikiPDFLayout.groups(observations) : []
    return makeRegions(groups.isEmpty ? observations.map { [$0] } : groups,
      native: native, kind: .ocrUnreviewed, imageIndex: imageIndex)
  }

  private static func makeRegions(_ groups: [[WikiPDFTextRegion]], native: WikiPDFPage,
    kind: WikiPDFEvidenceRegion.Kind, imageIndex: Int? = nil) -> [WikiPDFKnowledgePage.Region] {
    groups.enumerated().map { index, group in
      WikiPDFKnowledgePage.Region(page: regionPage(group, basedOn: native,
        extraction: kind == .layout ? .textLayer : .ocrUnreviewed),
        identity: .init(kind: kind, groupIndex: index, imageIndex: imageIndex))
    }
  }

  private static func visitPages(_ bytes: Data, pageIndices: Set<Int>?,
    _ consume: (PDFPage?, WikiPDFPage) throws -> Void) throws {
    try Task.checkCancellation()
    guard !bytes.isEmpty, bytes.count <= 50 * 1024 * 1024 else {
      throw WikiError.invalidSource("PDF 원본은 비어 있지 않은 50 MiB 이하 파일이어야 합니다.")
    }
    guard let document = PDFDocument(data: bytes) else {
      throw WikiError.invalidSource("PDF 원본을 읽을 수 없습니다.")
    }
    guard !document.isEncrypted, !document.isLocked else {
      throw WikiError.unavailable("암호화된 PDF는 현재 텍스트 추출을 지원하지 않습니다.")
    }
    guard document.pageCount > 0 else {
      throw WikiError.invalidSource("PDF 원본에 읽을 페이지가 없습니다.")
    }
    if let pageIndices, !pageIndices.allSatisfy({ $0 >= 0 && $0 < document.pageCount }) {
      throw WikiError.invalidSource("요청한 PDF 페이지가 원본 범위를 벗어났습니다.")
    }
    func consumePage(at index: Int) throws {
      try Task.checkCancellation()
      try autoreleasepool {
        guard let page = document.page(at: index) else {
          try consume(nil, WikiPDFPage(pageIndex: index, label: String(index + 1), text: "", regions: [], extraction: .unreadable))
          return
        }
        try consume(page, extractPage(page, index: index))
      }
    }
    if let pageIndices {
      for index in pageIndices.sorted() { try consumePage(at: index) }
    } else {
      for index in 0..<document.pageCount { try consumePage(at: index) }
    }
    try Task.checkCancellation()
  }

  private static func regionPage(_ regions: [WikiPDFTextRegion], basedOn native: WikiPDFPage,
    extraction: WikiPDFPage.Extraction) -> WikiPDFPage {
    var text = ""
    let positioned = regions.map { region in
      if !text.isEmpty { text += "\n" }
      let start = text.utf8.count
      text += region.text
      return WikiPDFTextRegion(text: region.text, bounds: region.bounds, byteRange: start..<text.utf8.count)
    }
    return WikiPDFPage(pageIndex: native.pageIndex, label: native.label, text: text,
      regions: positioned, extraction: extraction)
  }

  /// Use text selections to map tokens to the PDF. PDFKit's raw glyph indexes
  /// can omit line separators even when its page strings include them.
  private static func positionedText(on page: PDFPage, native: WikiPDFPage) throws
    -> (runs: [WikiPDFTextRegion], tokens: [WikiPDFTextRegion]) {
    let crop = page.bounds(for: .cropBox)
    guard page.numberOfCharacters <= 24_000, page.numberOfCharacters == native.text.utf16.count,
      page.rotation.isMultiple(of: 360), crop.width > 0, crop.height > 0 else { return (native.regions, []) }
    let text = native.text as NSString
    let matcher = try NSRegularExpression(pattern: #"\S+"#)
    let tokens = matcher.matches(in: native.text, range: NSRange(location: 0, length: text.length))
    var regions: [WikiPDFTextRegion] = []
    var positionedTokens: [WikiPDFTextRegion] = []
    var run = ""
    var region: CGRect?, lastToken: CGRect?
    var endOfPrevious = 0
    func finishRun() {
      if let region, let bounds = normalized(region, in: crop) {
        regions.append(.init(text: run, bounds: bounds))
      }
      run = ""; region = nil; lastToken = nil
    }
    for match in tokens {
      try Task.checkCancellation()
      let token = text.substring(with: match.range)
      guard let selection = page.selection(for: match.range), let selected = selection.string,
        selected.utf8.elementsEqual(token.utf8) else { return (native.regions, []) }
      let rectangle = selection.bounds(for: page)
      guard let bounds = normalized(rectangle, in: crop) else { return (native.regions, []) }
      positionedTokens.append(.init(text: token, bounds: bounds))
      let separator = text.substring(with: NSRange(location: endOfPrevious, length: match.range.location - endOfPrevious))
      endOfPrevious = NSMaxRange(match.range)
      if let previous = lastToken {
        let height = max(previous.height, rectangle.height)
        if separator.contains(where: \.isNewline) || abs(rectangle.midY - previous.midY) > height * 0.7
          || rectangle.minX - previous.maxX > max(12, height * 1.1)
          || previous.minX - rectangle.maxX > height * 1.1 { finishRun() }
      }
      if !run.isEmpty { run += separator }
      run += token
      region = region?.union(rectangle) ?? rectangle
      lastToken = rectangle
    }
    finishRun()
    return (regions, positionedTokens)
  }

  private static func extractPage(_ page: PDFPage, index: Int) throws -> WikiPDFPage {
    let label = page.label.flatMap { $0.isEmpty ? nil : $0 } ?? String(index + 1)
    let text = page.string ?? ""
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return WikiPDFPage(pageIndex: index, label: label, text: text,
        regions: [], extraction: .unreadable)
    }
    let crop = page.bounds(for: .cropBox)
    var regions: [WikiPDFTextRegion] = []
    if [crop.origin.x, crop.origin.y, crop.width, crop.height].allSatisfy(\.isFinite),
      crop.width > 0, crop.height > 0,
      let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) {
      let offsetsMatchPageString = page.numberOfCharacters == text.utf16.count
      for line in selection.selectionsByLine() {
        try Task.checkCancellation()
        guard let content = line.string,
          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let bounds = normalized(line.bounds(for: page), in: crop) else { continue }
        let byteRange: Range<Int>?
        if offsetsMatchPageString, line.numberOfTextRanges(on: page) == 1,
          let indices = Range(line.range(at: 0, on: page), in: text),
          text[indices].utf8.elementsEqual(content.utf8) {
          let start = text.utf8.distance(from: text.startIndex, to: indices.lowerBound)
          byteRange = start..<start + content.utf8.count
        } else { byteRange = nil }
        regions.append(WikiPDFTextRegion(text: content, bounds: bounds, byteRange: byteRange))
      }
    }
    // Retain page.string verbatim even when a producer cannot locate a line.
    // An empty region list means page-level evidence only; no box is invented.
    return WikiPDFPage(pageIndex: index, label: label, text: text,
      regions: regions, extraction: .textLayer)
  }

  private static func normalized(_ rectangle: CGRect, in crop: CGRect) -> WikiPDFBounds? {
    guard [rectangle.origin.x, rectangle.origin.y, rectangle.width, rectangle.height].allSatisfy(\.isFinite),
      rectangle.width > 0, rectangle.height > 0 else { return nil }
    let clipped = rectangle.intersection(crop)
    guard !clipped.isNull, !clipped.isEmpty else { return nil }
    let left = max(0, min(1, Double((clipped.minX - crop.minX) / crop.width)))
    let right = max(left, min(1, Double((clipped.maxX - crop.minX) / crop.width)))
    let bottom = max(0, min(1, Double((clipped.minY - crop.minY) / crop.height)))
    let top = max(bottom, min(1, Double((clipped.maxY - crop.minY) / crop.height)))
    let bounds = WikiPDFBounds(x: left, y: bottom, width: right - left, height: top - bottom)
    return bounds.isNormalized ? bounds : nil
  }
}
