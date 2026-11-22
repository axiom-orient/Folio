import Foundation
import Observation

/// A presentation can disappear with its window; unresolved input must not.
/// Retained entries reference the same buffers, never a second text snapshot.
@MainActor @Observable
final class FolioSourceRepairs {
  private(set) var selection: FolioSourceRepair?
  private var retained: [UUID: FolioSourceRepair] = [:]

  private var unsavedInput: FolioSourceRepair? {
    if let selection, selection.hasUnsavedInput { return selection }
    return retained.values.first { $0.hasUnsavedInput }
  }

  @discardableResult
  func present(_ value: FolioSourceRepair?) -> Bool {
    if let value, let pending = unsavedInput, pending.id != value.id {
      selection = pending
      return false
    }
    if let selection, selection.hasUnsavedInput { retained[selection.id] = selection }
    selection = value
    retained = retained.filter { $0.value.hasUnsavedInput }
    return true
  }

  /// Termination is cancelled before any input lane or access lease is closed.
  func restoreUnsavedInput() -> Bool {
    guard let pending = unsavedInput else { return false }
    selection = pending
    return true
  }
}
