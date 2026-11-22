import Foundation

public struct WikiPreparedEdit: Encodable, Sendable {
  public let operationID: UUID
  public let workspaceID: UUID
  public let workspaceRevision: String
  public let relativePath: String
  public let expectedRevision: String?
  public let resultRevision: String
  public let replacementBytes: Data
  public let before: String
  public let after: String
}

public struct WikiWriteReceipt: Codable, Sendable {
  public let operationID: UUID
  public let relativePath: String
  public let previousRevision: String?
  public let sourceRevision: String
  public let idempotencyKeySHA256: String?
  public let projectionUpdated: Bool
  public let diagnostic: String?
  public init(operationID: UUID, relativePath: String, previousRevision: String?, sourceRevision: String,
    idempotencyKeySHA256: String? = nil, projectionUpdated: Bool, diagnostic: String?
  ) {
    self.operationID = operationID; self.relativePath = relativePath; self.previousRevision = previousRevision
    self.sourceRevision = sourceRevision; self.idempotencyKeySHA256 = idempotencyKeySHA256
    self.projectionUpdated = projectionUpdated; self.diagnostic = diagnostic
  }
}

public struct WikiOperationStatus: Codable, Sendable {
  public enum State: String, Codable, Sendable { case notObserved, uncertain, committed }
  public let operationID: UUID
  public let state: State
  public let receipt: WikiWriteReceipt?
}
