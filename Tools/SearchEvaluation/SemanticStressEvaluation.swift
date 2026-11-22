import Foundation
import FolioKnowledge

enum SemanticStressEvaluation {
  static func run() async throws {
    let args = CommandLine.arguments
    func value(_ flag: String, _ fallback: String) throws -> String {
      guard let i = args.firstIndex(of: flag) else { return fallback }
      guard i + 1 < args.count else { throw WikiError.invalidSource("Missing " + flag) }
      return args[i + 1]
    }
    var c = SemanticStressWorkload.Configuration()
    c.layout = try value("--layout", "short")
    c.count = Int(try value("--count", "512")) ?? 0
    c.workers = Int(try value("--workers", "1")) ?? 0
    c.iterations = Int(try value("--iterations", "2")) ?? 0
    c.durationSeconds = Int(try value("--seconds", "0")) ?? -1
    c.pressureMiB = Int(try value("--pressure-mib", "0")) ?? -1
    let corpus = URL(fileURLWithPath: try value("--fixture", "FolioRuntimeChecks/Resources/StressCorpus.json"))
    let output = URL(fileURLWithPath: try value("--output", "/tmp/folio-stress.jsonl"))
    try await SemanticStressWorkload.run(corpusURL: corpus, outputURL: output, configuration: c)
  }
}
