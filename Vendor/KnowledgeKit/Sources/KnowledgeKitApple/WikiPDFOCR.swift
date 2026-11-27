import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Recognizes a single admitted page. The raster and Vision results are local
/// to this operation, and the page is never changed.
enum WikiPDFOCR {
  static let identifier = "apple-vision-r3.ko-en.crop2200.v1"
  static let regionalIdentifier = "apple-vision-r3.ko-en.image-region.v1"
  private static let maximumEdge: CGFloat = 2_200
  private static let maximumScale: CGFloat = 3

  /// Regions are positioned in the original, unrotated PDF crop box.
  /// The caller assigns byte ranges once it has assembled the transcript.
  static func recognize(_ page: PDFPage, in imageRegion: CGRect? = nil,
    excluding existingText: [WikiPDFTextRegion] = []) throws -> [WikiPDFTextRegion] {
    try Task.checkCancellation()
    guard let pdfPage = page.pageRef, pdfPage.rotationAngle.isMultiple(of: 90) else { return [] }
    let crop = page.bounds(for: .cropBox)
    guard isFiniteRectangle(crop) else { return [] }
    let area = imageRegion.map { $0.intersection(crop) } ?? crop
    guard isFiniteRectangle(area) else { return [] }

    let quarterTurn = !pdfPage.rotationAngle.isMultiple(of: 180)
    let width = quarterTurn ? area.height : area.width
    let height = quarterTurn ? area.width : area.height
    let scale = min(maximumScale, maximumEdge / max(width, height))
    let rasterWidth = Int((width * scale).rounded(.up))
    let rasterHeight = Int((height * scale).rounded(.up))
    guard rasterWidth >= 32, rasterHeight >= 32,
      let context = CGContext(data: nil, width: min(rasterWidth, Int(maximumEdge)),
        height: min(rasterHeight, Int(maximumEdge)), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }

    let raster = CGRect(x: 0, y: 0, width: context.width, height: context.height)
    let pdfToRaster: CGAffineTransform
    if imageRegion != nil {
      let uprightBox = CGRect(x: 0, y: 0, width: quarterTurn ? crop.height : crop.width,
        height: quarterTurn ? crop.width : crop.height)
      let upright = pdfPage.getDrawingTransform(.cropBox, rect: uprightBox, rotate: 0, preserveAspectRatio: true)
      let tile = area.applying(upright)
      guard isFiniteRectangle(tile) else { return [] }
      let fitted = min(raster.width / tile.width, raster.height / tile.height)
      pdfToRaster = upright.concatenating(.init(translationX: -tile.minX, y: -tile.minY))
        .concatenating(.init(scaleX: fitted, y: fitted))
    } else {
      // Preserve the full-page producer used by saved scan citations.
      pdfToRaster = pdfPage.getDrawingTransform(.cropBox, rect: raster, rotate: 0, preserveAspectRatio: true)
    }
    let determinant = pdfToRaster.a * pdfToRaster.d - pdfToRaster.b * pdfToRaster.c
    guard determinant.isFinite, determinant != 0 else { return [] }
    let rasterToPDF = pdfToRaster.inverted()
    guard [rasterToPDF.a, rasterToPDF.b, rasterToPDF.c, rasterToPDF.d, rasterToPDF.tx, rasterToPDF.ty]
      .allSatisfy(\.isFinite) else { return [] }

    context.setFillColor(gray: 1, alpha: 1)
    context.fill(raster)
    context.concatenate(pdfToRaster)
    context.clip(to: area)
    context.drawPDFPage(pdfPage)
    try Task.checkCancellation()
    guard let image = context.makeImage() else { return [] }

    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = .accurate
    let supported = try request.supportedRecognitionLanguages()
    let languages = [["ko-KR", "ko"], ["en-US", "en"]].compactMap { preferred in
      preferred.first(where: supported.contains)
    }
    guard !languages.isEmpty else { return [] }
    request.recognitionLanguages = languages
    // Preserve what the recognizer saw, including unfamiliar labels and digits.
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
    try Task.checkCancellation()

    let observations = (request.results ?? []).filter { isFiniteRectangle($0.boundingBox) }
      .sorted { left, right in
        let lhs = left.boundingBox, rhs = right.boundingBox
        return lhs.maxY == rhs.maxY ? lhs.minX < rhs.minX : lhs.maxY > rhs.maxY
      }
    func sourceBounds(_ rectangle: CGRect) -> WikiPDFBounds? {
      let pixels = CGRect(x: rectangle.minX * raster.width, y: rectangle.minY * raster.height,
        width: rectangle.width * raster.width, height: rectangle.height * raster.height)
      let region = pixels.applying(rasterToPDF).intersection(area)
      guard isFiniteRectangle(region) else { return nil }
      let bounds = WikiPDFBounds(x: (region.minX - crop.minX) / crop.width,
        y: (region.minY - crop.minY) / crop.height, width: region.width / crop.width, height: region.height / crop.height)
      return bounds.isNormalized ? bounds : nil
    }

    return try observations.flatMap { observation -> [WikiPDFTextRegion] in
      try Task.checkCancellation()
      guard let candidate = observation.topCandidates(1).first, candidate.confidence > 0,
        !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let bounds = sourceBounds(observation.boundingBox) else { return [] }
      return try uniqueText(candidate, bounds: bounds, existingText: existingText, sourceBounds: sourceBounds)
    }
  }

