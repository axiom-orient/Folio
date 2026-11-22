import Foundation
import Darwin
import FolioKnowledge
import Testing
@testable import FolioVaultImport

@Test func vaultImportPreservesOriginalBytesHashesAndExplicitRelationships() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("---\ntype: collection\n---\n# Index\n\n[[notes/Child|Child note]]\n", path: "index.md")
  try fixture.write("---\nparent: \"[[../index]]\"\n---\n# Child\n\n[[../index#Overview|Up]]\n\n[diagram](../media/Chart%20One.png)\n", path: "notes/Child.md")
  try fixture.write("# Loose\n\nA document without an explicit parent.\n", path: "loose.md")
  try fixture.write("# Hidden source file stays outside the import\n", path: ".skip.md")
  try fixture.write(Data([0, 1, 2, 255, 16]), path: "media/Chart One.png")
  try fixture.write("# Private source remains untouched\n", path: ".private/secret.md")
  let originalBytes = try fixture.sourceSnapshot()

  let result = try VaultImporter.run(fixture.request(name: "A \"quoted\" vault"))
  #expect(result.markdown == 3)
  #expect(result.files == 4)
  #expect(result.convertedWikiLinks == 2)
  #expect(result.parentRelations == 1)
  #expect(result.unresolved == 0)
  #expect(try fixture.sourceSnapshot() == originalBytes)
  let workspace = try WikiMarkdownParser.workspace(bytes: Data(contentsOf: result.workspace.appending(path: "_workspace.md")))
  #expect(workspace.id == result.workspaceID)
  #expect(workspace.name == "A \"quoted\" vault")
  let report = try fixture.report(at: result.manifest)
  #expect(report["originalMarkdownCount"] as? Int == 3)
  #expect(report["copiedFiles"] as? Int == 4)
  let entries = try #require(report["entries"] as? [[String: Any]])
  #expect(entries.count == 4)
  for entry in entries {
    let sourcePath = try #require(entry["originalPath"] as? String)
    let original = try #require(originalBytes[sourcePath])
    let outputPath = try #require(entry["importedPath"] as? String)
    let imported = try Data(contentsOf: fixture.destination.appending(path: outputPath))
    #expect(try Data(contentsOf: fixture.evidence.appending(path: "originals/" + sourcePath)) == original)
    #expect(entry["sourceSHA256"] as? String == SourceDigest.sha256(original))
    #expect(entry["importedSHA256"] as? String == SourceDigest.sha256(imported))
  }
  let index = try fixture.document("index.md")
  let child = try fixture.document("notes/Child.md")
  let loose = try fixture.document("loose.md")
  #expect(index.type == "collection")
  #expect(child.type == "document")
  #expect(child.declarations.contains { $0.predicate == "part_of" && $0.target == index.id && $0.origin == .frontmatter })
  #expect(!loose.declarations.contains { $0.predicate == "part_of" })
  let indexText = try fixture.importedText("index.md")
  let childText = try fixture.importedText("notes/Child.md")
  #expect(indexText.contains("[Child note](notes/Child.md)"))
  #expect(childText.contains("[Up](../index.md#Overview)"))
  #expect(childText.contains("[diagram](../../../attachments/projectvault/media/Chart%20One.png)"))
  #expect(try Data(contentsOf: fixture.destination.appending(path: "attachments/projectvault/media/Chart One.png")) == originalBytes["media/Chart One.png"])
}

