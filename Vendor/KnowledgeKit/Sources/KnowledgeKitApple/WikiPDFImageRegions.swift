import CoreGraphics
import Foundation
import PDFKit

/// Finds image paints in a mixed PDF page without treating unpainted resources
/// or the rest of the page as OCR input. Rectangles are in PDF page space.
enum WikiPDFImageRegions {
  struct ScanResult {
    let regions: [CGRect]
    let incomplete: Bool
  }

  static func regions(in page: PDFPage) throws -> ScanResult {
    try Task.checkCancellation()
    let crop = page.bounds(for: .cropBox)
    guard let pdf = page.pageRef, hasArea(crop), let table = CGPDFOperatorTableCreate() else {
      return ScanResult(regions: [], incomplete: true)
    }
    defer { CGPDFOperatorTableRelease(table) }
    configure(table)

    let content = CGPDFContentStreamCreateWithPage(pdf)
    defer { CGPDFContentStreamRelease(content) }
    let budget = ScanBudget()
    let state = GraphicsState(transform: .identity, clip: crop)
    let frame = ScanFrame(table: table, budget: budget, state: state,
      pageResources: pageResources(pdf.dictionary), depth: 0)
    frame.scan(content)
    try Task.checkCancellation()
    let ordered = budget.regions.sorted { left, right in
      if left.maxY != right.maxY { return left.maxY > right.maxY }
      if left.minX != right.minX { return left.minX < right.minX }
      if left.minY != right.minY { return left.minY > right.minY }
      return left.maxX < right.maxX
    }
    return ScanResult(regions: ordered, incomplete: budget.stopped || budget.incomplete)
  }

  private static func configure(_ table: CGPDFOperatorTableRef) {
    CGPDFOperatorTableSetCallback(table, "q") { WikiPDFImageRegions.scan($0, $1, .save) }
    CGPDFOperatorTableSetCallback(table, "Q") { WikiPDFImageRegions.scan($0, $1, .restore) }
    CGPDFOperatorTableSetCallback(table, "cm") { WikiPDFImageRegions.scan($0, $1, .concatenate) }
    CGPDFOperatorTableSetCallback(table, "Do") { WikiPDFImageRegions.scan($0, $1, .object) }
    CGPDFOperatorTableSetCallback(table, "EI") { WikiPDFImageRegions.scan($0, $1, .inlineImage) }
    CGPDFOperatorTableSetCallback(table, "re") { WikiPDFImageRegions.scan($0, $1, .rectangle) }
    for name in ["m", "l", "c", "v", "y", "h"] {
      CGPDFOperatorTableSetCallback(table, name) { WikiPDFImageRegions.scan($0, $1, .complexPath) }
    }
    for name in ["W", "W*"] {
      CGPDFOperatorTableSetCallback(table, name) { WikiPDFImageRegions.scan($0, $1, .clip) }
    }
    for name in ["n", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*"] {
      CGPDFOperatorTableSetCallback(table, name) { WikiPDFImageRegions.scan($0, $1, .finishPath) }
    }
    CGPDFOperatorTableSetCallback(table, "Tr") { WikiPDFImageRegions.scan($0, $1, .textMode) }
    CGPDFOperatorTableSetCallback(table, "ET") { WikiPDFImageRegions.scan($0, $1, .finishText) }
    for name in ["Tj", "TJ", "'", "\""] {
      CGPDFOperatorTableSetCallback(table, name) { WikiPDFImageRegions.scan($0, $1, .paintText) }
    }
    for name in ["Tf", "Td", "TD", "Tm", "T*", "BT", "gs", "sh"] {
      CGPDFOperatorTableSetCallback(table, name) { WikiPDFImageRegions.scan($0, $1, .count) }
    }
  }

  private enum Operator {
    case save, restore, concatenate, object, inlineImage
    case rectangle, complexPath, clip, finishPath
    case textMode, paintText, finishText, count
  }

  private static func scan(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?, _ op: Operator) {
    guard let info else { return }
    let frame = Unmanaged<ScanFrame>.fromOpaque(info).takeUnretainedValue()
    guard frame.budget.admitOperator(scanner) else { return }
    switch op {
    case .save: frame.save(scanner)
    case .restore: frame.restore(scanner)
    case .concatenate: frame.concatenate(scanner)
    case .object: frame.drawObject(scanner)
    case .inlineImage: frame.drawImage(scanner)
    case .rectangle: frame.addRectangle(scanner)
    case .complexPath: frame.path = .complex
    case .clip: frame.pendingClip = true
    case .finishPath: frame.finishPath()
    case .textMode: frame.setTextMode(scanner)
    case .paintText: if frame.state.textClips { frame.pendingTextClip = true }
    case .finishText: frame.finishText()
    case .count: break
    }
  }

