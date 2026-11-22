import Foundation
import FolioKnowledgeApple
import Synchronization

/// Opt-in diagnostics: phase names and process memory only, never source text.
package enum SemanticMemoryTrace {
  private static let enabled = ProcessInfo.processInfo.environment["FOLIO_SEMANTIC_MEMORY_TRACE"] == "1"
  private static let output = Mutex<URL?>(nil)
  package static func sample(_ phase: String) {
    guard enabled else { return }
    var fields: [String: Any] = ["phase": phase, "uptime": ProcessInfo.processInfo.systemUptime]
    if let memory = WikiProcessMemory.current() {
      fields["peakRSS"] = memory.peakResidentBytes; fields["rss"] = memory.residentBytes
      fields["footprint"] = memory.physicalFootprintBytes; fields["peakFootprint"] = memory.peakPhysicalFootprintBytes
      if let available = memory.availableApplicationBytes { fields["availableMemory"] = available }
    } else { fields["accountingUnavailable"] = true }
    if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
      FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8))
      // Explicit diagnostics only. Caches are disposable and contain no query,
      // path, document identifier or source contents. Overwrite on first use
      // in each process so a new launch cannot inherit another run's peak.
      output.withLock { url in
        if url == nil, let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
          let destination = cache.appendingPathComponent("FolioSemanticMemoryTrace.jsonl")
          try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
          if (try? Data().write(to: destination, options: .atomic)) != nil { url = destination }
        }
        if let url, let file = try? FileHandle(forWritingTo: url) {
          defer { try? file.close() }
          _ = try? file.seekToEnd(); try? file.write(contentsOf: data); try? file.write(contentsOf: Data("\n".utf8))
        }
      }
    }
  }
}