@Test func vaultWikiLinksInsideLiteralCodeEscapesAndEmbedsRetainTheirSourceMeaning() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Target\n", path: "Target.md")
  let source = """
    # Literals
    [[Target]]
    `[[Target]]`
    \\[[Target]]
    ![[Target]]
    ```markdown
    [[Target]]
    ```
    ~~~
    [[Target]]
    ~~~
    [existing](Target.md)

    """
  try fixture.write(source, path: "Literals.md")

  let result = try VaultImporter.run(fixture.request())
  let output = try fixture.importedText("Literals.md")
  #expect(result.convertedWikiLinks == 1)
  #expect(result.unresolved == 0)
  #expect(output.contains("[Target](Target.md)"))
  #expect(output.contains("`[[Target]]`"))
  #expect(output.contains("\\[[Target]]"))
  #expect(output.contains("![[Target]]"))
  #expect(output.contains("```markdown\n[[Target]]\n```"))
  #expect(output.contains("~~~\n[[Target]]\n~~~"))
  #expect(output.contains("[existing](Target.md)"))
  #expect(try String(contentsOf: fixture.source.appending(path: "Literals.md"), encoding: .utf8) == source)
}

@Test func ambiguousAndMissingVaultTargetsRemainLiteralAndAppearInTheManifest() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# First Shared\n", path: "A/Shared.md")
  try fixture.write("# Second Shared\n", path: "B/Shared.markdown")
  try fixture.write("# Links\n\n[[Shared]]\n[[Missing]]\n[[A/Shared]]\n", path: "Links.md")

  let result = try VaultImporter.run(fixture.request())
  let output = try fixture.importedText("Links.md")
  #expect(result.convertedWikiLinks == 1)
  #expect(result.unresolved == 2)
  #expect(output.contains("[[Shared]]"))
  #expect(output.contains("[[Missing]]"))
  #expect(output.contains("[A/Shared](A/Shared.md)"))
  let report = try fixture.report(at: result.manifest)
  let unresolved = try #require(report["unresolvedWikiLinks"] as? [[String: Any]])
  #expect(Set(unresolved.compactMap { $0["reason"] as? String }) == ["ambiguous", "missing"])
  #expect(unresolved.allSatisfy { $0["source"] as? String == "Links.md" })
}

@Test func documentLinksAndFoldersDoNotInventParentRelationships() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Root\n", path: "Root.md")
  try fixture.write("# Child\n\n[[../Root]]\n", path: "Group/Child.md")

  let result = try VaultImporter.run(fixture.request())
  #expect(result.parentRelations == 0)
  let child = try fixture.document("Group/Child.md")
  #expect(!child.declarations.contains { $0.predicate == "part_of" })
  #expect(child.declarations.contains { $0.predicate == "references" && $0.origin == .markdownLink })
}

@Test func vaultStableIDsUseNFCRelativePathsAndRemainStableAcrossImports() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  let relative = "cafe\u{301}.md"
  try fixture.write("# Café\n", path: relative)
  let sourceBefore = try fixture.sourceSnapshot()
  _ = try VaultImporter.run(fixture.request())
  let first = try fixture.document(relative)
  let secondDestination = fixture.base.appending(path: "SecondWorkspace", directoryHint: .isDirectory)
  let secondEvidence = fixture.base.appending(path: "SecondEvidence", directoryHint: .isDirectory)
  _ = try VaultImporter.run(VaultImportRequest(source: fixture.source, destination: secondDestination, evidence: secondEvidence))
  let second = try WikiMarkdownParser.document(relativePath: "notes/projectvault/" + relative,
    bytes: Data(contentsOf: secondDestination.appending(path: "notes/projectvault/" + relative)))

  let expected = "vault-" + String(SourceDigest.sha256(relative.precomposedStringWithCanonicalMapping).prefix(24))
  #expect(first.id == expected)
  #expect(second.id == expected)
  #expect(first.id == second.id)
  #expect(try fixture.sourceSnapshot() == sourceBefore)
}

@Test func vaultLinkLookupRetainsUnicodeCanonicalAndCaseFoldingSemantics() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Street\n", path: "Straße.md")
  try fixture.write("# Café\n", path: "Café.md")
  try fixture.write("# Links\n\n[[STRASSE]]\n[[CAFE\u{301}]]\n", path: "Links.md")

  let result = try VaultImporter.run(fixture.request())
  #expect(result.convertedWikiLinks == 2)
  #expect(result.unresolved == 0)
  let linked = try fixture.document("Links.md")
  #expect(linked.declarations.filter { $0.predicate == "references" }.count == 2)
}

