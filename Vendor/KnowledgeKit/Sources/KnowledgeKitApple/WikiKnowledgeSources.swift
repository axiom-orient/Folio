import Foundation
import FolioKnowledge

extension WikiWorkspace {
  var knowledgeScopeID: String {
    guard let namespace = managedLocalKnowledgeNamespace else { return pathKnowledgeScopeID }
    return SourceDigest.sha256("folio.knowledge.local.v1:\(namespace.uuidString):\(workspaceID.uuidString)")
  }

  private var pathKnowledgeScopeID: String {
    var scope = [root.path, workspaceID.uuidString, receiptDirectory.deletingLastPathComponent().path]
    if let knowledgeAccountScope { scope.append(knowledgeAccountScope.uuidString) }
    return SourceDigest.sha256((try? JSONEncoder().encode(scope)) ?? Data())
  }

  /// Only currently admitted notes and PDF links declared by those notes enter the corpus.
  /// Unlinked files and stale scanner records never acquire source authority from a cache.
  public func knowledgeInventory() async throws -> WikiKnowledgeInventory {
    let snapshot = try await refresh()
    try requireKnowledgeAccess()
    let scope = knowledgeScopeID
    var sources: [WikiKnowledgeSource] = []
    var admittedDocumentIDs = Set<String>()
    var pdfRevisions: [String: String] = [:]
    var diagnostics = snapshot.diagnostics.map { "\($0.path): \($0.reason)" }
    if !snapshot.coverageComplete && diagnostics.isEmpty { diagnostics.append("일부 자료를 읽을 수 없습니다.") }
    for document in snapshot.documents {
      try Task.checkCancellation()
      do {
        let bytes = try knowledgeRead(path: document.relativePath, maximumBytes: 256 * 1024)
        guard SourceDigest.sha256(bytes) == document.revision else { throw WikiError.changedSource }
        if try WikiMarkdownParser.isDerivedKnowledgeNote(bytes: bytes) { continue }
        admittedDocumentIDs.insert(document.id)
        if WikiAttachmentImport.unmodifiedPDFPath(in: document) == nil {
          sources.append(knowledgeSource(document, path: document.relativePath, revision: document.revision,
            kind: .markdown, scope: scope))
        }
        for path in knowledgePDFLinks(document).sorted() {
          try Task.checkCancellation()
          do {
            let revision: String
            if let alreadyRead = pdfRevisions[path] { revision = alreadyRead }
            else {
              revision = SourceDigest.sha256(try knowledgeRead(path: path, maximumBytes: 50 * 1024 * 1024))
              pdfRevisions[path] = revision
            }
            sources.append(knowledgeSource(document, path: path, revision: revision, kind: .pdf, scope: scope))
          } catch is CancellationError { throw CancellationError() }
          catch { diagnostics.append("\(document.title): PDF 원본을 읽을 수 없습니다. \(error.localizedDescription)") }
        }
      } catch is CancellationError { throw CancellationError() }
      catch { diagnostics.append("\(document.title): \(error.localizedDescription)") }
    }
    sources.sort { $0.id < $1.id }
    diagnostics.sort()
    let fingerprint = SourceDigest.sha256(try JSONEncoder().encode([[scope], sources.map(\.indexRevision), diagnostics]))
    try requireKnowledgeAccess()
    return WikiKnowledgeInventory(sources: sources, diagnostics: diagnostics, fingerprint: fingerprint,
      admittedDocumentIDs: admittedDocumentIDs)
  }

