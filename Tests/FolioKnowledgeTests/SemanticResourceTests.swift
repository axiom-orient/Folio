import CoreML
import Foundation
import Testing
import FolioKnowledgeApple
@testable import FolioSemanticModels

@Suite(.serialized)
struct SemanticResourceTests {
  @Test func concreteAndProtocolReleaseUnloadAndReloadIdentically() async throws {
    let embedding = MultilingualE5Embedding()
    let relevance = MultilingualMiniLMRelevance()
    let text = "은행은 예금 계좌에 맡긴 돈에 약정한 이자를 지급한다."
    let first = try await embedding.vector(for: text, role: .passage)
    let firstScore = try await relevance.scores(query: "이자를 받는 곳", passages: [text])
    #expect(await embedding.loadedResourceCount == 2)
    #expect(await relevance.loadedResourceCount == 2)
    let boundary = String(repeating: "word ", count: 507)
    #expect(try await embedding.tokenIDs("passage: " + boundary).count == 512)
    #expect(try await relevance.tokenIDs(query: "word", passage: boundary).count == 512)
    #expect(try await embedding.vector(for: boundary, role: .passage).count == 384)
    #expect(try await relevance.scores(query: "word", passages: [boundary]).first! != nil)
    let oversized = String(repeating: "word ", count: 508)
    await #expect(throws: WikiSemanticEmbeddingError.self) { try await embedding.vector(for: oversized, role: .passage) }
    #expect(try await relevance.scores(query: "word", passages: [oversized]) == [nil])
    // A synchronous actor method plus the protocol's default async no-op can
    // select the wrong overload at a concrete call site. Exercise both forms.
    await embedding.releaseResources(); await relevance.releaseResources()
    #expect(await embedding.loadedResourceCount == 0)
    #expect(await relevance.loadedResourceCount == 0)
    #expect(try await embedding.vector(for: text, role: .passage) == first)
    #expect(try await relevance.scores(query: "이자를 받는 곳", passages: [text]) == firstScore)
    let e: any WikiSemanticEmbedding = embedding
    let r: any WikiSemanticRelevance = relevance
    await e.releaseResources(); await r.releaseResources()
    #expect(await embedding.loadedResourceCount == 0)
    #expect(await relevance.loadedResourceCount == 0)
  }

  @Test func separateProvidersReuseOneResourceOwnerWithoutEvictingAnotherActiveClient() async throws {
    let first = MultilingualE5Embedding(); let second = MultilingualE5Embedding()
    let r1 = MultilingualMiniLMRelevance(); let r2 = MultilingualMiniLMRelevance()
    await first.releaseResources(); await r1.releaseResources()
    let text = "은행은 예금을 맡긴 고객에게 이자를 지급한다."
    let vector = try await first.vector(for: text, role: .passage)
    #expect(try await second.vector(for: text, role: .passage) == vector)
    #expect(await second.loadedResourceCount == 2)
    let score = try await r1.scores(query: "돈을 맡기고 이자를 받는 곳", passages: [text])
    #expect(try await r2.scores(query: "돈을 맡기고 이자를 받는 곳", passages: [text]) == score)
    #expect(await r2.loadedResourceCount == 2)
    // Closing one window releases its lease without evicting another active owner.
    await second.releaseResources(); await r2.releaseResources()
    #expect(await first.loadedResourceCount == 2)
    #expect(await r1.loadedResourceCount == 2)
    #expect(await second.loadedResourceCount == 0)
    #expect(await r2.loadedResourceCount == 0)
    let vectors = try await withThrowingTaskGroup(of: [Double].self, returning: [[Double]].self) { group in
      for _ in 0..<4 { group.addTask { try await MultilingualE5Embedding().vector(for: text, role: .passage) } }
      var values: [[Double]] = []
      for try await value in group { values.append(value) }
      return values
    }
    #expect(vectors.count == 4 && vectors.allSatisfy { $0 == vector })
    #expect(try await r2.scores(query: "돈을 맡기고 이자를 받는 곳", passages: [text]) == score)
    await first.releaseResources(); await r2.releaseResources()
  }

