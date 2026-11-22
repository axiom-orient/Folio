import Foundation
import Observation

/// Owns application storage readiness and the shared first-unlock preparation job.
/// FolioStorage performs migration I/O; workspace generations admit its result.
@MainActor @Observable
final class FolioStorageAccess {
  private(set) var isReady = true
  private(set) var protectedDataAvailable = true

  #if os(iOS)
  private struct Preparation {
    let id: UUID
    let task: Task<Bool, Error>
  }
  private var preparation: Preparation?
  private var migrateLegacyStorage = true
  var isPreparing: Bool { preparation != nil }
  #endif

  func initializeApplication(migrateLegacyStorage: Bool) -> String? {
    #if os(iOS)
    self.migrateLegacyStorage = migrateLegacyStorage
    protectedDataAvailable = FolioStorage.mobileDataReady(migrateLegacyStorage: migrateLegacyStorage)
    return nil
    #else
    do {
      if migrateLegacyStorage { try FolioStorage.migrate() }
      return nil
    } catch {
      isReady = false
      return error.localizedDescription
    }
    #endif
  }

  func updateProtectedDataAvailability(_ available: Bool) {
    protectedDataAvailable = available
  }

  #if os(iOS)
  func prepare(isCurrent: @MainActor () -> Bool) async -> String? {
    let current: Preparation
    if let preparation { current = preparation }
    else {
      let migrate = migrateLegacyStorage
      current = Preparation(id: UUID(), task: Task { try await FolioStorage.prepareMobileAccess(migrateLegacyStorage: migrate) })
      preparation = current
    }
    let result = await current.task.result
    if preparation?.id == current.id { preparation = nil }
    guard isCurrent() else { return nil }
    switch result {
    case .success(let available):
      isReady = true
      protectedDataAvailable = available
      return nil
    case .failure(let error):
      isReady = false
      protectedDataAvailable = false
      return "기존 자료 준비를 위해 iPhone을 한 번 잠금 해제해 주세요. " + error.localizedDescription
    }
  }
  #endif
}