  /// Rebuildable material only. Every returned quotation is verified again at publication.
  public func knowledgeBlocks(for source: WikiKnowledgeSource) throws -> WikiKnowledgeMaterial {
    let (document, bytes) = try knowledgeCurrentSource(source)
    let sourceRevision = source.indexRevision
    var evidence: [WikiKnowledgeEvidence] = []
    var unreadable = 0
    var recognitionFailed = false
    switch source.kind {
    case .markdown:
      for section in document.sections {
        let reference = WikiEvidenceReference(workspaceID: workspaceID, document: document, section: section)
        for chunk in try KnowledgeChunks.split(section.sourceText, baseOffset: section.range.lowerBound,
          baseLine: section.range.startLine) {
          evidence.append(try knowledgeEvidence(source: source, sourceIndexRevision: sourceRevision, text: chunk.text,
            location: .markdown(reference: reference, range: chunk.range)))
        }
      }
    case .pdf:
      try WikiPDFExtractor.forEachKnowledgePage(bytes) { page in
        try Task.checkCancellation()
        recognitionFailed = recognitionFailed || page.recognitionFailed
        if page.recognitionFailed || page.imageScanIncomplete || (page.native.extraction == .unreadable && page.regions.isEmpty) {
          unreadable += 1
        }
        if page.includesNative && page.native.extraction == .textLayer {
          evidence += try knowledgePDFBlocks(page.native, source: source, sourceRevision: sourceRevision)
        }
        for region in page.regions {
          evidence += try knowledgePDFBlocks(region.page, source: source, sourceRevision: sourceRevision,
            region: region.identity)
        }
      }
    }
    try requireKnowledgeAccess()
    return WikiKnowledgeMaterial(evidence: evidence, unreadablePages: unreadable, recognitionFailed: recognitionFailed)
  }

  func knowledgePDFBlocks(_ page: WikiPDFPage, source: WikiKnowledgeSource, sourceRevision: String,
    region: WikiPDFEvidenceRegion? = nil) throws -> [WikiKnowledgeEvidence] {
    let pageRevision = SourceDigest.sha256(page.text)
    return try KnowledgeChunks.split(page.text).map { chunk in
      let bounds = KnowledgeChunks.bounds(chunk.range, on: page, overlapping: region != nil)
      guard region == nil || !bounds.isEmpty else { throw WikiError.changedSource }
      return try knowledgeEvidence(source: source, sourceIndexRevision: sourceRevision, text: chunk.text,
        location: .pdf(pageIndex: page.pageIndex, label: page.label, range: chunk.range,
          pageSHA256: pageRevision, bounds: bounds), pdfRegion: region)
    }
  }

  /// The original is the authority, including the owner note's current attachment link.
  /// A self-consistent forged cache quote/hash is insufficient to pass this method.
  public func readKnowledgeEvidence(_ evidence: WikiKnowledgeEvidence) throws -> String {
    try readKnowledgeEvidence([evidence])[0]
  }

  /// Preserves request order. Each source is read once, and each requested PDF
  /// page is extracted once within that source. Files are checked in sequence.
  public func readKnowledgeEvidence(_ evidence: [WikiKnowledgeEvidence]) throws -> [String] {
    try requireKnowledgeAccess()
    guard evidence.count <= 1000 else {
      throw WikiError.invalidSource("Knowledge evidence batches accept at most 1,000 references.")
    }
    let sources = Dictionary(grouping: evidence.indices, by: { evidence[$0].source.indexRevision })
    var result = [String](repeating: "", count: evidence.count)
    for (sourceIndexRevision, offsets) in sources.sorted(by: { $0.value[0] < $1.value[0] }) {
      let source = evidence[offsets[0]].source
      let (document, bytes) = try knowledgeCurrentSource(source)
      switch source.kind {
      case .markdown:
        for offset in offsets {
          result[offset] = try knowledgeVerifiedMarkdownText(evidence[offset], document: document,
            bytes: bytes, sourceIndexRevision: sourceIndexRevision)
        }
      case .pdf:
        var byPage: [Int: [Int]] = [:]
        var enhanced = Set<Int>()
        var mixedImages: [Int: Set<Int>] = [:]
        for offset in offsets {
          guard case .pdf(let pageIndex, _, _, _, _) = evidence[offset].location else { throw WikiError.changedSource }
          byPage[pageIndex, default: []].append(offset)
          if evidence[offset].pdfRegion != nil { enhanced.insert(pageIndex) }
          if let image = evidence[offset].pdfRegion?.imageIndex { mixedImages[pageIndex, default: []].insert(image) }
        }
        try WikiPDFExtractor.forEachKnowledgePage(bytes, pageIndices: Set(byPage.keys), enhancedPages: enhanced,
          mixedImageIndices: mixedImages) { page in
          let pageBytes = Data(page.native.text.utf8)
          let pageRevision = SourceDigest.sha256(pageBytes)
          for offset in byPage[page.native.pageIndex] ?? [] {
            result[offset] = try knowledgeVerifiedPDFText(evidence[offset], page: page,
              nativeBytes: pageBytes, nativeRevision: pageRevision, sourceIndexRevision: sourceIndexRevision)
          }
        }
      }
    }
    try requireKnowledgeAccess()
    return result
  }