@Test(arguments: ["destination", "evidence"])
func existingVaultOutputsAreNeverOverwritten(existing: String) throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Source\n", path: "Source.md")
  let root = existing == "destination" ? fixture.destination : fixture.evidence
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let sentinel = root.appending(path: "keep.txt")
  let bytes = Data("Existing user data".utf8)
  try bytes.write(to: sentinel)

  #expect(throws: (any Error).self) { try VaultImporter.run(fixture.request()) }
  #expect(try Data(contentsOf: sentinel) == bytes)
  let other = existing == "destination" ? fixture.evidence : fixture.destination
  #expect(!FileManager.default.fileExists(atPath: other.path))
}

@Test(arguments: ["id: existing", "relations: {}", "\"id\": existing", "\"relations\": {}"])
func existingVaultIdentityAndRelationsRequireAnExplicitMigration(header: String) throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("---\n\(header)\n---\n# Existing identity\n", path: "Existing.md")
  let original = try fixture.sourceSnapshot()

  #expect(throws: (any Error).self) { try VaultImporter.run(fixture.request()) }
  fixture.expectNoOutputs()
  #expect(try fixture.sourceSnapshot() == original)
}

@Test(arguments: [InvalidVaultDocument.nonUTF8, .nulText, .unterminatedFrontmatter, .invalidYAML, .duplicateYAMLKey, .anchoredYAML])
private func malformedVaultDocumentsFailBeforeCreatingOutputs(document: InvalidVaultDocument) throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write(document.bytes, path: "Malformed.md")

  #expect(throws: (any Error).self) { try VaultImporter.run(fixture.request()) }
  fixture.expectNoOutputs()
  #expect(try Data(contentsOf: fixture.source.appending(path: "Malformed.md")) == document.bytes)
}

@Test(arguments: [VaultOverlap.destinationInSource, .evidenceInSource, .sameOutputs, .evidenceInDestination, .destinationInEvidence])
private func overlappingVaultInputAndOutputRootsAreRejected(overlap: VaultOverlap) throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Source\n", path: "Source.md")
  let request = overlap.request(fixture)

  #expect(throws: (any Error).self) { try VaultImporter.run(request) }
  #expect(!FileManager.default.fileExists(atPath: request.destination.path))
  #expect(!FileManager.default.fileExists(atPath: request.evidence.path))
  #expect(try fixture.sourceSnapshot().keys.sorted() == ["Source.md"])
}

@Test func vaultSourceSymlinksCannotCopyDataFromOutsideTheSelectedRoot() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Source\n", path: "Source.md")
  let external = fixture.base.appending(path: "private.txt")
  let bytes = Data("Private data outside the selected vault".utf8)
  try bytes.write(to: external)
  try FileManager.default.createSymbolicLink(at: fixture.source.appending(path: "linked.txt"), withDestinationURL: external)

  #expect(throws: (any Error).self) { try VaultImporter.run(fixture.request()) }
  fixture.expectNoOutputs()
  #expect(try Data(contentsOf: external) == bytes)
}

@Test func vaultOutputAncestorSymlinksCannotRedirectWrites() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Source\n", path: "Source.md")
  let actual = fixture.base.appending(path: "Actual", directoryHint: .isDirectory)
  let alias = fixture.base.appending(path: "Alias", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
  let request = VaultImportRequest(source: fixture.source, destination: alias.appending(path: "Workspace"), evidence: fixture.evidence)

  #expect(throws: (any Error).self) { try VaultImporter.run(request) }
  #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path).isEmpty)
  #expect(!FileManager.default.fileExists(atPath: fixture.evidence.path))
}

@Test func oversizedVaultMarkdownIsRejectedBeforeEvidenceOrWorkspaceCreation() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  let bytes = Data(repeating: 0x61, count: 256 * 1024 + 1)
  try fixture.write(bytes, path: "Oversized.md")

  #expect(throws: (any Error).self) { try VaultImporter.run(fixture.request()) }
  fixture.expectNoOutputs()
  #expect(try Data(contentsOf: fixture.source.appending(path: "Oversized.md")) == bytes)
}