  private static func pageResources(_ dictionary: CGPDFDictionaryRef?) -> CGPDFDictionaryRef? {
    var current = dictionary
    // /Resources is inheritable in the page tree. Bound traversal even when
    // the PDF producer supplied a cyclic or malformed /Parent chain.
    for _ in 0..<32 {
      guard let node = current else { return nil }
      var resources: CGPDFDictionaryRef?
      if CGPDFDictionaryGetDictionary(node, "Resources", &resources) { return resources }
      current = nil
      _ = CGPDFDictionaryGetDictionary(node, "Parent", &current)
    }
    return nil
  }

  private static func hasArea(_ rect: CGRect) -> Bool {
    rect.width > 0 && rect.height > 0 && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
  }

  /// A rectangular OCR crop can represent right-angle transforms and mirrors.
  /// A skew or arbitrary angle would include page content outside the image.
  private static func mappedRectangle(_ rect: CGRect, through transform: CGAffineTransform) -> CGRect? {
    guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
      .allSatisfy(\.isFinite) else { return nil }
    let tolerance = 1e-10
    let straight = abs(transform.b) <= tolerance * abs(transform.a) && abs(transform.c) <= tolerance * abs(transform.d)
    let quarterTurn = abs(transform.a) <= tolerance * abs(transform.b) && abs(transform.d) <= tolerance * abs(transform.c)
    guard straight || quarterTurn else { return nil }
    let result = rect.applying(transform)
    return hasArea(result) ? result : nil
  }

  private struct GraphicsState {
    var transform: CGAffineTransform
    // nil denotes an unsupported clip shape; a null CGRect denotes empty paint.
    var clip: CGRect?
    var textClips = false
  }

  private final class ScanBudget {
    private var callbacks = 0
    private var encodedBytes = 0
    var stopped = false
    var incomplete = false
    var regions: [CGRect] = []

    func admitOperator(_ scanner: CGPDFScannerRef) -> Bool {
      callbacks += 1
      guard !stopped, callbacks <= 50_000, !Task.isCancelled else { stop(scanner); return false }
      return true
    }

    func admitStream(_ content: CGPDFContentStreamRef) -> Bool {
      guard let streams = CGPDFContentStreamGetStreams(content) else { return true }
      let count = CFArrayGetCount(streams)
      guard count <= 128 else { return false }
      for index in 0..<count {
        guard let pointer = CFArrayGetValueAtIndex(streams, index),
          let dictionary = CGPDFStreamGetDictionary(CGPDFStreamRef(OpaquePointer(pointer))) else { return false }
        var length: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Length", &length), length >= 0,
          length <= 4 * 1024 * 1024 - encodedBytes else { return false }
        encodedBytes += length
      }
      return true
    }

    func stop(_ scanner: CGPDFScannerRef) {
      stopped = true
      CGPDFScannerStop(scanner)
    }
  }

  private final class ScanFrame {
    enum Path {
      case empty, rectangle(CGRect), complex
    }

    let table: CGPDFOperatorTableRef
    let budget: ScanBudget
    let pageResources: CGPDFDictionaryRef?
    let depth: Int
    var state: GraphicsState
    var stack: [GraphicsState] = []
    var path: Path = .empty
    var pendingClip = false
    var pendingTextClip = false

    init(table: CGPDFOperatorTableRef, budget: ScanBudget, state: GraphicsState,
      pageResources: CGPDFDictionaryRef?, depth: Int
    ) {
      self.table = table; self.budget = budget; self.state = state
      self.pageResources = pageResources; self.depth = depth
    }

    func scan(_ content: CGPDFContentStreamRef) {
      guard budget.admitStream(content) else { budget.stopped = true; return }
      withExtendedLifetime(self) {
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        if !CGPDFScannerScan(scanner) { budget.stopped = true }
      }
    }

    func save(_ scanner: CGPDFScannerRef) {
      guard stack.count < 64 else { budget.stop(scanner); return }
      stack.append(state)
    }

    func restore(_ scanner: CGPDFScannerRef) {
      guard let saved = stack.popLast() else { budget.stop(scanner); return }
      state = saved
    }

    func concatenate(_ scanner: CGPDFScannerRef) {
      guard let values = popNumbers(6, scanner) else { budget.stop(scanner); return }
      let transform = CGAffineTransform(a: values[0], b: values[1], c: values[2],
        d: values[3], tx: values[4], ty: values[5])
      state.transform = transform.concatenating(state.transform)
    }