  /// The reader displays the same admitted revision that provided the quotation.
  package func previewKnowledgeMarkdown(_ evidence: WikiKnowledgeEvidence) throws -> WikiDocument {
    guard evidence.source.kind == .markdown else { throw WikiError.invalidSource("Markdown 근거가 아닙니다.") }
    let (document, bytes) = try knowledgeCurrentSource(evidence.source)
    _ = try knowledgeVerifiedMarkdownText(evidence, document: document,
      bytes: bytes, sourceIndexRevision: evidence.source.indexRevision)
    try requireKnowledgeAccess()
    return document
  }

  public func previewKnowledgePDF(_ evidence: WikiKnowledgeEvidence) throws -> WikiKnowledgePDFPreview {
    guard case .pdf(let pageIndex, let label, _, _, let bounds) = evidence.location,
      evidence.source.kind == .pdf else { throw WikiError.invalidSource("PDF 근거가 아닙니다.") }
    let (_, bytes) = try knowledgeCurrentSource(evidence.source)
    let mixedImages: [Int: Set<Int>] = evidence.pdfRegion?.imageIndex.map { [pageIndex: [$0]] } ?? [:]
    try WikiPDFExtractor.forEachKnowledgePage(bytes, pageIndices: [pageIndex],
      enhancedPages: evidence.pdfRegion == nil ? [] : [pageIndex], mixedImageIndices: mixedImages) { page in
        let native = Data(page.native.text.utf8)
        _ = try knowledgeVerifiedPDFText(evidence, page: page, nativeBytes: native,
          nativeRevision: SourceDigest.sha256(native), sourceIndexRevision: evidence.source.indexRevision)
      }
    try requireKnowledgeAccess()
    return WikiKnowledgePDFPreview(data: bytes, pageIndex: pageIndex, label: label, bounds: bounds,
      usesOCR: evidence.pdfRegion?.kind == .ocrUnreviewed)
  }

  /// An ordinary Markdown link keeps its existing attachment preview. A saved
  /// quotation must resolve against the recorded evidence before opening a page.
  package func previewSavedKnowledgePDF(notePath: String, noteRevision: String,
    attachmentPath: String, pageIndex: Int, evidenceID: String? = nil
  ) throws -> WikiKnowledgePDFPreview? {
    guard let saved = try savedKnowledgeEvidence(notePath: notePath, noteRevision: noteRevision) else {
      if evidenceID != nil { throw WikiError.changedSource }
      return nil
    }
    let matches = saved.filter { evidence in
      guard evidence.source.kind == .pdf, evidence.source.relativePath.utf8.elementsEqual(attachmentPath.utf8),
        case .pdf(let index, _, _, _, _) = evidence.location else { return false }
      return index == pageIndex && (evidenceID.map { evidence.id == $0 } ?? (evidence.pdfRegion == nil))
    }
    guard let first = matches.first else { throw WikiError.changedSource }
    let preview = try previewKnowledgePDF(first)
    if evidenceID != nil || matches.count == 1 { return preview }
    // A page-only link is shared by several quotations on that page.
    return WikiKnowledgePDFPreview(data: preview.data, pageIndex: preview.pageIndex, label: preview.label, bounds: [])
  }

  /// An older, fragmentless link opens only when it identifies one recorded quotation.
  package func previewSavedKnowledgeMarkdown(notePath: String, noteRevision: String, sourcePath: String,
    fragment: String?
  ) throws -> (document: WikiDocument, sectionID: String, location: String)? {
    guard fragment?.hasPrefix(WikiKnowledgeLocation.markdownCitationPrefix) ?? true else { return nil }
    let saved = try savedKnowledgeEvidence(notePath: notePath, noteRevision: noteRevision) ?? []
    let matches = saved.filter { evidence in
      evidence.source.kind == .markdown && evidence.source.relativePath.utf8.elementsEqual(sourcePath.utf8)
        && (fragment == nil || evidence.location.savedCitationFragment == fragment)
    }
    guard let evidence = matches.first else {
      if fragment == nil { return nil }
      throw WikiError.changedSource
    }
    guard let reference = evidence.markdownReference, matches.allSatisfy({ $0.id == evidence.id }) else {
      throw WikiError.changedSource
    }
    return (try previewKnowledgeMarkdown(evidence), reference.sectionID, evidence.displayLocation)
  }

