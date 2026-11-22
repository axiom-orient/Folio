import Foundation
import FolioKnowledge

public struct WikiSemanticMatch: Codable, Sendable, Identifiable {
  public var id: String { reference.sectionID }
  public let title: String
  public let excerpt: String
  public let similarity: Double
  public let reference: WikiEvidenceReference
  public let relevanceScore: Double?
}

public struct WikiSemanticSearchReport: Codable, Sendable {
  public let atomicSnapshot: Bool
  public let modelID: String
  public let matches: [WikiSemanticMatch]
  public let sourceRevision: String
  public let coverageComplete: Bool
  public let indexComplete: Bool
  public let indexedSections: Int
  public let cachedSections: Int
  public let vectorBytes: Int
  public let diagnostics: [WikiDiagnostic]
  public let relevanceComplete: Bool?
  public let relevanceCheckedCandidates: Int?
}

/// Opt-in multilingual retrieval. The optional provider owns the model; this
/// actor owns source validation, derived-cache identity, budgets and rejection.
public actor WikiLocalSemanticSearch {
  public static let minimumSimilarity = 0.83
  public static let maximumScoreGap = 0.015
  public static let minimumCandidateSimilarity = 0.75
  public static let minimumRelevanceScore = -3.0
  public static let maximumRelevanceGap = 2.0
  public static let maximumRelevanceCandidates = 20
  public static let maximumSections = 512
  private let embedding: (any WikiSemanticEmbedding)?
  private let relevance: (any WikiSemanticRelevance)?
  private var isSearching = false
  private var releaseWhenIdle = false
  private struct CachedVector: Codable { let vector: [Double] }

  public init(embedding: (any WikiSemanticEmbedding)? = nil, relevance: (any WikiSemanticRelevance)? = nil) {
    self.embedding = embedding; self.relevance = relevance
  }

  public func releaseResources() async {
    guard !isSearching else { releaseWhenIdle = true; return }
    releaseWhenIdle = false
    await embedding?.releaseResources()
    await relevance?.releaseResources()
  }

  public func search(workspace: WikiWorkspace, query: String, limit: Int = 10,
    language: String = "auto", filter: WikiDocumentFilter = .init(), documentIDs: Set<String>? = nil, purpose: WikiSemanticPurpose = .retrieval
  ) async throws -> WikiSemanticSearchReport {
    try Task.checkCancellation()
    guard !isSearching else { throw WikiError.unavailable("의미 검색이 진행 중입니다. 잠시 후 다시 시도해 주세요.") }
    isSearching = true
    defer {
      isSearching = false
      if releaseWhenIdle { Task { await self.releaseResources() } }
    }
    guard ["auto", "en", "ko"].contains(language) else { throw WikiError.invalidSource("Supported search languages: auto, ko, en.") }
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      query.utf8.count <= 512, !query.contains("\0"), (1...20).contains(limit) else {
      throw WikiError.invalidSource("Expected a query up to 512 bytes and limit 1...20.")
    }
    try filter.validate()
    try await workspace.requireOpen()
    guard let embedding else { throw WikiError.unavailable("다국어 의미 검색 모델이 연결되지 않았습니다. 기본 검색은 계속 사용할 수 있습니다.") }
    if purpose == .retrieval, relevance == nil {
      throw WikiError.unavailable("관련성 검사 모델이 연결되지 않았습니다. 기본 검색을 사용해 주세요.")
    }
    guard (1...2048).contains(embedding.dimensions) else { throw WikiError.invalidSource("Embedding dimensions exceed the supported budget.") }
    guard let queryVector = Self.normalized(try await embedding.vector(for: query, role: .query)),
      queryVector.count == embedding.dimensions else { throw WikiError.invalidSource("Invalid query vector.") }
    let modelID = embedding.identifier + ".source-p3." + purpose.rawValue
      + (purpose == .retrieval ? ".joint1." + (relevance?.identifier ?? "") : "")
    let producer = Self.cacheProducer(modelID: modelID, purpose: purpose)
    let snapshot = try await workspace.refresh()
    let epoch = try WikiSearchEpoch.revision(snapshot)
    let items = snapshot.documents.filter { filter.matches($0) && (documentIDs?.contains($0.id) ?? true) }.flatMap { doc in doc.sections.map { (doc, $0) } }
    let selected = Array(items.prefix(Self.maximumSections))
    try await workspace.projection.removeLegacySemanticValues()
    try await workspace.projection.retainDerivedProducer(producer, namespace: "folio.semantic/" + purpose.rawValue + "/")
    let cache = try await workspace.projection.derivedValues(producer: producer, subjects: Set(selected.map { $0.1.id }))
    let cached = Dictionary(cache.map { ($0.subjectID, $0) }, uniquingKeysWith: { first, _ in first })
    var matches: [WikiSemanticMatch] = []
    var passageTexts: [String: String] = [:]
    var indexed = 0; var reused = 0; var bytes = 0; var diagnostics = snapshot.diagnostics
    var skipped = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    for (doc, section) in selected {
      try Task.checkCancellation()
      if ContinuousClock.now >= deadline { break }
      guard section.searchText.utf8.count <= 8192 else { skipped += 1; continue }
      let inputHash = SourceDigest.sha256(section.searchText)
      let vector: [Double]
      if let value = cached[section.id], value.sourceRevision == doc.revision, value.inputHash == inputHash,
        let decoded = try? JSONDecoder().decode(CachedVector.self, from: Data(value.valueJSON.utf8)),
        decoded.vector.count == queryVector.count, let valid = Self.normalized(decoded.vector) {
        vector = valid; reused += 1
      } else {
        let generated: [Double]?
        do { generated = Self.normalized(try await embedding.vector(for: section.sourceText, role: purpose == .similarity ? .query : .passage)) }
        catch WikiSemanticEmbeddingError.tokenBudget {
          skipped += 1; diagnostics.append(.init(path: doc.relativePath, reason: "semantic_token_budget: section exceeds 512 tokens")); continue
        }
        guard let generated, generated.count == queryVector.count else { skipped += 1; continue }
        vector = generated
        let json = String(decoding: try JSONEncoder().encode(CachedVector(vector: vector)), as: UTF8.self)
        try await workspace.requireOpen()
        guard try await workspace.projection.storeDerivedValue(.init(subjectID: section.id, sourceRevision: doc.revision,
          inputHash: inputHash, valueJSON: json), producer: producer) else { throw WikiError.changedSource }
      }
      indexed += 1; bytes += vector.count * MemoryLayout<Double>.size
      let score = zip(queryVector, vector).reduce(0.0) { $0 + $1.0 * $1.1 }
      if score >= (purpose == .retrieval ? Self.minimumCandidateSimilarity : Self.minimumSimilarity) {
        passageTexts[section.id] = section.sourceText
        matches.append(.init(title: doc.title, excerpt: String(section.sourceText.prefix(1000)), similarity: score,
          reference: WikiEvidenceReference(workspaceID: snapshot.workspace.id, document: doc, section: section), relevanceScore: nil))
      }
      // Permit cooperative cancellation even on a warm in-memory cache.
      if indexed.isMultiple(of: 8) { await Task.yield() }
    }
    matches.sort { $0.similarity == $1.similarity ? $0.id < $1.id : $0.similarity > $1.similarity }
    var relevanceComplete: Bool?; var checked: Int?
    if purpose == .retrieval, let relevance {
      let candidates = Array(matches.prefix(Self.maximumRelevanceCandidates))
      let passages = try candidates.map { match in
        guard let text = passageTexts[match.id] else { throw WikiError.changedSource }
        return text
      }
      let scores = try await relevance.scores(query: query, passages: passages)
      guard scores.count == candidates.count, scores.compactMap({ $0 }).allSatisfy(\.isFinite) else {
        throw WikiError.invalidSource("Invalid relevance scores.")
      }
      checked = scores.compactMap { $0 }.count; relevanceComplete = checked == candidates.count
      if relevanceComplete == false { diagnostics.append(.init(path: "", reason: "semantic_relevance_partial: 512 pair tokens, 5 seconds scoring budget")) }
      matches = zip(candidates, scores).compactMap { match, score in
        guard let score, score >= Self.minimumRelevanceScore else { return nil }
        return .init(title: match.title, excerpt: match.excerpt, similarity: match.similarity,
          reference: match.reference, relevanceScore: score)
      }
      matches.sort { $0.relevanceScore == $1.relevanceScore ? ($0.similarity == $1.similarity ? $0.id < $1.id : $0.similarity > $1.similarity)
        : ($0.relevanceScore ?? -.infinity) > ($1.relevanceScore ?? -.infinity) }
      if let best = matches.first?.relevanceScore { matches.removeAll { ($0.relevanceScore ?? -.infinity) < best - Self.maximumRelevanceGap } }
    } else if let best = matches.first?.similarity {
      matches.removeAll { $0.similarity < best - Self.maximumScoreGap }
    }
    // Revalidate after BOTH model stages. Neither a slow relevance model nor
    // closing/changing the source may authorize stale evidence.
    try Task.checkCancellation()
    try await workspace.requireOpen()
    let after = try await workspace.refresh()
    guard try WikiSearchEpoch.revision(after) == epoch else { throw WikiError.changedSource }
    try await workspace.projection.removeDerivedValues(producer: producer, retaining: Set(after.documents.flatMap(\.sections).map(\.id)))
    let complete = selected.count == items.count && indexed + skipped == selected.count && skipped == 0
    if !complete { diagnostics.append(.init(path: "", reason: "semantic_index_partial: 512 sections, 8 KiB/section, 15 seconds indexing budget")) }
    let result = Array(matches.prefix(limit))
    _ = try await workspace.read(result.map(\.reference))
    return .init(atomicSnapshot: false, modelID: modelID, matches: result, sourceRevision: snapshot.revision,
      coverageComplete: snapshot.coverageComplete, indexComplete: complete, indexedSections: indexed,
      cachedSections: reused, vectorBytes: bytes, diagnostics: diagnostics,
      relevanceComplete: relevanceComplete, relevanceCheckedCandidates: checked)
  }

  package static func cacheProducer(modelID: String, purpose: WikiSemanticPurpose = .retrieval) -> String {
    "folio.semantic/" + purpose.rawValue + "/" + SourceDigest.sha256(modelID)
  }

  private static func normalized(_ vector: [Double]?) -> [Double]? {
    guard let vector, !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0 else { return nil }
    return vector.map { $0 / norm }
  }
}
