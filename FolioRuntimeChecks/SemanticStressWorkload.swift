import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import FolioSemanticModels

/// Shared by the native hosted checks and the CLI through one source symlink.
/// Every workspace below is a newly created, test-owned temporary directory.
enum SemanticStressWorkload {
  struct Corpus: Decodable, Sendable {
    struct Entry: Decodable, Sendable { let id: String; let topic: String; let text: String; let tokens: Int }
    let short: [Entry]
    let long: [Entry]
  }
  struct Configuration: Sendable {
    var layout = "short"
    var count = 512
    var workers = 1
    var iterations = 2
    var durationSeconds = 0
    var pressureMiB = 0
  }
  struct Event: Encodable, Sendable {
    let phase: String
    let worker: Int?
    let iteration: Int?
    let milliseconds: Double?
    let indexed: Int?
    let cached: Int?
    let indexComplete: Bool?
    let relevanceComplete: Bool?
    let candidates: Int?
    let error: String?
    let memory: WikiProcessMemory?
    let uptime: TimeInterval
    let process: String
  }
  actor Log {
    let url: URL
    init(url: URL) throws {
      self.url = url
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: url, options: .atomic)
    }
    func append(_ phase: String, worker: Int? = nil, iteration: Int? = nil, milliseconds: Double? = nil,
      report: WikiSemanticSearchReport? = nil, error: String? = nil) throws {
      let event = Event(phase: phase, worker: worker, iteration: iteration, milliseconds: milliseconds,
        indexed: report?.indexedSections, cached: report?.cachedSections, indexComplete: report?.indexComplete,
        relevanceComplete: report?.relevanceComplete, candidates: report?.matches.count, error: error,
        memory: WikiProcessMemory.current(), uptime: ProcessInfo.processInfo.systemUptime,
        process: ProcessInfo.processInfo.processName)
      guard event.memory != nil else { throw WikiError.unavailable("Kernel memory accounting unavailable.") }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(event)
      let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
      try file.seekToEnd(); try file.write(contentsOf: data); try file.write(contentsOf: Data("\n".utf8))
      print("FOLIO_STRESS " + String(decoding: data, as: UTF8.self))
    }
  }

  static func run(corpusURL: URL, outputURL: URL, configuration c: Configuration) async throws {
    guard ["short", "long", "single"].contains(c.layout), (1...5000).contains(c.count), (1...4).contains(c.workers),
      (1...10000).contains(c.iterations), (0...3600).contains(c.durationSeconds), (0...96).contains(c.pressureMiB) else {
      throw WikiError.invalidSource("Invalid bounded stress configuration.")
    }
    let log = try Log(url: outputURL)
    try await log.append("start")
    let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
    let templates = c.layout == "long" ? corpus.long : corpus.short
    guard templates.count >= 512 else { throw WikiError.invalidSource("Stress corpus is incomplete.") }
    let entries = (0..<c.count).map { i in
      let template = templates[i % templates.count]
      return Corpus.Entry(id: String(format: "stress-%05d", i), topic: template.topic, text: template.text, tokens: template.tokens)
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioStress-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("Source")
    try WikiWorkspace.create(at: source, name: "성능 검증 자료")
    if c.layout == "single" {
      let text = "---\nid: stress-book\ntype: note\n---\n" + entries.map(\.text).joined(separator: "\n")
      try Data(text.utf8).write(to: source.appendingPathComponent("notes/book.md"))
    } else {
      for entry in entries {
        try Data("---\nid: \(entry.id)\ntype: note\n---\n\(entry.text)".utf8)
          .write(to: source.appendingPathComponent("notes/\(entry.id).md"))
      }
    }
    let originals = try sourceHashes(source)
    try await log.append("fixture.ready")
    let ballast = Data(repeating: 0xA5, count: c.pressureMiB * 1024 * 1024)
    try await log.append("controlled.application.load.ready")
    let deadline = ContinuousClock.now.advanced(by: .seconds(c.durationSeconds))
    try await withThrowingTaskGroup(of: Void.self) { group in
      for worker in 0..<c.workers {
        group.addTask {
          let workspace = try WikiWorkspace(root: source, localStateDirectory: base.appendingPathComponent("State-\(worker)"))
          let service = WikiSearchService(workspace: workspace, workspaceID: workspace.workspaceID,
            localSemanticEmbedding: MultilingualE5Embedding(), localSemanticRelevance: MultilingualMiniLMRelevance())
          var iteration = 0
          do {
            repeat {
              try Task.checkCancellation()
              let query = iteration.isMultiple(of: 2) ? "돈을 맡기고 이자를 받을 곳" : "양자 컴퓨터 오류 보정 부호"
              let start = ContinuousClock.now
              do {
                let report = try await service.semanticSearch(query, limit: 3)
                let elapsed = start.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                for match in report.matches { _ = try await workspace.read(match.reference) }
                if !iteration.isMultiple(of: 2), !report.matches.isEmpty { throw WikiError.invalidSource("Unrelated stress query returned a candidate.") }
                try await log.append("search.completed", worker: worker, iteration: iteration,
                  milliseconds: milliseconds, report: report)
              } catch is CancellationError { throw CancellationError() }
              catch {
                try await log.append("search.failed", worker: worker, iteration: iteration,
                  error: String(describing: error))
                throw error
              }
              iteration += 1
              if c.durationSeconds > 0 { try await Task.sleep(for: .milliseconds(250)) }
            } while iteration < c.iterations || (c.durationSeconds > 0 && ContinuousClock.now < deadline)
            await service.releaseSemanticResources(); await workspace.close()
            try await log.append("worker.released", worker: worker)
          } catch {
            await service.releaseSemanticResources(); await workspace.close(); throw error
          }
        }
      }
      try await group.waitForAll()
    }
    // Keep every touched ballast page alive until model activity has ended.
    let checksum = ballast.reduce(UInt64(0)) { $0 &+ UInt64($1) }
    guard checksum == UInt64(ballast.count) * 0xA5 else { throw WikiError.invalidSource("Ballast changed.") }
    guard try sourceHashes(source) == originals else { throw WikiError.changedSource }
    try await log.append("source.bytes.unchanged")
  }

  private static func sourceHashes(_ root: URL) throws -> [String: String] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw WikiError.invalidSource("Missing stress workspace.") }
    var hashes: [String: String] = [:]
    for case let url as URL in enumerator where url.pathExtension == "md" {
      hashes[url.lastPathComponent] = SourceDigest.sha256(try Data(contentsOf: url))
    }
    return hashes
  }
}