@Test func vaultImportRejectsAConvertedDocumentThatWouldExceedFoliosReadLimit() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  let bytes = Data(("# Near the limit\n" + String(repeating: "a", count: 256 * 1024 - 18)).utf8)
  #expect(bytes.count <= 256 * 1024)
  try fixture.write(bytes, path: "NearLimit.md")

  #expect(throws: (any Error).self) { try VaultImporter.run(fixture.request()) }
  fixture.expectNoOutputs()
  #expect(try Data(contentsOf: fixture.source.appending(path: "NearLimit.md")) == bytes)
}

@Test func aVaultWithoutMarkdownDoesNotCreateAnEmptyWorkspace() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write(Data([0, 1, 2]), path: "asset.bin")

  #expect(throws: (any Error).self) { try VaultImporter.run(fixture.request()) }
  fixture.expectNoOutputs()
}

@Test func oversizedVaultAssetsAreRejectedWithoutReadingOrCopyingTheirPayload() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Source\n", path: "Source.md")
  let large = fixture.source.appending(path: "large.bin")
  #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
  let handle = try FileHandle(forWritingTo: large)
  try handle.truncate(atOffset: 256 * 1024 * 1024 + 1)
  try handle.close()

  #expect(throws: (any Error).self) { try VaultImporter.run(fixture.request()) }
  fixture.expectNoOutputs()
  #expect(try FileManager.default.attributesOfItem(atPath: large.path)[.size] as? NSNumber == NSNumber(value: 256 * 1024 * 1024 + 1))
}

@Test func aVaultWithMoreThanTenThousandFilesIsRejectedBeforeOutputsExist() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Source\n", path: "Source.md")
  let assets = fixture.source.appending(path: "assets", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
  for index in 0..<10_000 {
    guard FileManager.default.createFile(atPath: assets.appending(path: "asset-\(index).bin").path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  #expect(throws: (any Error).self) { try VaultImporter.run(fixture.request()) }
  fixture.expectNoOutputs()
}

@Test func anInvalidVaultOutputParentLeavesBothOutputsAbsentAndExistingFilesUntouched() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Source\n", path: "Source.md")
  let blockedParent = fixture.base.appending(path: "blocked-parent")
  let bytes = Data("This path is an existing file.".utf8)
  try bytes.write(to: blockedParent)
  let request = VaultImportRequest(source: fixture.source, destination: fixture.destination,
    evidence: blockedParent.appending(path: "Evidence"))

  #expect(throws: (any Error).self) { try VaultImporter.run(request) }
  #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  #expect(try Data(contentsOf: blockedParent) == bytes)
  #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path)) == ["Source", "blocked-parent"])
}

@Test(.enabled(if: geteuid() != 0))
func aVaultEvidenceStagingFailureRemovesThePreparedWorkspaceStage() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  try fixture.write("# Source\n", path: "Source.md")
  let blockedParent = fixture.base.appending(path: "ReadOnlyEvidenceParent", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o500])
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedParent.path) }
  let request = VaultImportRequest(source: fixture.source, destination: fixture.destination,
    evidence: blockedParent.appending(path: "Evidence", directoryHint: .isDirectory))

  #expect(throws: (any Error).self) { try VaultImporter.run(request) }
  #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  #expect(!FileManager.default.fileExists(atPath: request.evidence.path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: blockedParent.path).isEmpty)
  #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path)) == ["Source", "ReadOnlyEvidenceParent"])
}

@Test func caseInsensitiveNewOutputAliasesAreRejectedBeforeStaging() throws {
  let fixture = try VaultFixture()
  defer { fixture.cleanup() }
  guard try fixture.base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false else { return }
  try fixture.write("# Source\n", path: "document.md")
  let request = VaultImportRequest(source: fixture.source,
    destination: fixture.base.appending(path: "out", directoryHint: .isDirectory),
    evidence: fixture.base.appending(path: "OUT/evidence", directoryHint: .isDirectory))
  #expect(throws: VaultImportError.self) { try VaultImporter.run(request) }
  #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path)) == ["Source"])
}