  private func savedKnowledgeEvidence(notePath: String, noteRevision: String) throws -> [WikiKnowledgeEvidence]? {
    try requireKnowledgeAccess()
    let note = try knowledgeRead(path: notePath, maximumBytes: 256 * 1024)
    guard SourceDigest.sha256(note) == noteRevision else { throw WikiError.changedSource }
    let ontology = try WikiOntologyRecord.read(bytes: note)
    if let ontology {
      guard try WikiMarkdownParser.isDerivedKnowledgeNote(bytes: note),
        try WikiMarkdownParser.document(relativePath: notePath, bytes: note).stableID == ontology.recordID else {
        throw WikiError.changedSource
      }
      let evidence = try WikiKnowledgeRecordPayload.decode(ontology).evidence
      // If both formats are present they must identify the same exact quotations.
      if let legacy = try WikiMarkdownParser.knowledgeNoteProvenance(bytes: note, required: false) {
        guard try Self.savedLegacyEvidence(legacy) == evidence else { throw WikiError.changedSource }
      }
      return evidence
    }
    guard let data = try WikiMarkdownParser.knowledgeNoteProvenance(bytes: note) else { return nil }
    return try Self.savedLegacyEvidence(data)
  }

  private static func savedLegacyEvidence(_ data: Data) throws -> [WikiKnowledgeEvidence] {
    struct SavedEvidence: Decodable {
      struct Entry: Decodable { let evidence: WikiKnowledgeEvidence }
      let version: Int
      let evidence: [Entry]
    }
    let saved = try JSONDecoder().decode(SavedEvidence.self, from: data)
    guard saved.version == 1 else { throw WikiError.changedSource }
    return saved.evidence.map(\.evidence)
  }

  private func knowledgeVerifiedMarkdownText(_ evidence: WikiKnowledgeEvidence, document: WikiDocument,
    bytes: Data, sourceIndexRevision: String
  ) throws -> String {
    guard evidence.pdfRegion == nil, case .markdown(let reference, let range) = evidence.location,
      let section = document.sections.first(where: { $0.id == reference.sectionID }),
      reference == WikiEvidenceReference(workspaceID: workspaceID, document: document, section: section),
      range.lowerBound >= section.range.lowerBound, range.upperBound <= section.range.upperBound else {
      throw WikiError.changedSource
    }
    let actual = try KnowledgeChunks.text(range, bytes: bytes)
    return try knowledgeVerifiedText(evidence, actual: actual, sourceIndexRevision: sourceIndexRevision)
  }

  private func knowledgeVerifiedPDFText(_ evidence: WikiKnowledgeEvidence, page: WikiPDFKnowledgePage,
    nativeBytes: Data, nativeRevision: String, sourceIndexRevision: String
  ) throws -> String {
    let representation: WikiPDFPage
    let pageBytes: Data
    let pageRevision: String
    if let region = evidence.pdfRegion {
      guard let matched = page.regions.first(where: { $0.identity == region }) else { throw WikiError.changedSource }
      representation = matched.page
      pageBytes = Data(representation.text.utf8)
      pageRevision = SourceDigest.sha256(pageBytes)
    } else {
      representation = page.native
      guard representation.extraction == .textLayer else { throw WikiError.changedSource }
      pageBytes = nativeBytes
      pageRevision = nativeRevision
    }
    guard case .pdf(let index, let label, let range, let hash, let bounds) = evidence.location,
      index == representation.pageIndex, representation.label.utf8.elementsEqual(label.utf8), pageRevision == hash,
      evidence.pdfRegion == nil || !bounds.isEmpty,
      bounds == KnowledgeChunks.bounds(range, on: representation, overlapping: evidence.pdfRegion != nil) else {
      throw WikiError.changedSource
    }
    let actual = try KnowledgeChunks.text(range, bytes: pageBytes)
    return try knowledgeVerifiedText(evidence, actual: actual, sourceIndexRevision: sourceIndexRevision)
  }

  private func knowledgeVerifiedText(_ evidence: WikiKnowledgeEvidence, actual: String,
    sourceIndexRevision: String
  ) throws -> String {
    try Task.checkCancellation()
    guard actual.utf8.elementsEqual(evidence.text.utf8), !actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      try knowledgeEvidence(source: evidence.source, sourceIndexRevision: sourceIndexRevision,
        text: actual, location: evidence.location, pdfRegion: evidence.pdfRegion).id == evidence.id else {
      throw WikiError.changedSource
    }
    return actual
  }

