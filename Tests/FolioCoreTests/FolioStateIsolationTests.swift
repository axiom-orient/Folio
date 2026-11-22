import Foundation
import Testing
import FolioCore
import FolioKnowledge

@MainActor
struct FolioStateIsolationTests {
  @Test(arguments: StateAliasDepth.allCases)
  func derivedStateAliasCannotWriteIntoSource(_ depth: StateAliasDepth) async throws {
    let fixture = try IsolationFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let sourceBefore = try fixture.sourceSnapshot()
    let state = configuration.stateDirectory
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let host = state.appendingPathComponent(SourceDigest.sha256(configuration.namespace), isDirectory: true)
    let alias: URL
    switch depth {
    case .host:
      alias = host
    case .workspaceScope:
      try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
      alias = host.appendingPathComponent(try fixture.scope(configuration), isDirectory: true)
    }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
    let session = FolioSession(configuration: configuration)

    await #expect(throws: (any Error).self) { try await session.openWorkspace(at: fixture.source) }

    #expect(try fixture.sourceSnapshot() == sourceBefore)
    #expect(session.snapshot == nil)
  }

  @Test func ancestorRepointedAfterConfigurationCannotWriteIntoSource() async throws {
    let fixture = try IsolationFixture()
    defer { fixture.remove() }
    let parent = fixture.directory.appendingPathComponent("HostContainer", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let configuration = try FolioConfiguration(stateDirectory: parent.appendingPathComponent("State", isDirectory: true),
      namespace: "org.example.repointed-parent")
    let before = try fixture.sourceSnapshot()
    try FileManager.default.removeItem(at: parent)
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: fixture.source)
    let session = FolioSession(configuration: configuration)
    await #expect(throws: (any Error).self) { try await session.openWorkspace(at: fixture.source) }
    #expect(try fixture.sourceSnapshot() == before)
    #expect(session.snapshot == nil)
  }

  @Test func stateRootRepointedAfterConfigurationCannotWriteIntoSource() async throws {
    let fixture = try IsolationFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let sourceBefore = try fixture.sourceSnapshot()
    // Configuration resolves the location before this alias exists. Open must
    // validate the current path rather than trusting the earlier URL value.
    try FileManager.default.createSymbolicLink(at: configuration.stateDirectory, withDestinationURL: fixture.source)
    let session = FolioSession(configuration: configuration)

    await #expect(throws: (any Error).self) { try await session.openWorkspace(at: fixture.source) }

    #expect(try fixture.sourceSnapshot() == sourceBefore)
    #expect(session.snapshot == nil)
  }
}

enum StateAliasDepth: CaseIterable, Sendable { case host, workspaceScope }

private struct IsolationFixture {
  let directory: URL
  let source: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioStateIsolation-" + UUID().uuidString)
    source = directory.appendingPathComponent("Research", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("notes"), withIntermediateDirectories: true)
    try Data("---\nid: 3b4c9499-f27c-4bde-989e-cd6990ce987a\nkind: workspace\nschema: 1\nname: 출처를 보존하는 연구 자료함\n---\n".utf8)
      .write(to: source.appendingPathComponent("_workspace.md"), options: .withoutOverwriting)
    try Data("---\nid: source-boundaries\n---\n\n# 원문과 복구 상태의 경계\n\n검색 색인과 편집 복구본은 연구 원문 폴더 밖에 보관한다. 경로가 달라지면 먼저 위치를 다시 확인한다.\n".utf8)
      .write(to: source.appendingPathComponent("notes/boundaries.md"), options: .withoutOverwriting)
  }

  func configuration() throws -> FolioConfiguration {
    try FolioConfiguration(stateDirectory: directory.appendingPathComponent("State", isDirectory: true),
      namespace: "org.example.source-isolation")
  }

  func scope(_ configuration: FolioConfiguration) throws -> String {
    struct Scope: Encodable {
      let namespace: String; let path: String; let location: String; let account: UUID?
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SourceDigest.sha256(try encoder.encode(Scope(namespace: configuration.namespace,
      path: source.standardizedFileURL.resolvingSymlinksInPath().path, location: "local", account: nil)))
  }

  /// Includes directory and hidden entries, so an empty lock/index directory is
  /// a source mutation even when the original Markdown bytes remain unchanged.
  func sourceSnapshot() throws -> [String: Data] {
    let root = source.standardizedFileURL.resolvingSymlinksInPath()
    let enumerator = try #require(FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
    var snapshot: [String: Data] = [:]
    for case let file as URL in enumerator {
      let relative = String(file.path.dropFirst(root.path.count))
      let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        snapshot["link:" + relative] = Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8)
        enumerator.skipDescendants()
      } else if values.isDirectory == true {
        snapshot["directory:" + relative] = Data()
      } else {
        snapshot["file:" + relative] = try Data(contentsOf: file)
      }
    }
    return snapshot
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
