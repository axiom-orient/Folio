import Foundation
import FolioKnowledge

public struct WikiConflictVersion: Sendable, Identifiable {
  public let id: String
  public let bytes: Data
  public var text: String { String(data: bytes, encoding: .utf8) ?? "이 버전은 UTF-8 Markdown이 아닙니다." }
  public let modifiedAt: Date?
  public let isCurrent: Bool
}

extension WikiWorkspace {
  public func conflictVersions(relativePath: String) throws -> [WikiConflictVersion] {
    try requireOpen()
    let path = try WikiPath.validate(relativePath)
    let current = try CoordinatedFiles.read(root: root, path: path)
    let url = root.appendingPathComponent(path)
    var result = [WikiConflictVersion(id: SourceDigest.sha256(current), bytes: current,
      modifiedAt: NSFileVersion.currentVersionOfItem(at: url)?.modificationDate, isCurrent: true)]
    let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
    guard versions.count <= 32 else { throw WikiError.unavailable("Inspect more than 32 conflicting versions in Files/Finder.") }
    for version in versions {
      let bytes = try CoordinatedFiles.read(root: version.url.deletingLastPathComponent(), path: version.url.lastPathComponent)
      let hash = SourceDigest.sha256(bytes)
      if result.contains(where: { $0.id == hash }) { continue }
      result.append(WikiConflictVersion(id: hash, bytes: bytes,
        modifiedAt: version.modificationDate, isCurrent: false))
    }
    return result
  }

  /// Explicit user resolution. Archive every observed byte version before publishing
  /// the chosen one; mark only the captured conflict objects resolved afterward.
  public func resolveConflict(relativePath: String, expectedCurrentRevision: String, chosenRevision: String) async throws -> WikiWriteReceipt {
    try requireOpen()
    let path = try WikiPath.validate(relativePath)
    guard ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
      throw WikiError.invalidPath("Conflict resolution is limited to Markdown source.")
    }
    let url = root.appendingPathComponent(path)
    let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
    guard !conflicts.isEmpty else { throw WikiError.changedSource }
    let versions = try conflictVersions(relativePath: path)
    guard versions.first?.id == expectedCurrentRevision,
      let chosen = versions.first(where: { $0.id == chosenRevision }) else { throw WikiError.changedSource }
    let chosenBytes = chosen.bytes
    if path == "_ontology.md" { _ = try WikiOntology(bytes: chosenBytes) }
    else if path == "_workspace.md" {
      let currentIdentity = try WikiMarkdownParser.workspace(bytes: versions[0].bytes)
      guard try WikiMarkdownParser.workspace(bytes: chosenBytes).id == currentIdentity.id else {
        throw WikiError.invalidSource("Conflict resolution cannot change workspace identity.")
      }
    } else { _ = try WikiMarkdownParser.document(relativePath: path, bytes: chosenBytes) }
    let operationID = UUID()
    let archive = receiptDirectory.appendingPathComponent("ConflictCopies/\(operationID.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    for version in versions {
      try CoordinatedFiles.write(root: archive, path: version.id + ".md", expectedRevision: nil, bytes: version.bytes)
    }
    try Task.checkCancellation()
    try CoordinatedFiles.write(root: root, path: path, expectedRevision: expectedCurrentRevision,
      bytes: chosenBytes, resolvingConflict: true)
    for version in conflicts { version.isResolved = true }
    do {
      _ = try await refresh()
      return WikiWriteReceipt(operationID: operationID, relativePath: path, previousRevision: expectedCurrentRevision,
        sourceRevision: chosenRevision, projectionUpdated: true, diagnostic: nil)
    } catch {
      return WikiWriteReceipt(operationID: operationID, relativePath: path, previousRevision: expectedCurrentRevision,
        sourceRevision: chosenRevision, projectionUpdated: false, diagnostic: "Conflict source was resolved; projection refresh is pending.")
    }
  }
}