  func knowledgeCurrentSource(_ source: WikiKnowledgeSource) throws -> (WikiDocument, Data) {
    try requireKnowledgeAccess()
    // Previously saved evidence remains usable at exactly its original paths.
    guard source.scopeID == knowledgeScopeID
      || (managedLocalKnowledgeNamespace != nil && source.scopeID == pathKnowledgeScopeID) else {
      throw WikiError.changedSource
    }
    let ownerBytes = try knowledgeRead(path: source.documentPath, maximumBytes: 256 * 1024)
    guard try WikiMarkdownParser.isDerivedKnowledgeNote(bytes: ownerBytes) == false else { throw WikiError.changedSource }
    let document = try WikiMarkdownParser.document(relativePath: source.documentPath, bytes: ownerBytes)
    guard source.documentID == document.id, source.documentRevision == document.revision else { throw WikiError.changedSource }
    let bytes: Data
    switch source.kind {
    case .markdown:
      guard source.relativePath == document.relativePath else { throw WikiError.changedSource }
      bytes = ownerBytes
    case .pdf:
      guard knowledgePDFLinks(document).contains(source.relativePath) else { throw WikiError.changedSource }
      bytes = try knowledgeRead(path: source.relativePath, maximumBytes: 50 * 1024 * 1024)
    }
    let revision = source.kind == .markdown ? document.revision : SourceDigest.sha256(bytes)
    let current = knowledgeSource(document, path: source.relativePath, revision: revision,
      kind: source.kind, scope: source.scopeID)
    guard current.indexRevision == source.indexRevision else {
      throw WikiError.changedSource
    }
    return (document, bytes)
  }

  func requireKnowledgeAccess() throws {
    try Task.checkCancellation()
    try requireOpen()
    guard NSFileVersion.unresolvedConflictVersionsOfItem(at: root.appendingPathComponent("_workspace.md"))?.isEmpty != false else {
      throw WikiError.conflict("_workspace.md")
    }
  }

  func knowledgeRead(path: String, maximumBytes: Int) throws -> Data {
    let path = try WikiPath.validate(path)
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    guard (path != "_workspace.md" && path != "_ontology.md" && ["md", "markdown"].contains(ext))
      || (path.hasPrefix("attachments/") && ext == "pdf") else {
      throw WikiError.invalidPath(path)
    }
    guard NSFileVersion.unresolvedConflictVersionsOfItem(at: root.appendingPathComponent(path))?.isEmpty != false else {
      throw WikiError.conflict(path)
    }
    return try CoordinatedFiles.read(root: root, path: path, maximumBytes: maximumBytes)
  }

  private func knowledgePDFLinks(_ document: WikiDocument) -> Set<String> {
    Set(document.declarations.compactMap { declaration in
      guard declaration.origin == .markdownLink,
        let path = WikiPath.resolveLink(declaration.target, from: document.relativePath), path.hasPrefix("attachments/"),
        URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" else { return nil }
      return path
    })
  }

  private func knowledgeSource(_ document: WikiDocument, path: String, revision: String,
    kind: WikiKnowledgeSource.Kind, scope: String) -> WikiKnowledgeSource {
    let id = SourceDigest.sha256((try? JSONEncoder().encode([scope, document.id, path, kind.rawValue])) ?? Data())
    let title: String
    if kind == .pdf {
      let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
      let suffix = name.dropFirst(36)
      if UUID(uuidString: String(name.prefix(36))) != nil, suffix.first == "-", suffix.count > 1 {
        title = String(suffix.dropFirst())
      } else { title = name }
    } else { title = document.title }
    return WikiKnowledgeSource(id: id, scopeID: scope, title: title, relativePath: path,
      documentID: document.id, documentPath: document.relativePath, documentRevision: document.revision,
      revision: revision, kind: kind)
  }

  private func knowledgeEvidence(source: WikiKnowledgeSource, sourceIndexRevision: String, text: String,
    location: WikiKnowledgeLocation, pdfRegion: WikiPDFEvidenceRegion? = nil) throws -> WikiKnowledgeEvidence {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    var identity = Data(sourceIndexRevision.utf8)
    identity.append(try encoder.encode(location))
    if let pdfRegion { identity.append(try encoder.encode(pdfRegion)) }
    identity.append(contentsOf: text.utf8)
    return WikiKnowledgeEvidence(id: SourceDigest.sha256(identity), text: text, source: source,
      location: location, pdfRegion: pdfRegion)
  }
}

