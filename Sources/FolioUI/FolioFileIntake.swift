import FolioNearbyTransport
import Foundation
import FolioKnowledgeApple
import Observation

/// The destination visible to the user, including the concrete source location.
/// Workspace UUIDs alone cannot distinguish retained local and iCloud copies.
struct FolioReceivedTarget: Equatable {
  let location: WikiWorkspaceLocation
  let root: URL
  let workspaceID: UUID
  let generation: Int

  @MainActor static func current(in session: FolioWorkspaceSession) -> Self? {
    guard session.hasOpenWorkspace, let location = session.location,
      let workspace = session.workspace, let root = session.openedSourceRoot,
      let snapshot = session.snapshot, root == workspace.root,
      snapshot.workspace.id == workspace.workspaceID else { return nil }
    return Self(location: location, root: root, workspaceID: workspace.workspaceID, generation: session.generation)
  }

  var storageTitle: String {
    switch location {
    case .localManaged: "이 기기"
    case .managedCloud: "iCloud"
    case .externalMac: "원문 폴더"
    }
  }
}

/// Owns attachment admission, received-file imports, and attachment previews.
/// Source writes and transport receipts stay with their existing owners.
@MainActor @Observable
final class FolioFileIntake {
  typealias DidLink = @MainActor (WikiAttachmentImport, Int) async -> Bool
  typealias ImportSource = @MainActor (URL) async -> Bool

  private(set) var linkingAttachments: Set<UUID> = []
  private(set) var isImportingReceived = false
  var previewURL: URL?
  @ObservationIgnored var onMessage: (@MainActor (String?) -> Void)?
  /// Rechecks account and recovery readiness at each source-effect boundary.
  @ObservationIgnored var canWriteSource: (@MainActor () -> Bool)?
  @ObservationIgnored var recoveryScope: (@MainActor () -> URL?)?

  private let session: FolioWorkspaceSession
  private let documentLibrary: FolioDocumentLibrary
  private let nearby: FolioNearbyModel
  private struct CaptureKey: Hashable {
    let source: URL
    let root: URL
    let workspaceID: UUID
    let recoveryScope: URL
  }
  // Keep only unfinished captures. The durable attachment ledger remains the
  // recovery owner; this identity also survives received-file staging changes.
  private var captures: [CaptureKey: UUID] = [:]
  private var capturing: Set<CaptureKey> = []

  init(session: FolioWorkspaceSession, documentLibrary: FolioDocumentLibrary, nearby: FolioNearbyModel) {
    self.session = session
    self.documentLibrary = documentLibrary
    self.nearby = nearby
  }

  func hasPendingCapture(_ source: URL) -> Bool {
    guard let workspace = session.workspace, let scope = recoveryScope?() else { return false }
    return captures[CaptureKey(source: source.standardizedFileURL, root: workspace.root,
      workspaceID: workspace.workspaceID, recoveryScope: scope)] != nil
  }

