import Foundation

public enum WikiSemanticEmbeddingError: Error, LocalizedError, Sendable {
  case tokenBudget
  public var errorDescription: String? { "검색 모델의 512 토큰 한도를 넘었습니다. 더 짧은 질문이나 구간으로 나누어 검색해 주세요." }
}

public enum WikiSemanticPurpose: String, Sendable { case retrieval, similarity }

public enum WikiSemanticRole: Sendable { case query, passage }

/// The source/search layer owns evidence and cache validation. Optional model
/// packages supply only vectors; they have no source access or write authority.
public protocol WikiSemanticEmbedding: Sendable {
  var identifier: String { get }
  var dimensions: Int { get }
  func vector(for text: String, role: WikiSemanticRole) async throws -> [Double]
  func releaseResources() async
}
extension WikiSemanticEmbedding { public func releaseResources() async {} }

/// Joint query/passage relevance, separate from vector similarity. Nil denotes
/// an unscored pair (token/time budget), never permission to use a dense fallback.
public protocol WikiSemanticRelevance: Sendable {
  var identifier: String { get }
  func scores(query: String, passages: [String]) async throws -> [Double?]
  func releaseResources() async
}
extension WikiSemanticRelevance { public func releaseResources() async {} }
