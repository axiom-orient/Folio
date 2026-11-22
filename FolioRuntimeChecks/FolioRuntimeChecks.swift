import XCTest
import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import FolioSemanticModels

@MainActor final class FolioRuntimeChecks: XCTestCase {
  func testSourceBackedStress() async throws {
    let env = ProcessInfo.processInfo.environment
    var c = SemanticStressWorkload.Configuration()
    c.layout = env["FOLIO_STRESS_LAYOUT"] ?? "short"
    c.count = Int(env["FOLIO_STRESS_COUNT"] ?? "512") ?? 0
    c.workers = Int(env["FOLIO_STRESS_WORKERS"] ?? "1") ?? 0
    c.iterations = Int(env["FOLIO_STRESS_ITERATIONS"] ?? "2") ?? 0
    c.durationSeconds = Int(env["FOLIO_STRESS_SECONDS"] ?? "0") ?? -1
    c.pressureMiB = Int(env["FOLIO_STRESS_PRESSURE_MIB"] ?? "0") ?? -1
    let bundle = Bundle(for: Self.self)
    let corpus = try XCTUnwrap(bundle.url(forResource: "StressCorpus", withExtension: "json")
      ?? bundle.url(forResource: "StressCorpus", withExtension: "json", subdirectory: "Resources"))
    let output = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
      .appendingPathComponent("FolioStress-\(c.layout)-\(c.workers)-\(c.pressureMiB).jsonl")
    try await SemanticStressWorkload.run(corpusURL: corpus, outputURL: output, configuration: c)
    let events = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
    XCTAssertTrue(events.last?.contains("source.bytes.unchanged") == true)
    XCTAssertFalse(events.contains { $0.contains("search.failed") }, "A failed request must not be counted as a quality pass.")
    let attachment = XCTAttachment(contentsOfFile: output)
    attachment.name = output.lastPathComponent; attachment.lifetime = .keepAlways; add(attachment)
  }
}
