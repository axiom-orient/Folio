import Foundation
import CoreML
import FolioKnowledge
import FolioKnowledgeApple

/// Pinned local cross-encoder. Joint attention checks query/passage relevance;
/// its raw logit is a ranking score, not a probability or evidence of truth.
/// Instances share one actor-isolated model per process. Resource eviction is
/// serialized with prediction; an eviction cannot invalidate an active tensor.
public actor MultilingualMiniLMRelevance: WikiSemanticRelevance {
  public nonisolated let identifier = "mmarco-minilm.fp16.5a9d13a7359c70b5a6b4c90810b65536b2ac470e.pair512.cpu.v1"
  private static let runtime = RelevanceModelRuntime()
  private let client = UUID()
  public init() {}
  deinit { let client = client; Task { await Self.runtime.releaseResources(client: client) } }
  @SemanticInferenceActor static func evictForMemoryPressure() { runtime.evict() }
  public func releaseResources() async { await Self.runtime.releaseResources(client: client) }
  package var loadedResourceCount: Int { get async { await Self.runtime.loadedResourceCount(for: client) } }

  public func scores(query: String, passages: [String]) async throws -> [Double?] {
    try await Self.runtime.scores(query: query, passages: passages, client: client)
  }
  package func tokenIDs(query: String, passage: String) async throws -> [Int] {
    try await Self.runtime.tokenIDs(query: query, passage: passage, client: client)
  }
  package func resources() throws -> URL { try BundledSemanticResources.root().appendingPathComponent("Relevance") }
}

@SemanticInferenceActor private final class RelevanceModelRuntime {
  private var tokenizer: CompactUnigramTokenizer?
  private var model: MLModel?
  private var compiledURL: URL?
  private var tracedPrediction = false
  private var clients: Set<UUID> = []
  nonisolated init() {}
  deinit { if let compiledURL { try? FileManager.default.removeItem(at: compiledURL) } }
  func releaseResources(client: UUID) {
    clients.remove(client)
    if clients.isEmpty { evict() }
  }
  func evict() {
    SemanticMemoryTrace.sample("relevance.resources.release.before")
    model = nil; tokenizer = nil; tracedPrediction = false
    SemanticMemoryTrace.sample("relevance.resources.released")
  }
  func loadedResourceCount(for client: UUID) -> Int {
    clients.contains(client) ? (model == nil ? 0 : 1) + (tokenizer == nil ? 0 : 1) : 0
  }

  func scores(query: String, passages: [String], client: UUID) throws -> [Double?] {
    let limit = WikiLocalSemanticSearch.maximumRelevanceCandidates
    guard passages.count <= limit else { throw WikiError.invalidSource("Relevance candidate budget is \(limit).") }
    try Task.checkCancellation()
    if passages.isEmpty { return [] }
    try requireResources()
    clients.insert(client)
    try loadModel()
    try loadTokenizer()
    guard let model else { throw WikiError.unavailable("관련성 검사 모델을 준비하지 못했습니다.") }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var scores: [Double?] = []
    for passage in passages {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { scores.append(nil); continue }
      let tokens = try tokenIDs(query: query, passage: passage, client: client)
      guard tokens.count <= 512 else { scores.append(nil); continue }
      try requireResources()
      let score: Double = try autoreleasepool {
        if !tracedPrediction { SemanticMemoryTrace.sample("relevance.predict.before") }
        let result = try model.prediction(from: SemanticTensor.input(tokens: tokens, length: 512))
        if !tracedPrediction { SemanticMemoryTrace.sample("relevance.predict.after"); tracedPrediction = true }
        try Task.checkCancellation()
        // This pinned artifact calls the output var_935 despite its model card
        // naming it logits. Validate the actual artifact, not the prose example.
        guard let output = result.featureValue(for: "var_935")?.multiArrayValue, output.shape == [1,1], output[0].doubleValue.isFinite else {
          throw WikiError.invalidSource("Unexpected relevance model output.")
        }
        return output[0].doubleValue
      }
      scores.append(score)
    }
    return scores
  }

  func resources() throws -> URL { try BundledSemanticResources.root().appendingPathComponent("Relevance") }
  func tokenIDs(query: String, passage: String, client: UUID) throws -> [Int] {
    clients.insert(client)
    try loadTokenizer()
    guard let tokenizer else { throw WikiError.unavailable("관련성 토크나이저를 준비하지 못했습니다.") }
    return [0] + tokenizer.encode(text: query, addSpecialTokens: false) + [2,2]
      + tokenizer.encode(text: passage, addSpecialTokens: false) + [2]
  }
  private func requireResources() throws {
    do { try SemanticRuntimeResources.check() }
    catch { evict(); throw error }
  }
  private func loadTokenizer() throws {
    guard tokenizer == nil else { return }
    let root = try BundledSemanticResources.root()
    SemanticMemoryTrace.sample("relevance.tokenizer.before")
    tokenizer = try CompactUnigramTokenizer(root: root, pipeline: .relevance)
    SemanticMemoryTrace.sample("relevance.tokenizer.constructed")
  }
  private func loadModel() throws {
    guard model == nil else { return }
    let cached = compiledURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    SemanticMemoryTrace.sample("relevance.compile.before")
    let compiled = try cached ?? MLModel.compileModel(at: resources().appendingPathComponent("reranker.mlpackage"))
    SemanticMemoryTrace.sample("relevance.compile.after")
    let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
    do { model = try autoreleasepool { try MLModel(contentsOf: compiled, configuration: config) }; compiledURL = compiled; SemanticMemoryTrace.sample("relevance.model.loaded") }
    catch { try? FileManager.default.removeItem(at: compiled); compiledURL = nil; throw error }
  }
}
