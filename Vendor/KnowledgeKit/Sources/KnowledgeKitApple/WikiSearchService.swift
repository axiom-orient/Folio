import Foundation
import FolioKnowledge

public actor WikiSearchService {
  public let workspace: WikiWorkspace
  public let spotlight: WikiSpotlight
  private let selectedSemanticSearch: (@Sendable (String, Int) async throws -> [String])?
  private let localSemantics: WikiLocalSemanticSearch
  private let knowledge: WikiKnowledgeQuery
  private let candidateSearch = WikiCandidateSearch()
  private let selectedSemanticState: (@Sendable () async -> String)?

  public init(workspace: WikiWorkspace, workspaceID: UUID,
    semanticSearch: (@Sendable (String, Int) async throws -> [String])? = nil,
    semanticState: (@Sendable () async -> String)? = nil,
    localSemanticEmbedding: (any WikiSemanticEmbedding)? = nil,
    localSemanticRelevance: (any WikiSemanticRelevance)? = nil
  ) {
    localSemantics = WikiLocalSemanticSearch(embedding: localSemanticEmbedding, relevance: localSemanticRelevance)
    knowledge = WikiKnowledgeQuery(workspace: workspace, embedding: localSemanticEmbedding, relevance: localSemanticRelevance)
    self.workspace = workspace
    spotlight = WikiSpotlight(projection: workspace.projection, workspaceID: workspaceID)
    selectedSemanticSearch = semanticSearch; selectedSemanticState = semanticState
  }

  public func search(_ query: String, limit: Int = 10, includeSystemSearch: Bool = true) async throws -> WikiSearchResult {
    try Task.checkCancellation()
    try await workspace.requireOpen()
    _ = try await workspace.refresh()
    // Always obtain literal/FTS candidates first. A slow system index cannot prevent reading.
    let local = try await workspace.projection.search(query, limit: limit)
    let candidates: Candidates
    if includeSystemSearch {
      let semanticSearch = selectedSemanticSearch
      let semanticState = selectedSemanticState
      let spotlight = self.spotlight
      let observedState = semanticSearch == nil ? await self.semanticState() : "selectedProvider"
      candidates = await candidateSearch.search(source: semanticSearch == nil ? .spotlight : .semantic) {
        if let semanticSearch {
          return Candidates(ids: Array(try await semanticSearch(query, 100).prefix(1000)),
            state: await semanticState?() ?? "selectedProvider", source: .semantic)
        }
        return Candidates(ids: Array(try await spotlight.search(query).prefix(1000)),
          state: observedState, source: .spotlight)
      }
    } else { candidates = Candidates(ids: [], state: "local", source: .spotlight) }
    try Task.checkCancellation()
    try await workspace.requireOpen()
    let result = candidates.ids.isEmpty ? local : try await workspace.projection.search(query, limit: limit,
      semanticSectionIDs: candidates.ids, semanticState: candidates.state, candidateSource: candidates.source)
    var current: [WikiSearchHit] = []; var diagnostics = result.diagnostics
    for hit in result.hits {
      do { _ = try await workspace.read(hit.reference); current.append(hit) }
      catch is CancellationError { throw CancellationError() }
      catch { diagnostics.append(WikiDiagnostic(path: hit.reference.relativePath, reason: error.localizedDescription)) }
    }
    return WikiSearchResult(hits: current, diagnostics: diagnostics,
      coverageComplete: result.coverageComplete && current.count == result.hits.count,
      semanticState: candidates.state, resultsTruncated: result.resultsTruncated)
  }

  private typealias Candidates = WikiCandidateSearch.Result

  public func semanticState() async -> String {
    if let selectedSemanticState { return await selectedSemanticState() }
    let observed = await spotlight.state
    if observed.hasPrefix("degraded") || observed == "unavailable" { return observed }
    do {
      let pending = try await workspace.projection.pendingJobs(adapter: "spotlight", limit: 1)
      if let job = pending.first { return job.lastError.map { "degraded: \($0)" } ?? "indexing" }
      return observed
    } catch { return "degraded: \(error.localizedDescription)" }
  }

  /// Release large local model/tokenizer objects without removing source or caches.
  public func releaseSemanticResources() async { await localSemantics.releaseResources() }

  public func prepareKnowledgeIndex() async throws -> WikiKnowledgeCoverage { try await knowledge.prepare() }

  public func knowledgeAnswer(_ question: String, documentID: String? = nil,
    useSemantic: Bool = false, conceptID: String? = nil) async throws -> WikiKnowledgeAnswer {
    try await knowledge.answer(question, documentID: documentID, useSemantic: useSemantic, conceptID: conceptID)
  }

  public func releaseKnowledgeResources() async { await knowledge.releaseResources() }

  /// Explicit opt-in, separate from complete lexical pagination and Spotlight.
  public func semanticSearch(_ query: String, limit: Int = 10, language: String = "auto",
    filter: WikiDocumentFilter = .init(), documentIDs: Set<String>? = nil, purpose: WikiSemanticPurpose = .retrieval
  ) async throws -> WikiSemanticSearchReport {
    try await localSemantics.search(workspace: workspace, query: query, limit: limit, language: language, filter: filter, documentIDs: documentIDs, purpose: purpose)
  }

  public func searchPage(_ query: String, filter: WikiDocumentFilter = .init(),
    cursor: WikiSearchCursor? = nil, pageSize: Int = 50
  ) async throws -> WikiSearchPage {
    try await workspace.localSearchPage(query, filter: filter, cursor: cursor, pageSize: pageSize)
  }
}
