import Foundation
import CoreML
import FolioKnowledge
import FolioKnowledgeApple

/// Pinned MIT E5-small conversion. All input stays on the device. Tokenization,
/// query/passage prefixes and masked mean pooling follow the original E5 model.
/// Instances share one actor-isolated model per process. Resource eviction is
/// serialized with prediction; an eviction cannot invalidate an active tensor.
public actor MultilingualE5Embedding: WikiSemanticEmbedding {
  public nonisolated let identifier = "multilingual-e5-small.int8.0a386d4aea14586b042c6e68a83acb6ff8d87970.tokens512.pool1.cpu"
  public nonisolated let dimensions = 384
  private static let runtime = E5ModelRuntime()
  private let client = UUID()
  public init() {}
  deinit { let client = client; Task { await Self.runtime.releaseResources(client: client) } }
  @SemanticInferenceActor static func evictForMemoryPressure() { runtime.evict() }
  public func releaseResources() async { await Self.runtime.releaseResources(client: client) }
  package var loadedResourceCount: Int { get async { await Self.runtime.loadedResourceCount(for: client) } }

  public func vector(for text: String, role: WikiSemanticRole) async throws -> [Double] {
    try await Self.runtime.vector(for: text, role: role, client: client)
  }
  package func tokenIDs(_ text: String) async throws -> [Int] { try await Self.runtime.tokenIDs(text, client: client) }
  package func resources() throws -> URL { try BundledSemanticResources.root() }
}

@SemanticInferenceActor private final class E5ModelRuntime {
  nonisolated let dimensions = 384
  private var model: MLModel?
  private var tokenizer: CompactUnigramTokenizer?
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
    SemanticMemoryTrace.sample("e5.resources.release.before")
    model = nil; tokenizer = nil; tracedPrediction = false
    SemanticMemoryTrace.sample("e5.resources.released")
  }
  func loadedResourceCount(for client: UUID) -> Int {
    clients.contains(client) ? (model == nil ? 0 : 1) + (tokenizer == nil ? 0 : 1) : 0
  }

  func vector(for text: String, role: WikiSemanticRole, client: UUID) throws -> [Double] {
    try Task.checkCancellation()
    try requireResources()
    clients.insert(client)
    try loadModel()
    try loadTokenizer()
    guard let model, let tokenizer else { throw WikiError.unavailable("다국어 모델을 준비하지 못했습니다.") }
    let prefix = role == .query ? "query: " : "passage: "
    let raw = tokenizer.encode(text: prefix + text)
    // Refuse silent truncation: the source layer reports oversized sections as partial.
    guard raw.count <= 512 else { throw WikiSemanticEmbeddingError.tokenBudget }
    let tokens = raw
    try requireResources()
    return try autoreleasepool {
      let input = try SemanticTensor.input(tokens: tokens, length: tokens.count)
      if !tracedPrediction { SemanticMemoryTrace.sample("e5.predict.before") }
      let prediction = try model.prediction(from: input)
      if !tracedPrediction { SemanticMemoryTrace.sample("e5.predict.after") }
      try Task.checkCancellation()
      guard let hidden = prediction.featureValue(for: "last_hidden_state")?.multiArrayValue,
        hidden.shape == [1, NSNumber(value: tokens.count), 384] else { throw WikiError.invalidSource("Unexpected multilingual model output.") }
      let vector = try SemanticTensor.pooled(hidden, tokens: tokens.count, dimensions: dimensions)
      if !tracedPrediction { SemanticMemoryTrace.sample("e5.pool.after"); tracedPrediction = true }
      return vector
    }
  }

  /// Token IDs are exposed for reference-tokenizer conformance, not custom
  /// tokenization. This path reads only compiled bundled tables and never contacts a Hub.
  func tokenIDs(_ text: String, client: UUID) throws -> [Int] {
    clients.insert(client)
    try loadTokenizer()
    return tokenizer?.encode(text: text) ?? []
  }
  func resources() throws -> URL {
    try BundledSemanticResources.root()
  }
  private func requireResources() throws {
    do { try SemanticRuntimeResources.check() }
    catch { evict(); throw error }
  }
  private func loadTokenizer() throws {
    guard tokenizer == nil else { return }
    let root = try resources()
    SemanticMemoryTrace.sample("e5.tokenizer.before")
    tokenizer = try CompactUnigramTokenizer(root: root, pipeline: .embedding)
    SemanticMemoryTrace.sample("e5.tokenizer.constructed")
  }
  private func loadModel() throws {
    guard model == nil else { return }
    let package = try resources().appendingPathComponent("MultilingualE5Small.mlpackage")
    let cached = compiledURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    SemanticMemoryTrace.sample("e5.compile.before")
    let url = try cached ?? MLModel.compileModel(at: package)
    SemanticMemoryTrace.sample("e5.compile.after")
    let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
    do { model = try autoreleasepool { try MLModel(contentsOf: url, configuration: configuration) }; compiledURL = url; SemanticMemoryTrace.sample("e5.model.loaded") }
    catch { try? FileManager.default.removeItem(at: url); compiledURL = nil; throw error }
  }
}

enum BundledSemanticResources {
  static func root() throws -> URL {
    guard let root = Bundle.module.resourceURL else { throw WikiError.unavailable("다국어 모델 리소스를 찾지 못했습니다.") }
    // Current bundles copy the assets to their resource root. Older bundles
    // may retain the copied Resources folder inside that root.
    for candidate in [root.appendingPathComponent("Resources"), root] {
      if ["Unigram.foliotokens", "Precompiled.charsmap", "MultilingualE5Small.mlpackage"].allSatisfy({
        FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path)
      }) { return candidate }
    }
    throw WikiError.unavailable("앱에 포함된 다국어 모델 리소스를 찾지 못했습니다.")
  }
}