private enum InvalidVaultDocument: Sendable {
  case nonUTF8, nulText, unterminatedFrontmatter, invalidYAML, duplicateYAMLKey, anchoredYAML
  var bytes: Data {
    switch self {
    case .nonUTF8: Data([0xff, 0xfe, 0x80])
    case .nulText: Data("# NUL-containing source\nA\0B\n".utf8)
    case .unterminatedFrontmatter: Data("---\ntitle: No ending delimiter\n# Body\n".utf8)
    case .invalidYAML: Data("---\ntype: [\n---\n# Invalid header\n".utf8)
    case .duplicateYAMLKey: Data("---\ntitle: First\ntitle: Second\n---\n# Duplicate header\n".utf8)
    case .anchoredYAML: Data("---\ntitle: &title Original\nalias: *title\n---\n# Anchored header\n".utf8)
    }
  }
}

private enum VaultOverlap: Sendable {
  case destinationInSource, evidenceInSource, sameOutputs, evidenceInDestination, destinationInEvidence
  func request(_ fixture: VaultFixture) -> VaultImportRequest {
    switch self {
    case .destinationInSource: VaultImportRequest(source: fixture.source, destination: fixture.source.appending(path: "Imported"), evidence: fixture.evidence)
    case .evidenceInSource: VaultImportRequest(source: fixture.source, destination: fixture.destination, evidence: fixture.source.appending(path: "Evidence"))
    case .sameOutputs: VaultImportRequest(source: fixture.source, destination: fixture.destination, evidence: fixture.destination)
    case .evidenceInDestination: VaultImportRequest(source: fixture.source, destination: fixture.destination, evidence: fixture.destination.appending(path: "Evidence"))
    case .destinationInEvidence: VaultImportRequest(source: fixture.source, destination: fixture.evidence.appending(path: "Workspace"), evidence: fixture.evidence)
    }
  }
}

private struct VaultFixture {
  let base: URL
  let source: URL
  let destination: URL
  let evidence: URL

  init() throws {
    #if os(macOS)
    let temporary = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
    #else
    let temporary = FileManager.default.temporaryDirectory
    #endif
    base = temporary.appending(path: "FolioVaultTests-" + UUID().uuidString, directoryHint: .isDirectory)
    source = base.appending(path: "Source", directoryHint: .isDirectory)
    destination = base.appending(path: "Workspace", directoryHint: .isDirectory)
    evidence = base.appending(path: "Evidence", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  func request(name: String = "ProjectVault") -> VaultImportRequest {
    VaultImportRequest(source: source, destination: destination, evidence: evidence, name: name)
  }

  func write(_ text: String, path: String) throws { try write(Data(text.utf8), path: path) }
  func write(_ bytes: Data, path: String) throws {
    let file = source.appending(path: path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: file)
  }

  func sourceSnapshot() throws -> [String: Data] {
    var result: [String: Data] = [:]
    let items = try #require(FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in items where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      let path = file.pathComponents.suffix(items.level).joined(separator: "/")
      result[path] = try Data(contentsOf: file)
    }
    return result
  }

  func importedText(_ relative: String) throws -> String {
    try String(contentsOf: destination.appending(path: "notes/projectvault/" + relative), encoding: .utf8)
  }

  func document(_ relative: String) throws -> WikiDocument {
    let path = "notes/projectvault/" + relative
    return try WikiMarkdownParser.document(relativePath: path, bytes: Data(contentsOf: destination.appending(path: path)))
  }

  func report(at manifest: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
  }

  func expectNoOutputs() {
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(!FileManager.default.fileExists(atPath: evidence.path))
  }

  func cleanup() { try? FileManager.default.removeItem(at: base) }
}
