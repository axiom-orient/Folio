import Foundation
import Testing
@testable import FolioCore
import FolioKnowledge

@MainActor
struct FolioRecoveryAndSearchTests {
  @Test func freshStateUnderSystemTemporaryDirectoryRemainsUsable() async throws {
    let fixture = try RecoverySearchFixture()
    defer { fixture.remove() }
    let source = try fixture.makeWorkspace(documentCount: 1)
    let session = FolioSession(configuration: try fixture.configuration())
    try await session.openWorkspace(at: source)
    #expect(session.snapshot?.documents.count == 1)
    try await session.close()
  }

  @Test func reviewedUncertainSavePreservesItsRecordBeforeASeparateSave() async throws {
    let fixture = try RecoverySearchFixture()
    defer { fixture.remove() }
    let source = try fixture.makeWorkspace(documentCount: 1)
    let note = fixture.noteURL(in: source, number: 1)
    let original = try Data(contentsOf: note)
    let draft = RecoverySearchFixture.note(number: 1,
      body: "evidence 초안에는 추가로 읽은 논문의 출처와 재현 조건을 기록한다.")
    let access = FolioSourceAccess()
    let first = FolioSession(configuration: try fixture.configuration(sourceAccess: access))
    try await first.openWorkspace(at: source)
    try await first.openDocument(id: RecoverySearchFixture.documentID(1))
    try first.updateDraft(draft)
    let presenter = RecoveryRevokingPresenter(url: note) { access.revoke() }
    NSFileCoordinator.addFilePresenter(presenter)
    await #expect(throws: (any Error).self) { try await first.save() }
    NSFileCoordinator.removeFilePresenter(presenter)
    let operationID = try #require(first.pendingOperationID)
    #expect(try Data(contentsOf: note) == original)
    #expect(first.draftText == draft)
    try await first.close()

    // A new access lifetime restores the previous account/location scope; no
    // operation is replayed merely because the source can be opened again.
    let restored = FolioSession(configuration: try fixture.configuration())
    try await restored.openWorkspace(at: source)
    try await restored.openDocument(id: RecoverySearchFixture.documentID(1))
    #expect(restored.pendingOperationID == operationID)
    switch try await restored.resolvePendingSave() {
    case .uncertain: break
    default: Issue.record("The source coordination failure must retain an uncertain operation.")
    }
    #expect(try Data(contentsOf: note) == original)
    let review = try await restored.readCurrentSource()
    await #expect(throws: (any Error).self) {
      try await restored.adoptReviewedSource(review, mergedText: draft, resolvingPendingSave: UUID())
    }
    #expect(restored.pendingOperationID == operationID)

