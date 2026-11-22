import Foundation
import FolioKnowledge
import FolioKnowledgeApple

extension WikiAppModel {
  public func localWorkspaces() -> [WikiManagedWorkspace] {
    guard hasStorageAccess else { return [] }
    do { return try WikiWorkspaceAccess.localWorkspaces() }
    catch { message = error.localizedDescription; return [] }
  }

  func isSelectedWorkspace(_ location: WikiWorkspaceLocation) -> Bool {
    hasOpenWorkspace && session.location == location
  }

  var currentWorkspaceLocation: WikiWorkspaceLocation? { hasOpenWorkspace ? session.location : nil }

  /// Archiving changes catalog organization only. Source URLs, drafts and
  /// operation receipts retain their existing owners and original locations.
  func setLibraryArchived(_ id: FolioLibraryIdentity, archived: Bool) {
    do { try libraryHistory.setArchived(id: id, archived: archived) }
    catch { message = "자료함 보관 목록을 저장하지 못했습니다. " + error.localizedDescription }
  }

  public func managedWorkspaces() -> [WikiManagedWorkspace] {
    guard hasStorageAccess else { return [] }
    return cloudLibrary.workspaces
  }

  public func createLocal(name: String = "내 위키") async {
    _ = await createLibrary(name: name, useCloud: false)
  }

  public func createManaged(name: String = "내 위키") async {
    _ = await createLibrary(name: name, useCloud: true)
  }

  /// A form closes only after the created source is actually open.
  func createLibrary(name rawName: String, useCloud: Bool) async -> WikiWorkspaceLocation? {
    guard let name = FolioInput.name(rawName) else { message = "자료함 이름을 입력해 주세요."; return nil }
    guard hasStorageAccess, protectedDataAvailable, !isBusy, preserveDraftsForWorkspaceChange() else { return nil }
    let generation = workspaceGeneration
    isBusy = true
    defer { if generation == workspaceGeneration { isBusy = false } }
    do {
      let created: WikiWorkspaceLocation
      if useCloud {
        guard let container = Bundle.main.object(forInfoDictionaryKey: "FolioCloudContainerID") as? String else {
          throw WikiError.unavailable("이 빌드에는 iCloud 연결이 설정되지 않았습니다.")
        }
        created = try await session.access.createManaged(name: name, containerIdentifier: container)
      } else {
        let id = UUID()
        let root = try WikiWorkspaceAccess.localRoot(workspaceID: id, create: true)
        try WikiWorkspace.create(at: root, name: name, workspaceID: id)
        created = .localManaged(workspaceID: id)
      }
      guard generation == workspaceGeneration, protectedDataAvailable else { return created }
      await open(created)
      if useCloud { await refreshCloudLibrary() }
      return created
    } catch { if generation == workspaceGeneration { message = error.localizedDescription }; return nil }
  }

  public func publishToCloud() async {
    guard canPublishToCloud, let workspace,
      let container = Bundle.main.object(forInfoDictionaryKey: "FolioCloudContainerID") as? String else { return }
    guard !drafts.values.contains(where: \.isDirty), savingDocuments.isEmpty else {
      message = "편집 중인 문서를 먼저 저장하거나 되돌린 후 iCloud에 연결해 주세요."; return
    }
    let current = workspaceGeneration
    isBusy = true
    do {
      let destination = try await workspace.publishToCloud(containerIdentifier: container)
      guard current == workspaceGeneration else { return }
      isBusy = false
      await open(destination); await refreshCloudLibrary()
      if session.location == destination, hasOpenWorkspace {
        message = nil
      } else {
        message = "원문은 iCloud에 게시했지만 자료함을 열지 못했습니다. 기존 로컬 자료는 보존했습니다. " + (message ?? "iCloud 자료함 목록에서 다시 열어 주세요.")
      }
    } catch {
      guard current == workspaceGeneration else { return }
      isBusy = false; message = error.localizedDescription
      await refreshCloudLibrary()
    }
  }
}
