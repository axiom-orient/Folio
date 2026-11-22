import Foundation

public enum VaultImporter {
  /// Imports a bounded local snapshot without changing the source or replacing output.
  public static func run(_ request: VaultImportRequest) throws -> VaultImportResult {
    let snapshot = try VaultSnapshot(request)
    let plan = try VaultPlan(snapshot: snapshot, name: request.name, id: UUID(), createdAt: Date())
    try VaultCommit.write(plan, locations: snapshot.locations)
    return plan.result
  }
}
