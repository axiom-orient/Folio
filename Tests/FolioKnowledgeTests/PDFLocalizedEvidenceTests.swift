import CoreGraphics
import CoreText
import Foundation
import Testing
import FolioKnowledge
import FolioKnowledgeApple

@Test func nativePDFLocalizesTableRowsAndFormulasWithoutChangingTheOriginal() async throws {
  let fixture = try KnowledgeFixture()
  defer { fixture.remove() }
  let sourcePath = "attachments/physics.pdf"
  let original = try makePhysicsPDF()
  let sourceURL = fixture.root.appendingPathComponent(sourcePath)
  try original.write(to: sourceURL)
  try fixture.write("---\nid: physics\n---\n# Physics reference\n[Original](../attachments/physics.pdf)\n", path: "notes/physics.md")

  let flat = try WikiPDFExtractor.extract(original)
  try #require(flat.map(\.extraction) == [.textLayer, .textLayer])
  #expect(flat[0].text.contains("rowprism") && flat[0].text.contains("rowlattice"))
  #expect(flat[1].text.contains("F = mass * acceleration"))

  let query = WikiKnowledgeQuery(workspace: fixture.workspace)
  let answer = try await query.answer("albedotarget", documentID: "physics")
  let row = try #require(answer.evidence.first { $0.pdfRegion?.kind == .layout })
  #expect(row.text.contains("albedotarget") && row.text.contains("Reflectance") && row.text.contains("42 percent"))
  #expect(!row.text.contains("rowprism") && !row.text.contains("rowlattice"))
  #expect(try await fixture.workspace.readKnowledgeEvidence(row).utf8.elementsEqual(row.text.utf8))
  guard case .pdf(let pageIndex, _, _, _, let bounds) = row.location else {
    Issue.record("A table match must identify an original PDF page.")
    return
  }
  #expect(pageIndex == 0)
  #expect(bounds.count == 3)
  for (box, x) in zip(bounds, [64.0, 236.0, 408.0]) {
    #expect(box.isNormalized)
    #expect(abs(box.x - x / 612) < 0.025)
    #expect(abs(box.y - 620.0 / 792) < 0.025)
  }
  let preview = try await fixture.workspace.previewKnowledgePDF(row)
  #expect(!preview.usesOCR && preview.bounds == bounds && preview.pageIndex == 0)
  #expect(SourceDigest.sha256(preview.data) == SourceDigest.sha256(original))

  let formulaAnswer = try await query.answer("acceleration", documentID: "physics")
  let formula = try #require(formulaAnswer.evidence.first { $0.pdfRegion?.kind == .layout })
  let formulaPreview = try await fixture.workspace.previewKnowledgePDF(formula)
  #expect(formula.text.contains("F = mass * acceleration"))
  #expect(formulaPreview.pageIndex == 1 && formulaPreview.bounds.count == 1)
  #expect(try Data(contentsOf: sourceURL) == original)
  await fixture.workspace.close()
}

private func makePhysicsPDF() throws -> Data {
  let storage = NSMutableData()
  let consumer = try #require(CGDataConsumer(data: storage))
  var media = CGRect(x: 0, y: 0, width: 612, height: 792)
  let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
  let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
  func draw(_ text: String, x: CGFloat, y: CGFloat) {
    context.textPosition = CGPoint(x: x, y: y)
    let source = NSAttributedString(string: text, attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
    ])
    CTLineDraw(CTLineCreateWithAttributedString(source as CFAttributedString), context)
  }

  context.beginPDFPage(nil)
  context.textMatrix = .identity
  for (index, cells) in [
    ["rowprism", "Dispersion", "12 percent"],
    ["albedotarget", "Reflectance", "42 percent"],
    ["rowlattice", "Diffraction", "65 percent"]
  ].enumerated() {
    let y = CGFloat(660 - index * 40)
    for (x, cell) in zip([64, 236, 408] as [CGFloat], cells) { draw(cell, x: x, y: y) }
  }
  context.endPDFPage()

  context.beginPDFPage(nil)
  context.textMatrix = .identity
  draw("Mechanics", x: 64, y: 700)
  draw("F = mass * acceleration", x: 180, y: 620)
  context.endPDFPage()
  context.closePDF()
  return storage as Data
}
