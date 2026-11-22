import Foundation
import FolioKnowledge

public struct WikiCloudPublication: Codable, Sendable {
  public enum State: String, Codable, Sendable { case prepared, uncertain, published }
  public let operationID: UUID
  public let workspaceID: UUID
  public let sourcePath: String
  public let destinationPath: String
  public var state: State
}

extension WikiWorkspace {
  /// Publish a bounded source-only copy. The local original and all device-private state stay intact.
  public func publishToCloud(containerIdentifier: String) async throws -> WikiWorkspaceLocation {
    try requireOpen()
    guard let account = FileManager.default.ubiquityIdentityToken else {
      throw WikiError.unavailable("iCloud 계정을 확인해 주세요.")
    }
    let container = try await WikiWorkspaceAccess.cloudContainer(identifier: containerIdentifier)
    try requireOpen(); try Task.checkCancellation()
    guard FileManager.default.ubiquityIdentityToken?.isEqual(account) == true else { throw WikiError.changedSource }
    let destination = container.appendingPathComponent("Documents/Workspaces/\(workspaceID.uuidString.lowercased())", isDirectory: true)
    guard !FileManager.default.fileExists(atPath: destination.path),
      !FileManager.default.isUbiquitousItem(at: destination) else {
      throw WikiError.conflict("같은 자료함이 이미 iCloud에 있습니다. iCloud 자료함 목록에서 열어 주세요.")
    }
    let transfers = receiptDirectory.deletingLastPathComponent().appendingPathComponent("CloudTransfers", isDirectory: true)
    try WikiLocalStorage.createDirectory(transfers)
    let operationID = UUID(); let recordURL = transfers.appendingPathComponent(operationID.uuidString + ".json")
    let stage = transfers.appendingPathComponent(operationID.uuidString, isDirectory: true)
    try Self.copySourceLayout(from: root, to: stage)
    var record = WikiCloudPublication(operationID: operationID, workspaceID: workspaceID,
      sourcePath: root.path, destinationPath: destination.path, state: .prepared)
    do {
      try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
      try Task.checkCancellation(); try requireOpen()
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard !FileManager.default.fileExists(atPath: destination.path) else { throw WikiError.changedSource }
      guard FileManager.default.ubiquityIdentityToken?.isEqual(account) == true else { throw WikiError.changedSource }
      record.state = .uncertain
      try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
    } catch {
      // No cloud effect was dispatched. Only our newly created local stage is removed.
      try? FileManager.default.removeItem(at: stage); throw error
    }
    do {
      try FileManager.default.setUbiquitous(true, itemAt: stage, destinationURL: destination)
      record.state = .published
      try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
    } catch {
      // A throwing transfer or receipt write may already have published files. Never retry or remove them.
      throw WikiError.unavailable("iCloud 연결 결과가 불확실합니다. iCloud 자료함 목록과 원문을 확인해 주세요. 기존 로컬 자료는 보존했으며 자동 재시도하지 않습니다. \(error.localizedDescription)")
    }
    return .managedCloud(containerIdentifier: containerIdentifier, workspaceID: workspaceID)
  }
}
