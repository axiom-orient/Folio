import Foundation
import FolioKnowledge

/// Owns only a rebuildable index and query coordination. Source reads and final
/// quotation checks remain on WikiWorkspace; models never acquire write access.
public actor WikiKnowledgeQuery {
  private static let markdownProducer = "folio.knowledge.v1." + WikiPDFExtractor.identifier + ".chunks.bytes800-1200.v2"
  private static let pdfProducer = markdownProducer + ".regions.v1." + WikiPDFOCR.identifier
    + "." + WikiPDFOCR.regionalIdentifier + "." + ProcessInfo.processInfo.operatingSystemVersionString
  private let workspace: WikiWorkspace
  private let embedding: (any WikiSemanticEmbedding)?
  private let relevance: (any WikiSemanticRelevance)?
  private var busy = false
  private var releaseWhenIdle = false

  private struct Envelope: Codable {
    let source: WikiKnowledgeSource
    let unreadablePages: Int
  }
  private struct Vector: Codable { let vector: [Double] }
  private struct Prepared {
    let inventory: WikiKnowledgeInventory
    let records: [String: Envelope]
    let indexingFailures: [String: String]
    let storeID: String
  }
  private struct DenseCandidate {
    let evidence: WikiKnowledgeEvidence
    let anchor: Anchor
    let similarity: Double
  }
  /// The same PDF can be linked by several notes. Keep ownership on the
  /// citation we publish, but count an original location only once when ranking.
  private struct Anchor: Hashable {
    let path: String
    let revision: String
    let location: WikiKnowledgeLocation

    init(_ evidence: WikiKnowledgeEvidence) {
      path = evidence.source.relativePath
      revision = evidence.source.revision
      location = evidence.location
    }
  }

  public init(workspace: WikiWorkspace, embedding: (any WikiSemanticEmbedding)? = nil,
    relevance: (any WikiSemanticRelevance)? = nil
  ) {
    self.workspace = workspace; self.embedding = embedding; self.relevance = relevance
  }

  public func prepare() async throws -> WikiKnowledgeCoverage {
    try begin()
    defer { finish() }
    let prepared = try await prepareIndex()
    let coverage = try await coverage(of: prepared)
    try await validate(prepared)
    return coverage
  }

  public func answer(_ question: String, documentID: String? = nil,
    useSemantic: Bool = false
  ) async throws -> WikiKnowledgeAnswer {
    try begin()
    defer { finish() }
    guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      question.utf8.count <= 8_192, !question.contains("\0"),
      documentID.map({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }) ?? true else {
      throw WikiError.invalidSource("질문은 비어 있지 않은 8,192 UTF-8 bytes 이하 문자열이어야 합니다.")
    }
    if useSemantic, embedding == nil || relevance == nil {
      throw WikiError.unavailable("뜻으로 찾기에는 검색 모델과 관련성 검사 모델이 모두 필요합니다.")
    }
    let prepared = try await prepareIndex()
    if let documentID, !prepared.inventory.admittedDocumentIDs.contains(documentID) {
      throw WikiError.invalidSource("선택한 자료가 현재 자료함에 없습니다.")
    }
    let scope = documentID.map { selected in
      Set(prepared.inventory.sources.filter { $0.documentID == selected }.map(\.id))
    }
    let coverage = try await coverage(of: prepared, scope: scope)
    let indexedScope = scope.map { Set(prepared.records.keys).intersection($0) }
    let lexicalBlocks = try await workspace.projection.searchKnowledgeBlocks(question, sourceIDs: indexedScope, limit: 60)
    var seenAnchors = Set<Anchor>()
    let lexical = try lexicalBlocks.compactMap { block -> WikiKnowledgeEvidence? in
      let evidence = try Self.evidence(block, records: prepared.records)
      return seenAnchors.insert(Anchor(evidence)).inserted ? evidence : nil
    }
    var diagnostics = coverage.diagnostics
    var semanticComplete = false
    let selected: [WikiKnowledgeEvidence]
    if useSemantic, let embedding, let relevance {
      guard (1...2_048).contains(embedding.dimensions) else {
        throw WikiError.invalidSource("검색 벡터 크기는 1...2,048이어야 합니다.")
      }
      // These are the existing E5-small + mMARCO MiniLM rejection thresholds,
      // not a model-independent probability or factual accuracy guarantee.
      if !embedding.identifier.hasPrefix("multilingual-e5-small.") || !relevance.identifier.hasPrefix("mmarco-minilm.") {
        diagnostics.append("의미 검색 임계값은 E5-small·mMARCO MiniLM 기준입니다. 다른 모델의 품질은 별도 보정이 필요합니다.")
      }
      let queryVector = try await embedding.vector(for: question, role: .query)
      try await checkAdmission()
      guard let normalizedQuery = Self.normalized(queryVector), normalizedQuery.count == embedding.dimensions else {
        throw WikiError.invalidSource("검색 모델이 올바르지 않은 질문 벡터를 반환했습니다.")
      }
      let pipeline = "knowledge.vector.v1." + SourceDigest.sha256(try Self.json([
        Self.markdownProducer, embedding.identifier, relevance.identifier, "normalized-dot.075.rerank.-3.gap2"
      ]))
      var candidates: [DenseCandidate] = []
      var cursor: Int64 = 0
      var skipped = 0
      while true {
        try Task.checkCancellation()
        let page = try await workspace.projection.knowledgeBlockPage(afterRowID: cursor, limit: 256, sourceIDs: indexedScope)
        guard let last = page.last else { break }
        for row in page {
          try Task.checkCancellation()
          let evidence = try Self.evidence(row.block, records: prepared.records)
          let vector: [Double]
          if row.block.vectorModelID == pipeline, let json = row.block.vectorJSON,
            let stored = try? JSONDecoder().decode(Vector.self, from: Data(json.utf8)),
            stored.vector.count == embedding.dimensions, let valid = Self.normalized(stored.vector) {
            vector = valid
          } else {
            let generated: [Double]
            do {
              generated = try await embedding.vector(for: row.block.text, role: .passage)
              try await checkAdmission()
            } catch WikiSemanticEmbeddingError.tokenBudget {
              try await checkAdmission()
              skipped += 1; continue
            }
            guard generated.count == embedding.dimensions, let valid = Self.normalized(generated) else {
              throw WikiError.invalidSource("검색 모델이 올바르지 않은 자료 벡터를 반환했습니다.")
            }
            vector = valid
            guard try await workspace.projection.storeKnowledgeVector(blockID: row.block.id,
              modelID: pipeline, valueJSON: Self.json(Vector(vector: vector))) else { throw WikiError.changedSource }
          }
          let score = zip(normalizedQuery, vector).reduce(0.0) { $0 + $1.0 * $1.1 }
          if score >= WikiLocalSemanticSearch.minimumCandidateSimilarity {
            let anchor = Anchor(evidence)
            if let existing = candidates.firstIndex(where: { $0.anchor == anchor }) {
              let previous = candidates[existing]
              guard score > previous.similarity || (score == previous.similarity && evidence.id < previous.evidence.id) else { continue }
              candidates.remove(at: existing)
            }
            candidates.append(DenseCandidate(evidence: evidence, anchor: anchor, similarity: score))
            candidates.sort { $0.similarity == $1.similarity ? $0.evidence.id < $1.evidence.id : $0.similarity > $1.similarity }
            if candidates.count > WikiLocalSemanticSearch.maximumRelevanceCandidates { candidates.removeLast() }
          }
        }
        cursor = last.rowID
      }
      semanticComplete = skipped == 0 && coverage.complete
      if skipped > 0 { diagnostics.append("의미 검색에서 토큰 한도를 넘은 \(skipped)개 구간은 제외했습니다. 원문 검색은 유지됩니다.") }
      let pool = Self.relevanceCandidates(lexical: lexical, dense: candidates.map(\.evidence))
      let passages = pool.map(\.text)
      let scores: [Double?]
      if passages.isEmpty { scores = [] }
      else {
        scores = try await relevance.scores(query: question, passages: passages)
        try await checkAdmission()
      }
      guard scores.count == pool.count, scores.compactMap({ $0 }).allSatisfy(\.isFinite) else {
        throw WikiError.invalidSource("관련성 검사 모델이 올바르지 않은 점수를 반환했습니다.")
      }
      if scores.contains(where: { $0 == nil }) {
        semanticComplete = false
        diagnostics.append("일부 후보를 관련성 검사하지 못했습니다. 검사하지 않은 후보는 결과에 포함하지 않습니다.")
      }
      var ranked = scores.enumerated().compactMap { rank, score -> (rank: Int, score: Double)? in
        guard let score, score >= WikiLocalSemanticSearch.minimumRelevanceScore else { return nil }
        return (rank, score)
      }
      ranked.sort { $0.score == $1.score ? $0.rank < $1.rank : $0.score > $1.score }
      if let best = ranked.first?.score {
        ranked.removeAll { $0.score < best - WikiLocalSemanticSearch.maximumRelevanceGap }
      }
      selected = ranked.prefix(10).map { pool[$0.rank] }
    } else {
      selected = Array(lexical.prefix(10))
    }
    if !selected.isEmpty {
      _ = try await workspace.readKnowledgeEvidence(selected)
    }
    // Source checks are segmented, not an atomic multi-file snapshot. Recheck
    // the entire admitted corpus before publishing, including unrelated files.
    try await validate(prepared)
    let resultCoverage = WikiKnowledgeCoverage(sourceCount: coverage.sourceCount,
      blockCount: coverage.blockCount, unreadablePages: coverage.unreadablePages,
      complete: coverage.complete, semanticComplete: semanticComplete, diagnostics: diagnostics)
    return WikiKnowledgeAnswer(question: question, evidence: selected, coverage: resultCoverage,
      semanticUsed: useSemantic, documentID: documentID)
  }

  /// Compare rank positions rather than mixing incomparable BM25 and cosine
  /// scores. Both paths contribute within MiniLM's one-request candidate budget.
  private static func relevanceCandidates(lexical: [WikiKnowledgeEvidence], dense: [WikiKnowledgeEvidence]) -> [WikiKnowledgeEvidence] {
    let rankConstant = 60.0
    var candidates: [Anchor: (evidence: WikiKnowledgeEvidence, weight: Double)] = [:]
    for list in [lexical, dense] {
      for (rank, evidence) in list.enumerated() {
        let key = Anchor(evidence)
        let weight = 1.0 / (rankConstant + Double(rank + 1))
        if let previous = candidates[key] { candidates[key] = (previous.evidence, previous.weight + weight) }
        else { candidates[key] = (evidence, weight) }
      }
    }
    return candidates.values.sorted {
      $0.weight == $1.weight ? $0.evidence.id < $1.evidence.id : $0.weight > $1.weight
    }.prefix(WikiLocalSemanticSearch.maximumRelevanceCandidates).map(\.evidence)
  }

  public func releaseResources() async {
    guard !busy else { releaseWhenIdle = true; return }
    busy = true
    releaseWhenIdle = false
    defer { finish() }
    await embedding?.releaseResources()
    await relevance?.releaseResources()
  }

  private func begin() throws {
    try Task.checkCancellation()
    guard !busy else { throw WikiError.unavailable("자료를 준비하거나 검색하고 있습니다. 잠시 후 다시 시도해 주세요.") }
    busy = true
  }

  private func finish() {
    busy = false
    if releaseWhenIdle { Task { await self.releaseResources() } }
  }

  private func prepareIndex() async throws -> Prepared {
    let storeID = try await workspace.projection.storeID()
    let inventory = try await workspace.knowledgeInventory()
    let previous = try await workspace.projection.knowledgeDocuments()
    let cached = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var records: [String: Envelope] = [:]
    var indexingFailures: [String: String] = [:]
    for source in inventory.sources {
      try Task.checkCancellation()
      let producer = source.kind == .pdf ? Self.pdfProducer : Self.markdownProducer
      if let record = cached[source.id], record.revision == source.indexRevision, record.producer == producer,
        let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(record.payload.utf8)),
        envelope.source == source, envelope.unreadablePages >= 0 {
        records[source.id] = envelope
        continue
      }
      do {
        let material = try await workspace.knowledgeBlocks(for: source)
        let blocks = try material.evidence.enumerated().map { ordinal, evidence in
          guard evidence.source == source else { throw WikiError.changedSource }
          return WikiKnowledgeBlockRecord(id: evidence.id, sourceID: source.id, ordinal: ordinal,
            text: evidence.text, payload: try Self.json(evidence))
        }
        let envelope = Envelope(source: source, unreadablePages: material.unreadablePages)
        // A transient OCR failure must not hide the file's readable pages or
        // make that incomplete extraction a reusable index for later searches.
        let record = WikiKnowledgeDocumentRecord(id: source.id, revision: source.indexRevision,
          producer: material.recognitionFailed ? producer + ".retry-ocr" : producer, payload: try Self.json(envelope))
        try await workspace.projection.replaceKnowledgeDocument(record, blocks: blocks)
        records[source.id] = envelope
      } catch is CancellationError { throw CancellationError() }
      catch WikiError.changedSource { throw WikiError.changedSource }
      catch { indexingFailures[source.id] = "\(source.title): 자료를 준비할 수 없습니다. \(error.localizedDescription)" }
    }
    if !Set(cached.keys).isSubset(of: records.keys) {
      try await workspace.projection.retainKnowledgeDocuments(Set(records.keys))
    }
    return Prepared(inventory: inventory, records: records, indexingFailures: indexingFailures, storeID: storeID)
  }

  private func coverage(of prepared: Prepared, scope: Set<String>? = nil) async throws -> WikiKnowledgeCoverage {
    let records = prepared.records.filter { scope?.contains($0.key) ?? true }
    var unreadable = 0
    for record in records.values {
      let sum = unreadable.addingReportingOverflow(record.unreadablePages)
      guard !sum.overflow else { throw WikiError.database("Invalid cached PDF coverage; rebuild the projection.") }
      unreadable = sum.partialValue
    }
    let count = try await workspace.projection.knowledgeBlockCount(sourceIDs: scope.map { _ in Set(records.keys) })
    // Inventory failures can hide an entire source before it has a source ID.
    // Keep those shared diagnostics rather than promising complete scoped results.
    var diagnostics = prepared.inventory.diagnostics
    diagnostics += prepared.indexingFailures.filter { scope?.contains($0.key) ?? true }.values.sorted()
    if unreadable > 0 { diagnostics.append("글자를 모두 읽지 못한 PDF 페이지가 \(unreadable)쪽 있습니다.") }
    return WikiKnowledgeCoverage(sourceCount: records.count, blockCount: count,
      unreadablePages: unreadable, complete: diagnostics.isEmpty,
      semanticComplete: false, diagnostics: diagnostics)
  }

  private func checkAdmission() async throws {
    try Task.checkCancellation()
    try await workspace.requireOpen()
  }

  private func validate(_ prepared: Prepared) async throws {
    try await checkAdmission()
    guard try await workspace.knowledgeInventory().fingerprint == prepared.inventory.fingerprint,
      try await workspace.projection.storeID() == prepared.storeID else { throw WikiError.changedSource }
    try await checkAdmission()
  }

  private static func evidence(_ block: WikiKnowledgeBlockRecord,
    records: [String: Envelope]
  ) throws -> WikiKnowledgeEvidence {
    guard let source = records[block.sourceID]?.source,
      let evidence = try? JSONDecoder().decode(WikiKnowledgeEvidence.self, from: Data(block.payload.utf8)),
      evidence.id == block.id, evidence.source == source, evidence.text == block.text else {
      throw WikiError.database("자료 색인이 원문 정보와 일치하지 않아 결과를 표시할 수 없습니다.")
    }
    return evidence
  }

  private static func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private static func normalized(_ values: [Double]) -> [Double]? {
    guard !values.isEmpty, values.allSatisfy(\.isFinite), let scale = values.map({ abs($0) }).max(), scale > 0 else { return nil }
    let scaled = values.map { $0 / scale }
    let norm = sqrt(scaled.reduce(0) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0 else { return nil }
    return scaled.map { $0 / norm }
  }
}
