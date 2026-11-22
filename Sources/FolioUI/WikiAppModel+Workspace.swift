import Foundation
import FolioCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import FolioKnowledge
import FolioKnowledgeApple

extension WikiAppModel {
  public var supportsManagedCloud: Bool { cloudAccount.supportsManagedCloud }
  public var isCloudWorkspace: Bool { session.isCloudWorkspace }
  public var canPublishToCloud: Bool { supportsManagedCloud && hasOpenWorkspace && !isCloudWorkspace && !isBusy }
  public var cloudStatus: WikiCloudStatus? { snapshot.flatMap { cloudLibrary.statusByWorkspace[$0.workspace.id] } }
  public func refreshCloudLibrary() async { await cloudAccount.refreshLibrary() }
  public func cloudIdentityChanged() async {
    await cloudAccount.identityChanged { [weak self] in await self?.close() }
  }
  // A source is not admitted to user operations until its recovery files load.
  public var hasOpenWorkspace: Bool {
    !terminationRequested && session.hasOpenWorkspace && draftStore.isBound && draftStore.acceptsPrivateInput
      && (!session.isCloudWorkspace || cloudAccount.sourceMatchesCurrentIdentity)
  }
  // Input already in progress still belongs to the bound private recovery
  // repository while an account change is waiting to close that source.
  var canAcceptPrivateEdits: Bool {
    !terminationRequested && session.workspace != nil && protectedDataAvailable && draftStore.isBound && draftStore.acceptsPrivateInput
      && !documentLibrary.phase.isApplying
  }

  public func open(_ location: WikiWorkspaceLocation) async {
    await open(location, intent: .user)
  }

  private func open(_ location: WikiWorkspaceLocation, intent: FolioWorkspaceOpening.Intent) async {
    guard !terminationRequested else { return }
    // Account revocation owns close and forget as one lane. A later selection
    // can start only after both effects have finished for the previous source.
    await cloudAccount.waitForRevocation()
    guard !terminationRequested, hasStorageAccess else { return }
    guard !documentLibrary.phase.isApplying else { message = "문서 정리가 끝나면 자료함을 바꿀 수 있습니다."; return }
    await session.waitForClose()
    guard !terminationRequested else { return }
    guard protectedDataAvailable else { message = "잠금을 해제하면 자료를 열 수 있습니다."; return }
    #if os(iOS)
    guard UIApplication.shared.applicationState != .background else { return }
    #endif
    var openingToken: (any NSObjectProtocol)?
    if case .managedCloud = location {
      await cloudIdentityChanged()
      guard !terminationRequested else { return }
      openingToken = cloudAccount.currentToken
      guard cloudAccount.matchesCurrentIdentity(openingToken) else { message = "iCloud 연결을 확인해 주세요."; return }
    }
    let openingIdentityGeneration = cloudAccount.generation
    let accountID: UUID?
    let validateSourceAccess: @Sendable () throws -> Void
    do {
      if case .managedCloud = location {
        validateSourceAccess = try FolioSourceAdmission.cloudValidator(for: openingToken)
        accountID = try FolioCore.FolioCloudIdentity.accountID(for: openingToken, directory: FolioDraftRepository.storageDirectory())
        try validateSourceAccess()
      } else {
        accountID = nil
        validateSourceAccess = {}
      }
    } catch {
      message = "iCloud 계정을 확인할 수 없습니다. 연결을 확인한 뒤 자료함을 다시 열어 주세요."
      return
    }
    let opening = FolioWorkspaceOpening.resolve(intent: intent, requested: location, current: self.location,
      pending: session.pendingLocation, hasSnapshot: snapshot != nil, isSuspended: isSuspended)
    let preserveNavigation = opening.preservesNavigation
    guard preserveDraftsForWorkspaceChange(opening: opening) else { return }
    mergeSelection = nil
    session.advanceDocumentGeneration(for: opening)
    draftStore.stopPrivateInput(); documentLibrary.reset()
    draftStore.detach()
    for window in windows.values { window.invalidateSearch() }
    do {
      let completedGeneration = try await session.open(location, preserveNavigation: preserveNavigation,
        knowledgeAccountScope: accountID, validateSourceAccess: validateSourceAccess, willReplace: {
        draftStore.clear()
        if !preserveNavigation { for window in windows.values { window.resetNavigation() } }
      }, didLoad: { snapshot in
        guard !terminationRequested else { throw CocoaError(.userCancelled) }
        libraryHistory.restoreRecent(workspaceID: snapshot.workspace.id)
        draftStore.clear()
        if !preserveNavigation { for window in windows.values { window.query = "" } }
        if case .managedCloud = location {
          guard cloudAccount.matchesCurrentIdentity(openingToken) else { throw WikiError.changedSource }
          try validateSourceAccess()
        }
        try draftStore.bind(.workspace(snapshot.workspace.id, location: location, accountID: accountID))
        if case .managedCloud = location, !cloudAccount.matchesCurrentIdentity(openingToken) {
          draftStore.detach()
          draftStore.clear()
          throw WikiError.changedSource
        }
        cloudAccount.bindSourceIdentity(openingToken)
        if !preserveNavigation { for window in windows.values { window.selectedDocumentID = snapshot.documents.first?.id } }
        message = nil
      })
      guard let admitted = FolioCloudIdentity.Opening(completedGeneration: completedGeneration,
        currentGeneration: workspaceGeneration, requestedLocation: location, currentLocation: session.location) else { return }
      if case .managedCloud = location {
        await cloudIdentityChanged()
        guard admitted.isCurrent(generation: workspaceGeneration, location: session.location) else { return }
        if isCloudWorkspace, cloudAccount.generation != openingIdentityGeneration {
          await cloudAccount.revokeSource { [weak self] in await self?.close() }
        }
      }
    } catch {
      message = error.localizedDescription
      if case WikiError.conflict(let path) = error { await showConflict(path: path) }
    }
  }