  func capture(_ url: URL, expectedTarget: FolioReceivedTarget? = nil, sourceIdentity: URL? = nil,
    didLink: DidLink
  ) async -> Bool {
    guard canWriteSource?() == true, session.hasOpenWorkspace, let workspace = session.workspace, let scope = recoveryScope?(),
      expectedTarget == nil || expectedTarget == FolioReceivedTarget.current(in: session) else {
      onMessage?("자료함이 바뀌었습니다. 추가할 자료함에서 파일을 다시 선택하세요.")
      return false
    }
    let key = CaptureKey(source: (sourceIdentity ?? url).standardizedFileURL, root: workspace.root,
      workspaceID: workspace.workspaceID, recoveryScope: scope)
    guard capturing.insert(key).inserted else { return false }
    defer { capturing.remove(key) }
    let generation = session.generation
    let previousOperation = captures[key]
    let operationID = previousOperation ?? UUID()
    captures[key] = operationID
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let record: WikiAttachmentImport
      if let previousOperation {
        guard let observed = try await workspace.observedAttachmentImport(previousOperation) else {
          captures.removeValue(forKey: key)
          if generation == session.generation, canWriteSource?() == true {
            onMessage?("이전 첨부 복사가 반영되지 않았습니다. ‘추가’를 눌러 다시 가져오세요.")
          }
          return false
        }
        record = observed
      } else { record = try await workspace.importAttachment(fromSelectedURL: url, operationID: operationID) }
      guard generation == session.generation, canWriteSource?() == true,
        expectedTarget == nil || expectedTarget == FolioReceivedTarget.current(in: session) else {
        return false
      }
      let linked = await link(record, didLink: didLink)
      if linked { captures.removeValue(forKey: key) }
      return linked
    } catch {
      // Only discard a definitely unpublished attempt. With an intent or
      // unreadable state, the next call must observe this same operation first.
      if (try? await workspace.hasAttachmentImportIntent(operationID)) == false {
        captures.removeValue(forKey: key)
      }
      _ = try? await session.refreshPendingAttachments(from: workspace, generation: generation)
      guard generation == session.generation, canWriteSource?() == true else { return false }
      onMessage?(error.localizedDescription)
    }
    return false
  }

  func link(_ record: WikiAttachmentImport, didLink: DidLink) async -> Bool {
    guard canWriteSource?() == true, !documentLibrary.phase.isApplying, session.hasOpenWorkspace, let workspace = session.workspace,
      linkingAttachments.insert(record.id).inserted else { return false }
    defer { linkingAttachments.remove(record.id) }
    let generation = session.generation
    do {
      try await FolioAttachmentNotes.link(record, in: workspace)
      guard generation == session.generation, canWriteSource?() == true else { return false }
      await session.refresh()
      guard generation == session.generation, canWriteSource?() == true else { return false }
      guard await didLink(record, generation), generation == session.generation,
        canWriteSource?() == true else { return false }
      onMessage?(nil)
      return true
    } catch {
      _ = try? await session.refreshPendingAttachments(from: workspace, generation: generation)
      guard session.isCurrent(generation) else { return false }
      onMessage?("첨부는 \(record.relativePath)에 보존했습니다. 연결 노트 저장: \(error.localizedDescription)")
    }
    return false
  }

  /// Archive only after a confirmed source import; transport receipts survive.
  func importReceived(_ file: AcornrySavedFile, receipt: AcornryImportReceipt, target: FolioReceivedTarget?,
    importSource: ImportSource, didLink: DidLink
  ) async -> Bool {
    guard !isImportingReceived, !(session.isBusy || documentLibrary.phase.isApplying),
      session.protectedDataAvailable else { return false }
    let isArchive = FolioTransferFileKind(url: file.fileURL) == .archive
    if !isArchive, (canWriteSource?() != true || target == nil || target != FolioReceivedTarget.current(in: session)) {
      onMessage?("자료함이 바뀌었습니다. 받은 파일을 다시 선택해 주세요.")
      return false
    }
    isImportingReceived = true
    defer { isImportingReceived = false }
    let expectedWorkspace = session.snapshot?.workspace.id
    let generation = session.generation
    do {
      let url = try await nearby.validatedFile(file, transferID: receipt.transferID)
      let copy = try await FolioTransferStorage.copyForSending(url)
      defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
      guard generation == session.generation, session.snapshot?.workspace.id == expectedWorkspace, session.protectedDataAvailable,
        isArchive || (canWriteSource?() == true && target == FolioReceivedTarget.current(in: session)) else {
        onMessage?("자료함이 바뀌었습니다. 받은 파일을 다시 선택해 주세요.")
        return false
      }
      let imported: Bool
      switch FolioTransferFileKind(url: copy) {
      case .document, .archive: imported = await importSource(copy)
      case .attachment: imported = await capture(copy, expectedTarget: target, sourceIdentity: file.fileURL, didLink: didLink)
      }
      guard imported else { return false }
      if !isArchive, (canWriteSource?() != true || target != FolioReceivedTarget.current(in: session)) {
        onMessage?("파일은 원래 자료함에 추가되었지만 현재 자료함이 바뀌었습니다. 받은 원본과 전송 기록은 보존했습니다.")
        return false
      }
      if receipt.state == .completed, nearby.received.contains(where: { $0.transferID == receipt.transferID }) {
        await nearby.moveReceived(receipt.transferID, toArchive: true)
      }
      return true
    } catch { onMessage?("받은 파일을 추가하지 못했습니다. " + error.localizedDescription) }
    return false
  }

  func preview(path: String) async {
    guard session.hasOpenWorkspace, let workspace = session.workspace else { return }
    let generation = session.generation
    do {
      let url = try await workspace.previewAttachment(relativePath: path)
      if generation == session.generation { previewURL = url }
    } catch {
      if generation == session.generation { onMessage?(error.localizedDescription) }
    }
  }
}
