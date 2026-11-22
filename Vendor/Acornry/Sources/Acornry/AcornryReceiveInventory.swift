import Foundation

/// Read-only observations of committed files and retained staging. A pending
/// observation never substitutes for the validation performed by retryImport.
public struct AcornryReceiveInventory: Sendable {
  public let active: [AcornryImportReceipt]
  public let archived: [AcornryImportReceipt]
  public let pendingImports: [AcornryPendingImport]

  public init(active: [AcornryImportReceipt], archived: [AcornryImportReceipt],
    pendingImports: [AcornryPendingImport]
  ) {
    self.active = active
    self.archived = archived
    self.pendingImports = pendingImports
  }
}