extension WikiKnowledgeLocation {
  package static let markdownCitationPrefix = "folio-quote="

  package var savedCitationFragment: String {
    switch self {
    case .markdown(_, let range): Self.markdownCitationPrefix + "\(range.lowerBound)-\(range.upperBound)"
    case .pdf(let pageIndex, _, _, _, _): "page=\(pageIndex + 1)"
    }
  }
}

extension WikiKnowledgeEvidence {
  /// One formatter for saved quotation notes and Concept records, including nested note paths.
  package func savedCitationMarkdown(from notePath: String) throws -> String {
    let path = try WikiPath.validate(notePath)
    guard path.hasPrefix("notes/") else { throw WikiError.invalidPath(path) }
    let label = WikiMarkdownEditor.literalInline(source.title + " · " + displayLocation)
    let parentDepth = path.split(separator: "/").count - 1
    let relative = String(repeating: "../", count: max(0, parentDepth - 1))
      + (try WikiPath.linkFromNotesDirectory(to: source.relativePath))
    var fragment = location.savedCitationFragment
    if pdfRegion != nil { fragment += "&folio-quote=" + id }
    let quote = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map { "> " + WikiMarkdownEditor.literalInline(String($0)) }.joined(separator: "\n")
    return "## [" + label + "](" + relative + "#" + fragment + ")\n\n" + quote
  }
}

/// Byte-preserving chunks; no Unicode normalization, silent clipping or fabricated overlap.
private enum KnowledgeChunks {
  struct Chunk { let text: String; let range: WikiSourceRange }
  static func split(_ text: String, baseOffset: Int = 0, baseLine: Int = 1) throws -> [Chunk] {
    var output: [Chunk] = []
    var pending = ""; var offset = baseOffset; var line = baseLine
    func append() {
      let nextLine = line + lineBreakCount(pending.utf8)
      if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        output.append(Chunk(text: pending, range: WikiSourceRange(lowerBound: offset,
          upperBound: offset + pending.utf8.count, startLine: line, endLine: nextLine - trailingBreak(pending))))
      }
      offset += pending.utf8.count; line = nextLine; pending = ""
    }
    for character in text {
      try Task.checkCancellation()
      let next = String(character)
      if pending.utf8.count + next.utf8.count > 1200 { append() }
      // A single malicious grapheme may itself be enormous. Preserve it as one
      // explicit storage-limit error rather than dropping original bytes.
      pending += next
      if pending.utf8.count >= 800 && (character.isWhitespace || character == "." || character == "。") { append() }
    }
    append()
    return output
  }
  static func text(_ range: WikiSourceRange, bytes: Data) throws -> String {
    let slice = try range.extract(from: bytes)
    let text = String(decoding: slice, as: UTF8.self)
    guard slice.elementsEqual(text.utf8) else {
      throw WikiError.invalidSource("원문 구간이 올바른 UTF-8이 아닙니다.")
    }
    let start = 1 + lineBreakCount(bytes.prefix(range.lowerBound))
    guard start == range.startLine, range.endLine == start + lineBreakCount(text.utf8) - trailingBreak(text) else {
      throw WikiError.changedSource
    }
    return text
  }
  private static func trailingBreak(_ text: String) -> Int {
    text.utf8.last == 10 || text.utf8.last == 13 ? 1 : 0
  }
  private static func lineBreakCount(_ bytes: some Sequence<UInt8>) -> Int {
    var count = 0; var previousWasCR = false
    for byte in bytes {
      if byte == 13 || (byte == 10 && !previousWasCR) { count += 1 }
      previousWasCR = byte == 13
    }
    return count
  }
  static func bounds(_ range: WikiSourceRange, on page: WikiPDFPage, overlapping: Bool = false) -> [WikiPDFBounds] {
    page.regions.compactMap { region in
      guard let location = region.byteRange else { return nil }
      let matches = overlapping ? location.lowerBound < range.upperBound && location.upperBound > range.lowerBound
        : location.lowerBound >= range.lowerBound && location.upperBound <= range.upperBound
      guard matches else { return nil }
      return region.bounds
    }
  }
}
