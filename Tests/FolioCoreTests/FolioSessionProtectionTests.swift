import Foundation
import Synchronization
import Testing
import FolioCore
import FolioKnowledge
import FolioKnowledgeApple

@MainActor
struct FolioSessionProtectionTests {
  @Test func changedSourceKeepsTheSourceAndDraft() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let source = try fixture.makeWorkspace(named: "research")
    let session = FolioSession(configuration: try fixture.configuration())
    try await session.openWorkspace(at: source)
    try await session.openDocument(id: WorkspaceFixture.documentID)
    let draft = WorkspaceFixture.note("새 논문을 읽고 근거 문단의 위치를 추가한다.")
    try session.updateDraft(draft)
    let changed = WorkspaceFixture.note("다른 편집자가 실험 조건과 한계를 보완했다.")
    try Data(changed.utf8).write(to: fixture.noteURL(in: source), options: .atomic)

    await #expect(throws: (any Error).self) { try await session.save() }
    #expect(try Data(contentsOf: fixture.noteURL(in: source)) == Data(changed.utf8))
    #expect(session.draftText == draft)
    #expect(session.isDirty)

    let reviewed = try await session.readCurrentSource()
    let later = WorkspaceFixture.note("다른 편집자가 후속 연구의 표본과 관찰 기간을 추가했다.")
    try Data(later.utf8).write(to: fixture.noteURL(in: source), options: .atomic)
    await #expect(throws: (any Error).self) {
      try await session.adoptReviewedSource(reviewed,
        mergedText: WorkspaceFixture.note("검토한 실험 조건에 내 근거 문단을 함께 정리한다."))
    }
    #expect(try Data(contentsOf: fixture.noteURL(in: source)) == Data(later.utf8))
    #expect(session.draftText == draft)

    let latestReview = try await session.readCurrentSource()
    let merged = WorkspaceFixture.note("표본과 관찰 기간을 확인하고 내 근거 문단을 함께 정리한다.")
    try await session.adoptReviewedSource(latestReview, mergedText: merged)
    let beforeSave = WorkspaceFixture.note("다른 편집자가 재현 실험의 결측 자료 처리 방법을 보완했다.")
    try Data(beforeSave.utf8).write(to: fixture.noteURL(in: source), options: .atomic)
    await #expect(throws: (any Error).self) { try await session.save() }
    #expect(try Data(contentsOf: fixture.noteURL(in: source)) == Data(beforeSave.utf8))
    #expect(session.draftText == merged)

    let finalReview = try await session.readCurrentSource()
    let finalMerged = WorkspaceFixture.note("표본, 관찰 기간, 결측 자료 처리 방법을 확인하고 근거 문단을 함께 기록한다.")
    try await session.adoptReviewedSource(finalReview, mergedText: finalMerged)
    let receipt = try await session.save()
    let saved = try Data(contentsOf: fixture.noteURL(in: source))
    #expect(saved == Data(finalMerged.utf8))
    #expect(receipt.sourceRevision == SourceDigest.sha256(saved))
    #expect(!session.isDirty)
    try await session.close()
  }

  @Test func closingAndReopeningRestoresDraftWithoutSavingSource() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let source = try fixture.makeWorkspace(named: "project")
    let configuration = try fixture.configuration()
    let original = try Data(contentsOf: fixture.noteURL(in: source))
    let draft = WorkspaceFixture.note("다음 회의에서는 검색 결과가 원문 근거와 연결되는지 검토한다.")
      .replacingOccurrences(of: "# 근거를 남기는 연구 기록", with: "# 연구 문서 검토 계획")
    let first = FolioSession(configuration: configuration)
    try await first.openWorkspace(at: source)
    try await first.openDocument(id: WorkspaceFixture.documentID)
    try first.updateDraft(draft)
    try await first.close()

    let restored = FolioSession(configuration: configuration)
    try await restored.openWorkspace(at: source)
    try await restored.openDocument(id: WorkspaceFixture.documentID)
    #expect(restored.draftText == draft)
    #expect(restored.isDirty)
    #expect(try Data(contentsOf: fixture.noteURL(in: source)) == original)
    let receipt = try await restored.save()
    let saved = try Data(contentsOf: fixture.noteURL(in: source))
    #expect(saved == Data(draft.utf8))
    #expect(receipt.sourceRevision == SourceDigest.sha256(saved))
    #expect(!restored.isDirty)
    #expect(restored.selectedDocument?.title == "연구 문서 검토 계획")
    let changedID = draft.replacingOccurrences(of: WorkspaceFixture.documentID, with: UUID().uuidString)
    try restored.updateDraft(changedID)
    await #expect(throws: FolioError.documentIdentityChanged) { try await restored.save() }
    #expect(try Data(contentsOf: fixture.noteURL(in: source)) == Data(draft.utf8))
    #expect(restored.draftText == changedID)
    try await restored.close()
  }

  @Test func identicalIDsStaySeparateAcrossSourceRootsAndHosts() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let legacy = fixture.directory.appendingPathComponent("SourceWiki")
    let existing = fixture.directory.appendingPathComponent("Folio")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
    let legacyBytes = Data("기존 연구 초안은 호스트가 이관을 결정할 때까지 보존한다.".utf8)
    let existingBytes = Data("기존 자료함의 보관 위치와 문서를 임의로 합치지 않는다.".utf8)
    let legacyFile = legacy.appendingPathComponent("draft.md")
    let existingFile = existing.appendingPathComponent("guide.md")
    try legacyBytes.write(to: legacyFile, options: .withoutOverwriting)
    try existingBytes.write(to: existingFile, options: .withoutOverwriting)
    let migrationBefore = UserDefaults.standard.object(forKey: "Folio.storageMigrationCompleted") as? Bool
    let mobileMigrationBefore = UserDefaults.standard.object(forKey: "Folio.firstUnlockStorageMigration.v1") as? Bool
    let sourceA = try fixture.makeWorkspace(named: "personal-research")
    let sourceB = try fixture.makeWorkspace(named: "work-research")
    let original = WorkspaceFixture.note("연구 기록에는 출처와 판단의 한계를 함께 남긴다.")
    let draft = WorkspaceFixture.note("개인 연구의 추가 해석은 이 자료함의 초안에만 보관한다.")
    let first = FolioSession(configuration: try fixture.configuration())
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("host-state").path))
    try await first.openWorkspace(at: sourceA)
    try await first.openDocument(id: WorkspaceFixture.documentID)
    try first.updateDraft(draft)
    try await first.openWorkspace(at: sourceA)
    #expect(first.draftText == draft)
    let staleEditor = try #require(first.editingTarget)
    try await first.openWorkspace(at: sourceB)
    try await first.openDocument(id: WorkspaceFixture.documentID)
    #expect(throws: FolioError.changedSource) { try first.updateDraft(draft, target: staleEditor) }
    await #expect(throws: FolioError.changedSource) { try await first.save(target: staleEditor) }
    #expect(first.draftText == original)
    try await first.close()

    let otherRoot = FolioSession(configuration: try fixture.configuration())
    try await otherRoot.openWorkspace(at: sourceB)
    try await otherRoot.openDocument(id: WorkspaceFixture.documentID)
    #expect(otherRoot.draftText == original)
    #expect(!otherRoot.isDirty)
    try await otherRoot.close()

    let otherHost = FolioSession(configuration: try fixture.configuration(namespace: "org.example.other-host"))
    try await otherHost.openWorkspace(at: sourceA)
    try await otherHost.openDocument(id: WorkspaceFixture.documentID)
    #expect(otherHost.draftText == original)
    #expect(!otherHost.isDirty)
    try await otherHost.close()

    let originalHost = FolioSession(configuration: try fixture.configuration())
    try await originalHost.openWorkspace(at: sourceA)
    try await originalHost.openDocument(id: WorkspaceFixture.documentID)
    #expect(originalHost.draftText == draft)
    try await originalHost.close()
    #expect(try Data(contentsOf: legacyFile) == legacyBytes)
    #expect(try Data(contentsOf: existingFile) == existingBytes)
    #expect((UserDefaults.standard.object(forKey: "Folio.storageMigrationCompleted") as? Bool) == migrationBefore)
    #expect((UserDefaults.standard.object(forKey: "Folio.firstUnlockStorageMigration.v1") as? Bool) == mobileMigrationBefore)
  }

  @Test func sourceAccessRevokedDuringCoordinationCannotPublishPreparedSave() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let root = try fixture.makeWorkspace(named: "reviewed-source")
    let original = try Data(contentsOf: fixture.noteURL(in: root))
    let revoked = Mutex(false)
    let workspace = try WikiWorkspace(root: root,
      localStateDirectory: fixture.directory.appendingPathComponent("writer-state"),
      validateSourceAccess: {
        guard !revoked.withLock({ $0 }) else { throw WikiError.unavailable("Host access was revoked.") }
      })
    let prepared = try await workspace.prepareRawSave(relativePath: "notes/research.md",
      expectedRevision: SourceDigest.sha256(original),
      replacement: WorkspaceFixture.note("검토한 변경은 저장 직전에도 접근 권한이 유효할 때만 반영한다."),
      operationID: UUID())
    // Revoke only when source coordination asks its presenter to relinquish
    // writing access. Earlier actor admission checks have already succeeded.
    let presenter = RevokingSourcePresenter(url: fixture.noteURL(in: root)) {
      revoked.withLock { $0 = true }
    }
    NSFileCoordinator.addFilePresenter(presenter)
    defer { NSFileCoordinator.removeFilePresenter(presenter) }

    await #expect(throws: (any Error).self) { try await workspace.execute(prepared) }
    #expect(revoked.withLock { $0 })
    #expect(try Data(contentsOf: fixture.noteURL(in: root)) == original)
    let status = try await workspace.operationStatus(prepared.operationID)
    #expect(status.state == .uncertain)
    await workspace.close()
  }
}

