import Synchronization

/// The Objective-C completion permits asynchronous acknowledgement but has no
/// Sendable annotation. This bridge owns one immutable callback and invokes it
/// at most once under a mutex; no app state is captured by the bridge itself.
final class SpotlightAcknowledgement: @unchecked Sendable {
  private let callback: () -> Void
  private let called = Mutex(false)
  init(_ callback: @escaping () -> Void) { self.callback = callback }
  func call() {
    called.withLock { called in
      guard !called else { return }; called = true; callback()
    }
  }
}