  public func restore() async {
    guard workspace == nil, let location = session.restoredLocation else { return }
    await open(location)
  }

  #if os(macOS)
  public func openExternal(_ url: URL, create: Bool) async {
    guard hasStorageAccess else { return }
    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      if create {
        guard preserveDraftsForWorkspaceChange() else { return }
        try WikiWorkspace.create(at: url, name: url.lastPathComponent)
      }
      await open(.externalMac(bookmark: try WikiWorkspaceAccess.bookmark(for: url)))
    } catch { message = error.localizedDescription }
  }

  public func connectSEMI() async {
    guard hasOpenWorkspace else {
      message = "편집 복구본을 확인한 뒤 자료함을 다시 열어 주세요."
      return
    }
    await session.connect()
  }
  #endif

  #if os(macOS)
  public func revealWorkspace() async {
    guard let workspace else { return }
    let root = workspace.root
    NSWorkspace.shared.activateFileViewerSelecting([root])
  }
  #endif

  public func close() async {
    await documentLibrary.drain()
    await nearby.stop()
    await session.close { [weak self] in self?.prepareWorkspaceClose() }
  }

  private func prepareWorkspaceClose() {
    mergeSelection = nil
    draftStore.stopPrivateInput()
    draftStore.cancelPendingWrite(); persistDrafts()
    for window in windows.values { window.invalidateSearch() }
  }

  #if os(iOS)
  /// Called synchronously at the application lifecycle boundary before awaiting drain.
  public func restrictMobileAccess(protectedDataAvailable: Bool) {
    mergeSelection = nil
    draftStore.stopPrivateInput()
    nearby.restrict()
    session.restrictMobileAccess(protectedDataAvailable: protectedDataAvailable) {
      persistDrafts(); draftStore.cancelPendingWrite()
    }
  }
  public func pauseMobileObservation() async { await access.pauseObservation() }
  public func suspendMobile() async {
    await documentLibrary.drain()
    await nearby.stop()
    await access.pauseObservation()
    await session.closeWorkspace(preserveView: true) { prepareWorkspaceClose() }
  }
  func prepareStorageAccess() async {
    let generation = workspaceGeneration
    if let problem = await storageAccess.prepare(isCurrent: { session.isCurrent(generation) }),
      session.isCurrent(generation) { message = problem }
  }
  public func resumeMobile() async {
    await documentLibrary.drain()
    await prepareStorageAccess()
    guard protectedDataAvailable, hasStorageAccess else { return }
    nearby.allowAccess()
    await nearby.ready()
    await refreshCloudLibrary()
    guard let location = session.pendingLocation ?? location else { await restore(); return }
    await open(location, intent: .lifecycleResume)
  }
  #endif

  /// Workspace changes keep private drafts; they never commit Markdown implicitly.
  func preserveDraftsForWorkspaceChange(opening: FolioWorkspaceOpening = .replace) -> Bool {
    do {
      try opening.checkpoint(hasMetadataEditor: windows.values.contains(where: { $0.metadataSelection != nil }),
        isSaving: !savingDocuments.isEmpty, isLinking: !linkingAttachments.isEmpty,
        isApplyingDocumentChanges: documentLibrary.phase.isApplying) { try draftStore.checkpoint() }
      return true
    } catch FolioWorkspaceOpening.AdmissionError.documentMutation {
      message = "문서 정리가 끝나면 자료함을 바꿀 수 있습니다."
    } catch FolioWorkspaceOpening.AdmissionError.metadataEditing {
      message = "제목·태그 편집을 마친 뒤 자료함을 바꿀 수 있습니다."
    } catch FolioWorkspaceOpening.AdmissionError.sourceWrite {
      message = "저장이 끝나면 자료함을 바꿀 수 있습니다."
    } catch {
      message = "편집 복구본을 보존하지 못해 자료함을 바꾸지 않았습니다. " + error.localizedDescription
    }
    return false
  }
}
