import Foundation
import os

/// Owns account observation and the close/forget lane for a revoked cloud source.
/// The session owns source access; its caller supplies the full application close.
@MainActor
final class FolioCloudAccount {
  private var identity: FolioCloudIdentity
  private var boundSourceToken: (any NSObjectProtocol)?
  private var revocation: Task<Void, Never>?
  private let session: FolioWorkspaceSession
  private let storageAccess: FolioStorageAccess
  private let systemToken: @MainActor () -> (any NSObjectProtocol)?
  private let logger = Logger(subsystem: "com.axient.Folio", category: "CloudIdentity")
  var onMessage: (@MainActor (String) -> Void)?

  init(session: FolioWorkspaceSession, storageAccess: FolioStorageAccess, token: (any NSObjectProtocol)?,
    systemToken: @escaping @MainActor () -> (any NSObjectProtocol)? = { FileManager.default.ubiquityIdentityToken }
  ) {
    self.session = session
    self.storageAccess = storageAccess
    self.systemToken = systemToken
    identity = FolioCloudIdentity(token: token)
  }

  var generation: Int { identity.generation }
  var currentToken: (any NSObjectProtocol)? { identity.currentToken }
  var matchesSystemIdentity: Bool { identity.matches(systemToken()) }
  func matchesCurrentIdentity(_ captured: (any NSObjectProtocol)?) -> Bool {
    identity.matches(captured) && matchesSystemIdentity
  }
  var sourceMatchesCurrentIdentity: Bool { matchesCurrentIdentity(boundSourceToken) }
  func bindSourceIdentity(_ token: (any NSObjectProtocol)?) { boundSourceToken = token }
  var supportsManagedCloud: Bool { Bundle.main.object(forInfoDictionaryKey: "FolioCloudContainerID") != nil }

  func refreshLibrary() async {
    guard storageAccess.isReady, storageAccess.protectedDataAvailable,
      let id = Bundle.main.object(forInfoDictionaryKey: "FolioCloudContainerID") as? String else { return }
    await session.cloudLibrary.start(containerIdentifier: id)
  }

  func identityChanged(closeWorkspace: @escaping @MainActor () async -> Void) async {
    let wasAvailable = identity.isAvailable
    let change = identity.observe(systemToken())
    let isAvailable = identity.isAvailable
    logger.notice("iCloud identity observed: didChange=\(change != nil, privacy: .public) previousAvailable=\(wasAvailable, privacy: .public) available=\(isAvailable, privacy: .public)")
    guard let change else { return }
    session.cloudLibrary.stop()
    if session.isCloudWorkspace { await revokeSource(closeWorkspace: closeWorkspace) }
    guard identity.generation == change.generation else { return }
    await refreshLibrary()
  }

  func waitForRevocation() async { await revocation?.value }

  func revokeSource(closeWorkspace: @escaping @MainActor () async -> Void) async {
    session.markSuspended()
    if revocation == nil {
      let captured = identity.beginRevocation(documentGeneration: session.documentGeneration,
        sourceGeneration: session.generation)
      let location = session.location
      let pendingLocation = session.pendingLocation
      revocation = Task { [weak self] in
        guard let self else { return }
        defer {
          self.identity.finishRevocation(captured)
          // This single-flight task is never replaced or cleared before completion.
          self.revocation = nil
        }
        await closeWorkspace()
        guard self.session.location == location,
          self.identity.mayForget(captured, documentGeneration: self.session.documentGeneration,
            sourceGeneration: self.session.generation, hasOpenSource: self.session.hasOpenWorkspace,
            isOpeningSource: self.session.pendingLocation != nil && self.session.pendingLocation != pendingLocation) else { return }
        self.session.forgetLocation()
        self.onMessage?(self.identity.isAvailable
          ? "iCloud 계정이 바뀌었습니다. 사용할 자료함을 다시 선택해 주세요."
          : "iCloud를 사용할 수 없습니다. 편집 내용은 초안으로 유지합니다. iCloud 연결을 확인해 주세요.")
      }
    }
    await revocation?.value
  }
}
