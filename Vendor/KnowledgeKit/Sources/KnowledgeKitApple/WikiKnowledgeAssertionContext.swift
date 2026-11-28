import Foundation
import FolioKnowledge

public struct WikiKnowledgeEvidenceContext: Sendable {
  public let focus: WikiKnowledgeEvidence
  public let evidence: [WikiKnowledgeEvidence]
  /// Completeness of this bounded neighborhood, not table interpretation or semantic support.
  public let complete: Bool
  public let diagnostics: [String]
}

extension WikiWorkspace {
  /// Reads the same Markdown section or PDF page. OCR stays on the selected image when one is known.
  public func knowledgeEvidenceContext(_ focus: WikiKnowledgeEvidence, limit: Int = 8) throws -> WikiKnowledgeEvidenceContext {
    guard (1...16).contains(limit) else { throw WikiError.invalidSource("주변 근거는 1...16개로 요청해 주세요.") }
    _ = try readKnowledgeEvidence(focus)
    let material: [WikiKnowledgeEvidence]
    var unreadable = false
    switch focus.location {
    case .markdown(let reference, _):
      let blocks = try knowledgeBlocks(for: focus.source).evidence
      var seen = Set<String>()
      let sections = blocks.compactMap { $0.markdownReference?.sectionID }.filter { seen.insert($0).inserted }
      guard let ordinal = sections.firstIndex(of: reference.sectionID) else { throw WikiError.changedSource }
      let neighboring = Set(sections[max(0, ordinal - 1)...min(sections.count - 1, ordinal + 1)])
      material = blocks.filter { $0.markdownReference.map { neighboring.contains($0.sectionID) } == true }
    case .pdf(let pageIndex, _, _, _, _):
      let (_, bytes) = try knowledgeCurrentSource(focus.source)
      var pageEvidence: [WikiKnowledgeEvidence] = []
      let images: [Int: Set<Int>] = focus.pdfRegion?.imageIndex.map { [pageIndex: [$0]] } ?? [:]
      try WikiPDFExtractor.forEachKnowledgePage(bytes, pageIndices: [pageIndex], enhancedPages: [pageIndex],
        mixedImageIndices: images) { page in
          unreadable = page.recognitionFailed || page.imageScanIncomplete
            || (page.native.extraction == .unreadable && page.regions.isEmpty)
          if page.includesNative && page.native.extraction == .textLayer {
            pageEvidence += try knowledgePDFBlocks(page.native, source: focus.source, sourceRevision: focus.source.indexRevision)
          }
          for region in page.regions {
            pageEvidence += try knowledgePDFBlocks(region.page, source: focus.source,
              sourceRevision: focus.source.indexRevision, region: region.identity)
          }
        }
      material = pageEvidence
    }
    var seen = Set([focus.id])
    let nearby = material.filter { seen.insert($0.id).inserted }
    let result = [focus] + nearby.prefix(limit - 1)
    _ = try readKnowledgeEvidence(result)
    var diagnostics: [String] = []
    if nearby.count + 1 > limit { diagnostics.append("주변 근거의 일부만 표시했습니다.") }
    if unreadable { diagnostics.append("같은 페이지에서 읽지 못한 내용이 있습니다.") }
    return .init(focus: focus, evidence: result, complete: diagnostics.isEmpty, diagnostics: diagnostics)
  }
}