    func drawImage(_ scanner: CGPDFScannerRef) {
      guard let clip = state.clip else { budget.incomplete = true; return }
      guard !clip.isNull else { return }
      let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
      guard let footprint = mappedRectangle(unit, through: state.transform) else { budget.incomplete = true; return }
      let region = clip.intersection(footprint)
      guard hasArea(region), !budget.regions.contains(where: { $0.contains(region) }) else { return }
      budget.regions.removeAll(where: { region.contains($0) })
      guard budget.regions.count < 64 else { budget.stop(scanner); return }
      budget.regions.append(region)
    }

    func drawObject(_ scanner: CGPDFScannerRef) {
      guard state.clip?.isNull != true else { return }
      var name: UnsafePointer<CChar>?
      guard CGPDFScannerPopName(scanner, &name), let name else { budget.incomplete = true; return }
      let parent = CGPDFScannerGetContentStream(scanner)
      var stream: CGPDFStreamRef?
      var subtype: UnsafePointer<CChar>?
      guard let object = CGPDFContentStreamGetResource(parent, "XObject", name),
        CGPDFObjectGetValue(object, .stream, &stream), let stream,
        let dictionary = CGPDFStreamGetDictionary(stream),
        CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { budget.incomplete = true; return }
      switch String(cString: subtype) {
      case "Image": drawImage(scanner)
      case "Form": drawForm(stream, dictionary: dictionary, parent: parent, scanner: scanner)
      default: break
      }
    }

    private func drawForm(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef,
      parent: CGPDFContentStreamRef, scanner: CGPDFScannerRef
    ) {
      guard depth < 8 else { budget.incomplete = true; return }
      var formTransform = CGAffineTransform.identity
      var entry: CGPDFObjectRef?
      if CGPDFDictionaryGetObject(dictionary, "Matrix", &entry) {
        guard let values = numbers(in: dictionary, key: "Matrix", count: 6) else { budget.incomplete = true; return }
        formTransform = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3],
          tx: values[4], ty: values[5])
      }
      guard let box = numbers(in: dictionary, key: "BBox", count: 4) else { budget.incomplete = true; return }
      let bbox = CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1]).standardized
      let transform = formTransform.concatenating(state.transform)
      let clip = mappedRectangle(bbox, through: transform).flatMap { footprint in
        state.clip?.intersection(footprint)
      }
      if let clip, !hasArea(clip) { return }

      var ownResources: CGPDFDictionaryRef?
      if CGPDFDictionaryGetObject(dictionary, "Resources", &entry),
        !CGPDFDictionaryGetDictionary(dictionary, "Resources", &ownResources) { budget.incomplete = true; return }
      // A legacy form without /Resources uses the page tree's dictionary.
      let resolvedResources = ownResources ?? pageResources ?? dictionary
      let content = CGPDFContentStreamCreateWithStream(stream, resolvedResources, parent)
      defer { CGPDFContentStreamRelease(content) }
      let next = GraphicsState(transform: transform, clip: clip, textClips: state.textClips)
      ScanFrame(table: table, budget: budget, state: next, pageResources: pageResources, depth: depth + 1).scan(content)
      if budget.stopped { budget.stop(scanner) }
    }

    func addRectangle(_ scanner: CGPDFScannerRef) {
      guard let values = popNumbers(4, scanner), case .empty = path else { path = .complex; return }
      let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3]).standardized
      if let footprint = mappedRectangle(rect, through: state.transform) { path = .rectangle(footprint) }
      else { path = .complex }
    }

    func finishPath() {
      if pendingClip {
        if case .rectangle(let rect) = path { state.clip = state.clip?.intersection(rect) }
        else if state.clip?.isNull != true { state.clip = nil }
      }
      pendingClip = false
      path = .empty
    }

    func setTextMode(_ scanner: CGPDFScannerRef) {
      var mode: CGPDFInteger = 0
      guard CGPDFScannerPopInteger(scanner, &mode) else { budget.stop(scanner); return }
      state.textClips = (4...7).contains(mode)
    }

    func finishText() {
      if pendingTextClip, state.clip?.isNull != true { state.clip = nil }
      pendingTextClip = false
    }

    private func popNumbers(_ count: Int, _ scanner: CGPDFScannerRef) -> [CGFloat]? {
      var values = [CGFloat](repeating: 0, count: count)
      for index in values.indices.reversed() {
        guard CGPDFScannerPopNumber(scanner, &values[index]), values[index].isFinite else { return nil }
      }
      return values
    }

    private func numbers(in dictionary: CGPDFDictionaryRef, key: String, count: Int) -> [CGFloat]? {
      var array: CGPDFArrayRef?
      guard CGPDFDictionaryGetArray(dictionary, key, &array), let array,
        CGPDFArrayGetCount(array) == count else { return nil }
      var values = [CGFloat](repeating: 0, count: count)
      for index in values.indices {
        guard CGPDFArrayGetNumber(array, index, &values[index]), values[index].isFinite else { return nil }
      }
      return values
    }
  }
}
