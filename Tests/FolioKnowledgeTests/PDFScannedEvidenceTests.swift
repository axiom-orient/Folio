import CoreGraphics
import CoreText
import FolioKnowledge
import FolioKnowledgeApple
import Foundation
import Testing

@Test func scannedKoreanPDFSearchReopensOriginalImageRegion() async throws {
  let fixture = try KnowledgeFixture(); defer { fixture.remove() }
  let sourceURL = fixture.root.appendingPathComponent("attachments/lab.pdf")
  let original = try makeScannedNotebook()
  try original.write(to: sourceURL)
  try fixture.write("---\nid: lab\n---\n# 실험 자료\n\n[PDF](../attachments/lab.pdf)\n", path: "notes/lab.md")

  let baseline = try #require(WikiPDFExtractor.extract(original, pageIndices: [1]).first)
  #expect(baseline.extraction == .unreadable && baseline.text.isEmpty)

  let engine = WikiKnowledgeQuery(workspace: fixture.workspace)
  let answer = try await engine.answer("실험", documentID: "lab")
  #expect(answer.coverage.unreadablePages == 1)
  let hit = try #require(answer.evidence.first { $0.pdfRegion?.kind == .ocrUnreviewed && $0.text.contains("실험") })
  let preview = try await fixture.workspace.previewKnowledgePDF(hit)
  #expect(hit.displayLocation.contains("스캔 인식"))
  #expect(preview.pageIndex == 1 && preview.usesOCR && preview.data == original)
  let region = try #require(preview.bounds.first)
  #expect(region.x > 0.13 && region.x < 0.20 && region.y > 0.69 && region.y < 0.76)
  #expect(region.isNormalized)
  #expect(try Data(contentsOf: sourceURL) == original)

  guard case .pdf(let index, let label, let range, let hash, _) = hit.location else {
    Issue.record("Expected a PDF region")
    return
  }
  let forged = WikiKnowledgeEvidence(id: hit.id, text: hit.text, source: hit.source,
    location: .pdf(pageIndex: index, label: label, range: range, pageSHA256: hash,
      bounds: [.init(x: 0.2, y: 0.2, width: 0.1, height: 0.1)]), pdfRegion: hit.pdfRegion)
  await #expect(throws: WikiError.changedSource) { try await fixture.workspace.previewKnowledgePDF(forged) }
  try Data("replaced".utf8).write(to: sourceURL)
  await #expect(throws: WikiError.changedSource) { try await fixture.workspace.previewKnowledgePDF(hit) }
}

private func makeScannedNotebook() throws -> Data {
  let raster = try #require(CGContext(data: nil, width: 1_224, height: 1_584, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
  raster.setFillColor(gray: 1, alpha: 1)
  raster.fill(CGRect(x: 0, y: 0, width: 1_224, height: 1_584))
  raster.setFillColor(gray: 0, alpha: 1)
  raster.textMatrix = .identity
  raster.textPosition = CGPoint(x: 196, y: 1_142)
  let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 56, nil)
  let text = NSAttributedString(string: "실험 결과를 확인합니다", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
  ])
  CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), raster)
  let scan = try #require(raster.makeImage())

  let storage = NSMutableData()
  let consumer = try #require(CGDataConsumer(data: storage))
  var media = CGRect(x: 0, y: 0, width: 612, height: 792)
  let pdf = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
  pdf.beginPDFPage(nil)
  pdf.textPosition = CGPoint(x: 80, y: 700)
  CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Cover") as CFAttributedString), pdf)
  pdf.endPDFPage()
  pdf.beginPDFPage(nil)
  pdf.draw(scan, in: media)
  pdf.endPDFPage()
  pdf.beginPDFPage(nil)
  pdf.endPDFPage()
  pdf.closePDF()
  return storage as Data
}
