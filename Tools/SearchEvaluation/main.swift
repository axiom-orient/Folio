import Foundation
import FolioKnowledge
import FolioKnowledgeApple

/// Deterministic synthetic relevance judgments, never personal documents or a live index.
@main struct SearchEvaluation {
  struct Query {
    let text: String
    let relevant: Set<String>
  }
  struct Sample: Encodable {
    let route: String
    let query: String
    let returned: [String]
    let recallAt10: Double?
    let reciprocalRankAt10: Double?
    let milliseconds: Double
    let coverageComplete: Bool
  }
  struct Report: Encodable {
    let schema = "folio.search-evaluation/1"
    let corpus = "synthetic-bilingual-v1"
    let inference = "disabled; local lexical evidence only"
    let date: String
    let os: String
    let samples: [Sample]
  }
  static func main() async throws {
    if CommandLine.arguments.contains("--semantic-stress") { try await SemanticStressEvaluation.run(); return }
    if CommandLine.arguments.contains("--semantic-memory-probe") { try await SemanticMemoryProbe.run(); return }
    if CommandLine.arguments.contains("--semantic") { try await SemanticEvaluation.run(); return }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioSearchEvaluation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Source")
    try WikiWorkspace.create(at: root, name: "Synthetic search evaluation")
    let notes: [(String, String)] = [
      ("coffee", "aliases: [\"Café Plan\", 커피계획]\n---\n# Coffee plan\nCoffee preparation budget.\n"),
      ("bank-finance", "aliases: [예금안내]\n---\n# 금융 은행\n은행 예금 금리 안내.\n"),
      ("bank-river", "---\n# River bank\n은행 나무가 있는 강변 산책 기록.\n"),
      ("swift", "---\n# Swift concurrency\nActor cancellation evidence. 동시성 작업 취소.\n"),
      ("research", "---\n# 연구 출처\n연구 근거와 재현 조건을 기록한다.\n")
    ]
    for (id, body) in notes {
      try Data(("---\nid: \(id)\n" + body).utf8).write(to: root.appendingPathComponent("notes/\(id).md"))
    }
    let workspace = try WikiWorkspace(root: root, localStateDirectory: base.appendingPathComponent("State"))
    let service = WikiSearchService(workspace: workspace, workspaceID: workspace.workspaceID)
    let queries = [
      Query(text: "커피계획", relevant: ["coffee"]), Query(text: "cafe plan", relevant: ["coffee"]),
      Query(text: "예금안내", relevant: ["bank-finance"]), Query(text: "은행", relevant: ["bank-finance", "bank-river"]),
      Query(text: "Swift concurrency", relevant: ["swift"]), Query(text: "연구 근거", relevant: ["research"]),
      Query(text: "AbsentNeedle", relevant: []),
      // Intentionally missing paraphrase: measures a lexical limitation, not an inferred answer.
      Query(text: "저축기관", relevant: ["bank-finance"])
    ]
    var samples: [Sample] = []
    do {
      for _ in 0..<5 {
        for query in queries {
          for route in ["localPage", "boundedLocalFallback"] {
            let start = ContinuousClock.now
            let hits: [WikiSearchHit]
            let complete: Bool
            if route == "localPage" {
              let page = try await service.searchPage(query.text, pageSize: 10)
              hits = page.hits; complete = page.coverageComplete
            } else {
              let result = try await service.search(query.text, limit: 10, includeSystemSearch: false)
              hits = result.hits; complete = result.coverageComplete
            }
            let ids = hits.map(\.reference.documentID)
            let found = Set(ids).intersection(query.relevant)
            let elapsed = start.duration(to: .now).components
            samples.append(Sample(route: route, query: query.text, returned: ids,
              recallAt10: query.relevant.isEmpty ? nil : Double(found.count) / Double(query.relevant.count),
              reciprocalRankAt10: query.relevant.isEmpty ? nil : ids.firstIndex(where: query.relevant.contains).map { 1 / Double($0 + 1) } ?? 0,
              milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
              coverageComplete: complete))
          }
        }
      }
      await workspace.close()
    } catch { await workspace.close(); throw error }
    let report = Report(date: ISO8601DateFormatter().string(from: Date()),
      os: ProcessInfo.processInfo.operatingSystemVersionString, samples: samples)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
