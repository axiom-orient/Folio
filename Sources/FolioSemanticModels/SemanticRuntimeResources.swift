import Foundation
import Dispatch

/// Both model runtimes share one executor, so two prediction scratch arenas
/// cannot grow concurrently. Neither tokenizer output nor model scores change.
@globalActor actor SemanticInferenceActor {
  static let shared = SemanticInferenceActor()
}

public enum SemanticResourceError: Error, LocalizedError, Sendable {
  case systemPressure
  public var errorDescription: String? {
    switch self {
    case .systemPressure: "기기의 메모리 부담이 줄어든 뒤 다시 시도해 주세요. 기본 검색은 계속 사용할 수 있습니다."
    }
  }
}

/// Respond to the operating system's pressure signal. The old 128 MiB research
/// target is measured externally; it is not an OS limit or a product cutoff.
@SemanticInferenceActor enum SemanticRuntimeResources {
  private static var pressureSource: (any DispatchSourceMemoryPressure)?
  private static var underPressure = false

  static func check() throws {
    observePressure()
    guard !underPressure else { throw SemanticResourceError.systemPressure }
  }

  static func receivePressure(_ event: DispatchSource.MemoryPressureEvent) {
    underPressure = !event.contains(.normal)
    if underPressure {
      MultilingualE5Embedding.evictForMemoryPressure()
      MultilingualMiniLMRelevance.evictForMemoryPressure()
      SemanticMemoryTrace.sample("system.memory.pressure.evicted")
    }
  }

  private static func observePressure() {
    guard pressureSource == nil else { return }
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
    // Dispatch invokes this handler on its utility queue, outside the actor.
    source.setEventHandler { @Sendable in
      Task { @SemanticInferenceActor in
        guard let source = pressureSource else { return }
        receivePressure(source.data)
      }
    }
    pressureSource = source
    source.activate()
  }
}