    let received = RecoverySearchFixture.note(number: 1,
      body: "evidence 원문에는 다른 검토자가 실험의 제한 조건과 출처 위치를 보완했다.")
    try Data(received.utf8).write(to: note, options: .atomic)
    await #expect(throws: FolioError.changedSource) {
      try await restored.adoptReviewedSource(review, mergedText: draft, resolvingPendingSave: operationID)
    }
    #expect(restored.pendingOperationID == operationID)
    #expect(restored.draftText == draft)
    #expect(try Data(contentsOf: note) == Data(received.utf8))
    #expect(try fixture.reviewedArchives().isEmpty)

    let current = try await restored.readCurrentSource()
    let merged = RecoverySearchFixture.note(number: 1,
      body: "evidence 원문에 보완한 제한 조건과 출처 위치를 유지한다. 추가 논문의 출처와 재현 조건도 함께 기록한다.")
    try await restored.adoptReviewedSource(current, mergedText: merged, resolvingPendingSave: operationID)
    #expect(restored.pendingOperationID == nil)
    #expect(restored.draftText == merged)
    // Acknowledging an inspected result changes recovery state only.
    #expect(try Data(contentsOf: note) == Data(received.utf8))
    let archives = try fixture.reviewedArchives()
    let archive = try #require(archives.count == 1 ? archives.first : nil)
    #expect(archive.lastPathComponent == operationID.uuidString + ".json")
    let archiveBytes = try Data(contentsOf: archive)
    let archived = try JSONDecoder().decode(SDKDraft.self, from: archiveBytes)
    #expect(archived.pending?.operationID == operationID)
    #expect(archived.pending?.text == draft)
    #expect(archived.text == draft)
    #expect(archived.original == String(decoding: original, as: UTF8.self))
    #expect(archived.revision == SourceDigest.sha256(original))

    let receipt = try await restored.save()
    let saved = try Data(contentsOf: note)
    #expect(saved == Data(merged.utf8))
    #expect(receipt.sourceRevision == SourceDigest.sha256(saved))
    #expect(!restored.isDirty)
    #expect(try Data(contentsOf: archive) == archiveBytes)
    try await restored.close()
  }

  @Test func searchTraversesEveryResultAndRejectsStaleOrForeignContinuation() async throws {
    let fixture = try RecoverySearchFixture()
    defer { fixture.remove() }
    let source = try fixture.makeWorkspace(documentCount: 55)
    let session = FolioSession(configuration: try fixture.configuration())
    try await session.openWorkspace(at: source)
    let first = try await session.searchPage("evidence")
    #expect(first.results.count == 50)
    #expect(first.totalCount == 55)
    #expect(first.coverageComplete)
    #expect(first.diagnostics.isEmpty)
    let continuation = try #require(first.nextContinuation)
    let second = try await session.searchPage("evidence", continuation: continuation)
    #expect(second.results.count == 5)
    #expect(second.totalCount == 55)
    #expect(second.nextContinuation == nil)
    let all = first.results + second.results
    #expect(Set(all.map(\.id)).count == 55)
    #expect(Set(all.map(\.documentID)).count == 55)

    let otherHost = FolioSession(configuration: try fixture.configuration(namespace: "org.example.other-research"))
    try await otherHost.openWorkspace(at: source)
    await #expect(throws: FolioError.changedSource) {
      try await otherHost.searchPage("evidence", continuation: continuation)
    }
    try await otherHost.close()

    try Data(RecoverySearchFixture.note(number: 1,
      body: "evidence 기록에 새 근거를 추가해 이전 검색 결과의 기준 원문이 바뀌었다.").utf8)
      .write(to: fixture.noteURL(in: source, number: 1), options: .atomic)
    await #expect(throws: (any Error).self) {
      try await session.searchPage("evidence", continuation: continuation)
    }
    try await session.close()
  }
}

private final class RecoveryRevokingPresenter: NSObject, NSFilePresenter, Sendable {
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

private struct RecoverySearchFixture {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioRecoverySearch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }

  func configuration(namespace: String = "org.example.research-recovery",
    sourceAccess: FolioSourceAccess = FolioSourceAccess()
  ) throws -> FolioConfiguration {
    try FolioConfiguration(stateDirectory: directory.appendingPathComponent("State"),
      namespace: namespace, sourceAccess: sourceAccess)
  }

  func makeWorkspace(documentCount: Int) throws -> URL {
    let root = directory.appendingPathComponent("Research", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
    try Data("---\nid: c6c7fb84-6e19-4849-8328-660183596b97\nkind: workspace\nschema: 1\nname: 근거를 검토하는 연구 자료함\n---\n".utf8)
      .write(to: root.appendingPathComponent("_workspace.md"), options: .withoutOverwriting)
    for number in 1...documentCount {
      try Data(Self.note(number: number,
        body: "evidence 기록에는 관찰한 출처와 제한 조건을 남긴다. 제\(number)회 검토에서는 결론을 재현할 수 있는 질문을 정리한다.").utf8)
        .write(to: noteURL(in: root, number: number), options: .withoutOverwriting)
    }
    return root
  }

  static func documentID(_ number: Int) -> String { "research-evidence-\(number)" }

  static func note(number: Int, body: String) -> String {
    "---\nid: \(documentID(number))\n---\n\n# 연구 근거 기록 \(number)\n\n\(body)\n"
  }

  func noteURL(in source: URL, number: Int) -> URL {
    source.appendingPathComponent("notes/research-\(number).md")
  }

  func reviewedArchives() throws -> [URL] {
    let state = directory.appendingPathComponent("State")
    guard FileManager.default.fileExists(atPath: state.path) else { return [] }
    let files = try #require(FileManager.default.enumerator(at: state,
      includingPropertiesForKeys: [.isRegularFileKey]))
    return files.compactMap { $0 as? URL }.filter {
      $0.deletingLastPathComponent().lastPathComponent == "ReviewedSaves" && $0.pathExtension == "json"
    }
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