private final class RevokingSourcePresenter: NSObject, NSFilePresenter, Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue
  private let revoke: @Sendable () -> Void

  init(url: URL, revoke: @escaping @Sendable () -> Void) {
    presentedItemURL = url
    presentedItemOperationQueue = OperationQueue()
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
    self.revoke = revoke
  }

  func relinquishPresentedItem(toWriter writer: @Sendable @escaping ((@Sendable () -> Void)?) -> Void) {
    revoke()
    writer(nil)
  }
}

private struct WorkspaceFixture {
  static let workspaceID = "34f7cc2c-e445-4199-880e-f1a67018e421"
  static let documentID = "7acd0594-d9f2-4e70-8ec7-df9919e1dd63"
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioSDK-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }

  func configuration(namespace: String = "org.example.research-host") throws -> FolioConfiguration {
    try FolioConfiguration(stateDirectory: directory.appendingPathComponent("host-state"), namespace: namespace)
  }

  func makeWorkspace(named name: String) throws -> URL {
    let root = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
    let marker = "---\nid: \(Self.workspaceID)\nkind: workspace\nschema: 1\nname: Research notes\n---\n"
    try Data(marker.utf8).write(to: root.appendingPathComponent("_workspace.md"), options: .withoutOverwriting)
    try Data(Self.note("연구 기록에는 출처와 판단의 한계를 함께 남긴다.").utf8)
      .write(to: noteURL(in: root), options: .withoutOverwriting)
    return root
  }

  static func note(_ body: String) -> String {
    "---\nid: \(documentID)\n---\n\n# 근거를 남기는 연구 기록\n\n\(body)\n"
  }

  func noteURL(in root: URL) -> URL { root.appendingPathComponent("notes/research.md") }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
