import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import FolioSemanticModels

/// Fresh-process diagnostics with the actual bundled providers. No source files
/// or approval state are opened. Use --semantic for full source-backed quality.
enum SemanticMemoryProbe {
  static func run() async throws {
    let args = CommandLine.arguments
    func value(_ flag: String, default fallback: String) throws -> String {
      guard let index = args.firstIndex(of: flag) else { return fallback }
      guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
        throw WikiError.invalidSource("Missing value for " + flag)
      }
      return args[index + 1]
    }
    let scenario = try value("--scenario", default: "joint")
    guard ["tokenizers", "e5", "relevance", "joint"].contains(scenario),
      let cycles = Int(try value("--cycles", default: "1")), (1...10).contains(cycles) else {
      throw WikiError.invalidSource("Expected scenario tokenizers/e5/relevance/joint and cycles 1...10.")
    }
    let long = args.contains("--long")
    let text = long ? String(repeating: "word ", count: 507) : "은행은 고객이 맡긴 돈을 예금 계좌에 보관하고 약정한 조건에 따라 이자를 지급한다."
    SemanticMemoryTrace.sample("probe.start")
    let embedding = MultilingualE5Embedding(); let relevance = MultilingualMiniLMRelevance()
    for cycle in 1...cycles {
      SemanticMemoryTrace.sample("probe.cycle.\(cycle).start")
      if scenario == "tokenizers" {
        _ = try await embedding.tokenIDs("passage: " + text)
        _ = try await relevance.tokenIDs(query: "이자를 받는 곳", passage: text)
        SemanticMemoryTrace.sample("probe.tokenizers.ready")
      }
      if scenario == "e5" || scenario == "joint" {
        _ = try await embedding.vector(for: text, role: .passage)
        SemanticMemoryTrace.sample("probe.e5.ready")
      }
      if scenario == "relevance" || scenario == "joint" {
        _ = try await relevance.scores(query: long ? "word" : "이자를 받는 곳", passages: [text])
        SemanticMemoryTrace.sample("probe.relevance.ready")
      }
      await embedding.releaseResources(); await relevance.releaseResources()
      SemanticMemoryTrace.sample("probe.cycle.\(cycle).released")
    }
  }
}