  @Test func systemPressureEvictsAndDefersInferenceUntilRecoveryWithoutChangingScores() async throws {
    let embedding = MultilingualE5Embedding(); let relevance = MultilingualMiniLMRelevance()
    let text = "은행의 예금 계좌에 맡긴 돈과 이자"
    let vector = try await embedding.vector(for: text, role: .passage)
    let scores = try await relevance.scores(query: "돈을 맡길 곳", passages: [text])
    await SemanticRuntimeResources.receivePressure(.warning)
    #expect(await embedding.loadedResourceCount == 0)
    #expect(await relevance.loadedResourceCount == 0)
    await #expect(throws: SemanticResourceError.self) { try await embedding.vector(for: text, role: .passage) }
    await #expect(throws: SemanticResourceError.self) { try await relevance.scores(query: "돈을 맡길 곳", passages: [text]) }
    await SemanticRuntimeResources.receivePressure(.normal)
    #expect(try await embedding.vector(for: text, role: .passage) == vector)
    #expect(try await relevance.scores(query: "돈을 맡길 곳", passages: [text]) == scores)
    await embedding.releaseResources(); await relevance.releaseResources()
  }

  @Test func scopedPoolingMatchesOriginalDoubleArithmeticAndRejectsInvalidOutput() throws {
    let tensor = try MLMultiArray(shape: [1, 4, 3], dataType: .float32)
    for i in 0..<tensor.count { tensor[i] = NSNumber(value: Float(i - 5) / 7) }
    var expected = [Double](repeating: 0, count: 3)
    for t in 0..<4 { for d in 0..<3 { expected[d] += tensor[[0, NSNumber(value: t), NSNumber(value: d)]].doubleValue } }
    let norm = sqrt(expected.reduce(0) { $0 + $1 * $1 }); expected = expected.map { $0 / norm }
    #expect(try SemanticTensor.pooled(tensor, tokens: 4, dimensions: 3) == expected)
    let storage = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    storage.initialize(repeating: .nan, count: 32)
    defer { storage.deinitialize(count: 32); storage.deallocate() }
    let strided = try MLMultiArray(dataPointer: storage, shape: [1, 4, 3], dataType: .float32, strides: [32, 8, 2])
    for t in 0..<4 { for d in 0..<3 { storage[t * 8 + d * 2] = Float(t * 3 + d - 5) / 7 } }
    #expect(try SemanticTensor.pooled(strided, tokens: 4, dimensions: 3) == expected)
    #expect(throws: (any Error).self) { try SemanticTensor.pooled(tensor, tokens: 3, dimensions: 4) }
    tensor[0] = NSNumber(value: Float.nan)
    #expect(throws: (any Error).self) { try SemanticTensor.pooled(tensor, tokens: 4, dimensions: 3) }
  }

  @Test func inputTensorPadsMasksAndRejectsInvalidIDs() throws {
    let input = try SemanticTensor.input(tokens: [0, 3, 250001, 2], length: 6)
    let ids = try #require(input.featureValue(for: "input_ids")?.multiArrayValue)
    let mask = try #require(input.featureValue(for: "attention_mask")?.multiArrayValue)
    #expect((0..<6).map { ids[$0].intValue } == [0, 3, 250001, 2, 1, 1])
    #expect((0..<6).map { mask[$0].intValue } == [1, 1, 1, 1, 0, 0])
    #expect(throws: (any Error).self) { try SemanticTensor.input(tokens: [Int.max], length: 1) }
    #expect(throws: (any Error).self) { try SemanticTensor.input(tokens: [0, 2], length: 1) }
    #expect(throws: (any Error).self) { try SemanticTensor.input(tokens: [], length: 0) }
  }

  @Test func malformedCompiledTokenizerFailsClosed() async throws {
    let root = try await MultilingualE5Embedding().resources()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FolioInvalidTokenizer-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try Data(contentsOf: root.appendingPathComponent("Unigram.foliotokens"))
    try Data(contentsOf: root.appendingPathComponent("Precompiled.charsmap")).write(to: folder.appendingPathComponent("Precompiled.charsmap"))
    for offset in [0, 8, 12, 16, 20, 24, 32, 36, 40, 44] {
      var damaged = bytes
      damaged.replaceSubrange(offset..<(offset + 4), with: offset == 40 ? [146, 208, 3, 0] : [255, 255, 255, 255])
      try damaged.write(to: folder.appendingPathComponent("Unigram.foliotokens"), options: .atomic)
      #expect(throws: (any Error).self) { try CompactUnigramTokenizer(root: folder, pipeline: .embedding) }
    }
    try bytes.dropLast().write(to: folder.appendingPathComponent("Unigram.foliotokens"), options: .atomic)
    #expect(throws: (any Error).self) { try CompactUnigramTokenizer(root: folder, pipeline: .relevance) }
  }
}