  private static func uniqueText(_ candidate: VNRecognizedText, bounds: WikiPDFBounds,
    existingText: [WikiPDFTextRegion], sourceBounds: (CGRect) -> WikiPDFBounds?) throws -> [WikiPDFTextRegion] {
    let text = candidate.string
    let whole = WikiPDFTextRegion(text: text, bounds: bounds)
    let nearby = existingText.filter { overlaps(bounds, $0.bounds) }
    if nearby.isEmpty { return [whole] }
    let comparisonText = comparable(text)
    if nearby.contains(where: { comparable($0.text) == comparisonText }) { return [] }

    // A caption or an invisible text overlay can account for only part of an
    // OCR line. Suppress matching words at the same location and keep the rest.
    var retained: [Range<String.Index>] = []
    var current: Range<String.Index>?
    var removedWord = false
    for word in text.split(whereSeparator: \.isWhitespace) {
      try Task.checkCancellation()
      let range = word.startIndex..<word.endIndex
      let wordBounds = (try? candidate.boundingBox(for: range)).flatMap { sourceBounds($0.boundingBox) }
      let duplicate = wordBounds.map { box in
        nearby.contains { overlaps(box, $0.bounds) && comparable($0.text) == comparable(String(word)) }
      } ?? false
      if duplicate {
        if let current { retained.append(current) }
        current = nil
        removedWord = true
      } else { current = (current?.lowerBound ?? range.lowerBound)..<range.upperBound }
    }
    guard removedWord else { return [whole] }
    if let current { retained.append(current) }
    return retained.compactMap { range in
      guard let box = try? candidate.boundingBox(for: range), let localized = sourceBounds(box.boundingBox) else { return nil }
      return WikiPDFTextRegion(text: String(text[range]), bounds: localized)
    }
  }

  private static func comparable(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func overlaps(_ first: WikiPDFBounds, _ second: WikiPDFBounds) -> Bool {
    let width = min(first.x + first.width, second.x + second.width) - max(first.x, second.x)
    let height = min(first.y + first.height, second.y + second.height) - max(first.y, second.y)
    return width > 0 && height > 0 && width * height >= min(first.width * first.height, second.width * second.height) * 0.55
  }

  private static func isFiniteRectangle(_ rectangle: CGRect) -> Bool {
    [rectangle.minX, rectangle.minY, rectangle.maxX, rectangle.maxY].allSatisfy(\.isFinite)
      && rectangle.width > 0 && rectangle.height > 0
  }
}
