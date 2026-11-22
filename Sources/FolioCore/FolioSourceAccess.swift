import Synchronization

/// Host-owned admission for protected data, security-scoped URLs and account
/// transitions. Revocation is permanent: reopen using a new configuration/gate.
/// Invalidate BEFORE releasing access. An already committed write is reported
/// by its receipt; revocation cannot undo a durable source change.
public final class FolioSourceAccess: Sendable {
  private let revoked = Mutex(false)
  public init() {}
  public func revoke() { revoked.withLock { $0 = true } }
  func validate() throws {
    guard !revoked.withLock({ $0 }) else { throw FolioError.accountUnavailable }
  }
}
