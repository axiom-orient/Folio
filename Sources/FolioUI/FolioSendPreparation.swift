import FolioNearbyTransport
import Foundation
import Observation

/// Owns the screen's immutable outgoing copy until the transfer accepts it.
/// Preparation runs in the caller's task; Nearby owns the actual send lifetime.
@MainActor @Observable
final class FolioSendPreparation {
  private(set) var file: URL?
  private(set) var isPreparing = false
  private(set) var error: String?

  func prepare(_ source: FolioSendSource, using transfer: FolioNearbyModel) async {
    discard()
    isPreparing = true
    error = nil
    defer { isPreparing = false }
    do {
      let file = try await source.prepare(in: transfer)
      guard !Task.isCancelled else {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        return
      }
      self.file = file
    } catch is CancellationError {
      if !Task.isCancelled { self.error = "파일 준비가 중단되었습니다." }
    } catch { self.error = error.localizedDescription }
  }

  func send(to discovery: AcornryDiscovery, title: String, using transfer: FolioNearbyModel) -> Bool {
    guard let file, transfer.send(file: file, title: title, to: discovery) else { return false }
    self.file = nil
    return true
  }

  func discard() {
    if let file {
      try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
      self.file = nil
    }
  }
}
