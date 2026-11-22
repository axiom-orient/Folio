import CoreGraphics
import CoreText
import Foundation
import Testing
import FolioKnowledge
import FolioKnowledgeApple

@Suite struct PDFExtractionTests {
  @Test func textPagesKeepOrderTextAndSourceCoordinatesWhileBlankPagesRemainExplicit() throws {
    let bytes = try makePDF(pages: [
      ["Alpha evidence remains on page one.", "Second source line."],
      ["한국어 원문 보존", "Beta evidence remains on page two."],
      []
    ])
    let pages = try WikiPDFExtractor.extract(bytes)
    #expect(pages.map(\.pageIndex) == [0, 1, 2])
    #expect(pages.map(\.label) == ["1", "2", "3"])
    #expect(pages.map(\.extraction) == [.textLayer, .textLayer, .unreadable])
    #expect(pages[0].text.contains("Alpha evidence remains on page one."))
    #expect(pages[0].text.contains("Second source line."))
    #expect(pages[1].text.contains("한국어 원문 보존"))
    #expect(pages[1].text.contains("Beta evidence remains on page two."))
    let firstLine = try #require(pages[0].regions.first { $0.text.contains("Alpha evidence") })
    #expect(abs(firstLine.bounds.x - 72.0 / 612.0) < 0.02)
    #expect(firstLine.bounds.y > 0.7, "Text near the page's top must have a high bottom-left y coordinate.")
    #expect(pages[0].regions.allSatisfy { $0.bounds.isNormalized })
    #expect(pages[1].regions.allSatisfy { $0.bounds.isNormalized })
    #expect(pages[2].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(pages[2].regions.isEmpty)
  }

  @Test func selectingPagesKeepsTheirOriginalPositionsAndRejectsUnknownIndices() throws {
    let bytes = try makePDF(pages: [["First source."], ["Second source."], ["Third source."]])
    let selected = try WikiPDFExtractor.extract(bytes, pageIndices: [2, 0])
    #expect(selected.map(\.pageIndex) == [0, 2])
    #expect(selected.map(\.label) == ["1", "3"])
    #expect(selected[1].text.contains("Third source."))
    #expect(try WikiPDFExtractor.extract(bytes, pageIndices: []).isEmpty)
    #expect(throws: WikiError.self) { try WikiPDFExtractor.extract(bytes, pageIndices: [-1]) }
    #expect(throws: WikiError.self) { try WikiPDFExtractor.extract(bytes, pageIndices: [3]) }
  }

  @Test func invalidEncryptedAndCancelledSourcesDoNotReturnAnEmptySuccess() async throws {
    #expect(throws: WikiError.self) { try WikiPDFExtractor.extract(Data()) }
    #expect(throws: WikiError.self) { try WikiPDFExtractor.extract(Data("not a PDF".utf8)) }
    let encrypted = try makePDF(pages: [["Protected source."]], encrypted: true)
    #expect(throws: WikiError.self) { try WikiPDFExtractor.extract(encrypted) }
    let bytes = try makePDF(pages: [["A valid source."]])
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try WikiPDFExtractor.extract(bytes)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
  }

  /// Builds an in-memory document only. It never opens a window or a device.
  private func makePDF(pages: [[String]], encrypted: Bool = false) throws -> Data {
    let storage = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: storage))
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    let options: CFDictionary? = encrypted ? [
      kCGPDFContextUserPassword as String: "fixture-reader",
      kCGPDFContextOwnerPassword as String: "fixture-owner"
    ] as CFDictionary : nil
    let context = try #require(CGContext(consumer: consumer, mediaBox: &media, options))
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    for lines in pages {
      context.beginPDFPage(nil)
      context.textMatrix = .identity
      for (index, text) in lines.enumerated() {
        let string = NSAttributedString(string: text, attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 72, y: CGFloat(700 - index * 28))
        CTLineDraw(CTLineCreateWithAttributedString(string as CFAttributedString), context)
      }
      context.endPDFPage()
    }
    context.closePDF()
    return storage as Data
  }
}
