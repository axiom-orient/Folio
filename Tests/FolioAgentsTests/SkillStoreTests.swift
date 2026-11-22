import Foundation
import Testing
@testable import FolioAgents

@Test func skillTargetsUseEachHostsDocumentedInstallationRoots() throws {
  let home = URL(filePath: "/tmp/folio-home", directoryHint: .isDirectory)
  let project = URL(filePath: "/tmp/folio-project", directoryHint: .isDirectory)
  #expect(try SkillTarget(host: .codex, scope: .global).directory(home: home).path == home.appending(path: ".agents/skills").path)
  #expect(try SkillTarget(host: .claude, scope: .global).directory(home: home).path == home.appending(path: ".claude/skills").path)
  #expect(try SkillTarget(host: .codex, scope: .project, project: project).directory(home: home).path == project.appending(path: ".agents/skills").path)
  #expect(try SkillTarget(host: .claude, scope: .project, project: project).directory(home: home).path == project.appending(path: ".claude/skills").path)
}

@Test func localInstallationCopiesCompleteSkillAndCanBeRemovedWithoutTouchingSource() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let script = fixture.source.appending(path: "scripts/check.sh")
  try fixture.write("#!/bin/sh\nprintf 'done'\n", to: script)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)

  #expect(installed.name == "demo-skill")
  #expect(installed.isManaged)
  #expect(!installed.isSymbolicLink)
  #expect(try fixture.text(at: installed.directory.appending(path: "SKILL.md")) == fixture.text(at: fixture.source.appending(path: "SKILL.md")))
  #expect(try fixture.text(at: installed.directory.appending(path: "scripts/check.sh")) == fixture.text(at: script))
  let permissions = try FileManager.default.attributesOfItem(atPath: installed.directory.appending(path: "scripts/check.sh").path)[.posixPermissions] as? NSNumber
  #expect(permissions?.intValue == 0o755)
  let listed = try await fixture.store.list(fixture.target)
  #expect(listed.count == 1)
  #expect(listed.first?.isManaged == true)

  try await fixture.store.remove(installed, target: fixture.target)
  #expect(!FileManager.default.fileExists(atPath: installed.directory.path))
  #expect(try fixture.text(at: script) == "#!/bin/sh\nprintf 'done'\n")
}

@Test func aGitWorktreePointerCannotHideTheNextSkillResourceDirectory() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  try fixture.write("gitdir: /unused/worktree-metadata\n", to: fixture.source.appending(path: ".git"))
  try fixture.write("Required resource\n", to: fixture.source.appending(path: "assets/template.md"))
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  #expect(try fixture.text(at: installed.directory.appending(path: "assets/template.md")) == "Required resource\n")
  #expect(!FileManager.default.fileExists(atPath: installed.directory.appending(path: ".git").path))
  #expect(try fixture.text(at: fixture.source.appending(path: ".git")) == "gitdir: /unused/worktree-metadata\n")
  try await fixture.store.remove(installed, target: fixture.target)
}

@Test func yamlLiteralDescriptionRetainsItsLines() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  try fixture.writeManifest(description: "|\n  First instruction line.\n  Second instruction line.")

  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  #expect(installed.summary.contains("First instruction line.\nSecond instruction line."))
}

@Test func unicodeSkillNamesInstallWithoutRenamingTheirManifest() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let name = "문서-도구"
  let source = fixture.source.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
  try FileManager.default.moveItem(at: fixture.source, to: source)
  try fixture.write("---\nname: \(name)\ndescription: 한국어 이름을 보존합니다.\n---\n# 도구\n", to: source.appending(path: "SKILL.md"))

  let installed = try await fixture.store.install(source: .local(source), target: fixture.target)
  #expect(installed.name == name)
  #expect(installed.directory.lastPathComponent == name)
  #expect(try await fixture.store.list(fixture.target).first?.name == name)
}

@Test func updateReplacesAnUnmodifiedManagedCopyAndKeepsItsSource() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let instructions = fixture.source.appending(path: "references/details.md")
  try fixture.write("Version one", to: instructions)
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  try fixture.write("Version two", to: instructions)

  let updated = try await fixture.store.update(installed, target: fixture.target)
  #expect(try fixture.text(at: updated.directory.appending(path: "references/details.md")) == "Version two")
  #expect(try fixture.text(at: instructions) == "Version two")
  #expect(updated.isManaged)
  try await fixture.store.remove(updated, target: fixture.target)
}

@Test func gitInstallationRecordsACommitAndUpdatesFromTheSameRepository() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  try await fixture.git(["init", "--initial-branch=main"])
  try await fixture.git(["add", "SKILL.md"])
  try await fixture.git(["commit", "-m", "Initial skill"])
  let firstCommit = try await fixture.git(["rev-parse", "HEAD"])
  let source = SkillSource.git(repository: fixture.source.absoluteString, reference: "HEAD", subdirectory: "")
  let installed = try await fixture.store.install(source: source, target: fixture.target)
  #expect(installed.revision == firstCommit)
  #expect(installed.source == source)
  #expect(!FileManager.default.fileExists(atPath: installed.directory.appending(path: ".git").path))

  try fixture.writeManifest(description: "Updated from Git.")
  try await fixture.git(["add", "SKILL.md"])
  try await fixture.git(["commit", "-m", "Update skill"])
  let secondCommit = try await fixture.git(["rev-parse", "HEAD"])
  let updated = try await fixture.store.update(installed, target: fixture.target)
  #expect(updated.revision == secondCommit)
  #expect(updated.revision != installed.revision)
  #expect(updated.summary == "Updated from Git.")
}

@Test func gitInstallationResolvesANondefaultBranchAndNestedSkillAtAnImmutableCommit() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  try await fixture.git(["init", "--initial-branch=main"])
  try await fixture.git(["add", "SKILL.md"])
  try await fixture.git(["commit", "-m", "Initial skill"])
  try await fixture.git(["checkout", "-b", "feature"])
  let nested = fixture.source.appending(path: "packages/demo-skill", directoryHint: .isDirectory)
  try fixture.write("---\nname: demo-skill\ndescription: Feature branch nested skill.\n---\n# Nested\n", to: nested.appending(path: "SKILL.md"))
  try await fixture.git(["add", "packages"])
  try await fixture.git(["commit", "-m", "Nested skill on feature"])
  let featureCommit = try await fixture.git(["rev-parse", "HEAD"])
  try await fixture.git(["checkout", "main"])
  let source = SkillSource.git(repository: fixture.source.absoluteString, reference: "feature", subdirectory: "packages/demo-skill")

  let installed = try await fixture.store.install(source: source, target: fixture.target)
  #expect(installed.revision == featureCommit)
  #expect(installed.summary == "Feature branch nested skill.")
  #expect(installed.source == source)
  #expect(!FileManager.default.fileExists(atPath: installed.directory.appending(path: "packages").path))
}

@Test func modifyingAnInstalledFileBlocksUpdateAndRemoval() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  let instructions = installed.directory.appending(path: "SKILL.md")
  let userText = try fixture.text(at: instructions) + "\nUser additions that must survive.\n"
  try fixture.write(userText, to: instructions)
  try fixture.writeManifest(description: "A changed upstream skill.")

  await #expect(throws: (any Error).self) { try await fixture.store.update(installed, target: fixture.target) }
  await #expect(throws: (any Error).self) { try await fixture.store.remove(installed, target: fixture.target) }
  #expect(try fixture.text(at: instructions) == userText)
}

@Test func addingAnInstalledFileBlocksRemoval() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  let personalNote = installed.directory.appending(path: "personal-notes.md")
  try fixture.write("Keep this note.", to: personalNote)

  await #expect(throws: (any Error).self) { try await fixture.store.remove(installed, target: fixture.target) }
  #expect(try fixture.text(at: personalNote) == "Keep this note.")
}

@Test func emptySourceDirectoriesArePreservedAndNewInstalledDirectoriesBlockRemoval() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  try FileManager.default.createDirectory(at: fixture.source.appending(path: "references/empty", directoryHint: .isDirectory), withIntermediateDirectories: true)
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  #expect(try FileManager.default.contentsOfDirectory(atPath: installed.directory.appending(path: "references/empty").path).isEmpty)
  let userDirectory = installed.directory.appending(path: "personal-empty-directory", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: false)

  await #expect(throws: (any Error).self) { try await fixture.store.remove(installed, target: fixture.target) }
  #expect(FileManager.default.fileExists(atPath: userDirectory.path))
}

@Test func initializingGitInsideAnInstalledSkillDoesNotMakeUserMetadataDisposable() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  let configuration = installed.directory.appending(path: ".git/config")
  try fixture.write("[core]\n\trepositoryformatversion = 0\n", to: configuration)

  await #expect(throws: (any Error).self) { try await fixture.store.remove(installed, target: fixture.target) }
  #expect(FileManager.default.fileExists(atPath: configuration.path))
}

@Test func missingLocalUpdateSourcePreservesInstalledCopy() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  let original = try fixture.text(at: installed.directory.appending(path: "SKILL.md"))
  try FileManager.default.removeItem(at: fixture.source)

  await #expect(throws: (any Error).self) { try await fixture.store.update(installed, target: fixture.target) }
  #expect(try fixture.text(at: installed.directory.appending(path: "SKILL.md")) == original)
  #expect(try await fixture.store.list(fixture.target).first?.isManaged == true)
}

@Test func duplicateInstallNeverOverwritesExistingFiles() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  let original = try fixture.text(at: installed.directory.appending(path: "SKILL.md"))
  try fixture.writeManifest(description: "New source must not replace an existing destination.")

  await #expect(throws: (any Error).self) { try await fixture.store.install(source: .local(fixture.source), target: fixture.target) }
  #expect(try fixture.text(at: installed.directory.appending(path: "SKILL.md")) == original)
}

@Test func foreignSkillsAreVisibleAndCannotBeMutated() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let destination = try fixture.target.directory(home: fixture.home).appending(path: "demo-skill", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: fixture.source, to: destination)

  let skills = try await fixture.store.list(fixture.target)
  let foreign = try #require(skills.first)
  #expect(!foreign.isManaged)
  await #expect(throws: (any Error).self) { try await fixture.store.remove(foreign, target: fixture.target) }
  await #expect(throws: (any Error).self) { try await fixture.store.update(foreign, target: fixture.target) }
  #expect(FileManager.default.fileExists(atPath: destination.appending(path: "SKILL.md").path))
}

@Test func legacyCodexSkillsRemainVisibleAndReadOnlyAlongsideCanonicalInstalls() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let legacy = fixture.home.appending(path: ".codex/skills/demo-skill", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: fixture.source, to: legacy)
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)

  let listed = try await fixture.store.list(fixture.target)
  #expect(listed.count == 2)
  let compatibility = try #require(listed.first(where: { $0.directory.path == legacy.path }))
  #expect(!compatibility.isManaged)
  #expect(compatibility.warning != nil)
  await #expect(throws: (any Error).self) { try await fixture.store.remove(compatibility, target: fixture.target) }
  try await fixture.store.remove(installed, target: fixture.target)
  #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "SKILL.md").path))
}

@Test func linkedExistingSkillsAreReadOnly() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let root = try fixture.target.directory(home: fixture.home)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let linked = root.appending(path: "demo-skill", directoryHint: .isDirectory)
  try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.source)

  let listed = try await fixture.store.list(fixture.target)
  let existing = try #require(listed.first)
  #expect(existing.isSymbolicLink)
  #expect(!existing.isManaged)
  await #expect(throws: (any Error).self) { try await fixture.store.remove(existing, target: fixture.target) }
  #expect(FileManager.default.fileExists(atPath: fixture.source.appending(path: "SKILL.md").path))
}

@Test func corruptedReceiptNeverGrantsMutationPermission() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  try fixture.write("{ invalid receipt", to: installed.directory.appending(path: ".folio-install.json"))

  let listed = try await fixture.store.list(fixture.target)
  let inspected = try #require(listed.first)
  #expect(!inspected.isManaged)
  await #expect(throws: (any Error).self) { try await fixture.store.remove(installed, target: fixture.target) }
  await #expect(throws: (any Error).self) { try await fixture.store.update(installed, target: fixture.target) }
  #expect(FileManager.default.fileExists(atPath: installed.directory.appending(path: "SKILL.md").path))
}

@Test func anUnknownReceiptSchemaCannotAuthorizeRemoval() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  let receiptURL = installed.directory.appending(path: ".folio-install.json")
  let data = try Data(contentsOf: receiptURL)
  var receipt = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  receipt["schema"] = 2
  try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL)

  let listed = try await fixture.store.list(fixture.target)
  #expect(listed.first?.isManaged == false)
  await #expect(throws: (any Error).self) { try await fixture.store.remove(installed, target: fixture.target) }
  #expect(FileManager.default.fileExists(atPath: installed.directory.appending(path: "SKILL.md").path))
}

@Test func anInstallationCannotBeRemovedUsingAnotherHostsTarget() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  let claude = SkillTarget(host: .claude, scope: .global)

  await #expect(throws: (any Error).self) { try await fixture.store.remove(installed, target: claude) }
  #expect(FileManager.default.fileExists(atPath: installed.directory.appending(path: "SKILL.md").path))
}

@Test func globalAndProjectCopiesHaveIndependentOwnership() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let project = SkillTarget(host: .claude, scope: .project, project: fixture.project)
  let globalSkill = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  let projectSkill = try await fixture.store.install(source: .local(fixture.source), target: project)
  #expect(globalSkill.directory != projectSkill.directory)

  try await fixture.store.remove(globalSkill, target: fixture.target)
  #expect(try await fixture.store.list(fixture.target).isEmpty)
  #expect(try await fixture.store.list(project).count == 1)
  #expect(FileManager.default.fileExists(atPath: projectSkill.directory.appending(path: "SKILL.md").path))
}

@Test(arguments: ["../escape", "Uppercase", "-leading", "trailing-", "double--hyphen", ""])
func invalidNamesCannotEscapeOrCreateAnInstallation(name: String) async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  try fixture.writeManifest(name: "\"\(name)\"")

  await #expect(throws: (any Error).self) { try await fixture.store.install(source: .local(fixture.source), target: fixture.target) }
  #expect(try await fixture.store.list(fixture.target).isEmpty)
}

@Test func manifestNameMustMatchItsContainingDirectory() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  try fixture.writeManifest(name: "different-name")

  await #expect(throws: (any Error).self) { try await fixture.store.install(source: .local(fixture.source), target: fixture.target) }
  #expect(try await fixture.store.list(fixture.target).isEmpty)
}

@Test func sourceSymlinksCannotImportFilesOutsideTheSkill() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let secret = fixture.base.appending(path: "private.txt")
  try fixture.write("Private file outside the skill.", to: secret)
  try FileManager.default.createSymbolicLink(at: fixture.source.appending(path: "leak.txt"), withDestinationURL: secret)

  await #expect(throws: (any Error).self) { try await fixture.store.install(source: .local(fixture.source), target: fixture.target) }
  #expect(try fixture.text(at: secret) == "Private file outside the skill.")
  #expect(try await fixture.store.list(fixture.target).isEmpty)
}

@Test func targetAncestorSymlinkCannotRedirectInstallationWrites() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let outside = fixture.base.appending(path: "Outside", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: fixture.home.appending(path: ".agents"), withDestinationURL: outside)

  await #expect(throws: (any Error).self) { try await fixture.store.install(source: .local(fixture.source), target: fixture.target) }
  #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test func replacingAnInstalledRootWithASymlinkCannotRedirectRemoval() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let installed = try await fixture.store.install(source: .local(fixture.source), target: fixture.target)
  let root = installed.directory.deletingLastPathComponent()
  let originalRoot = fixture.base.appending(path: "OriginalSkills", directoryHint: .isDirectory)
  let outside = fixture.base.appending(path: "Outside", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: installed.directory, to: outside.appending(path: installed.name))
  try FileManager.default.moveItem(at: root, to: originalRoot)
  try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)

  await #expect(throws: (any Error).self) { try await fixture.store.remove(installed, target: fixture.target) }
  #expect(FileManager.default.fileExists(atPath: outside.appending(path: "demo-skill/SKILL.md").path))
  #expect(FileManager.default.fileExists(atPath: originalRoot.appending(path: "demo-skill/SKILL.md").path))
}

@Test func aSkillSourceCannotForgeFolioOwnershipMetadata() async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  try fixture.write("{}", to: fixture.source.appending(path: ".folio-install.json"))

  await #expect(throws: (any Error).self) { try await fixture.store.install(source: .local(fixture.source), target: fixture.target) }
  #expect(try await fixture.store.list(fixture.target).isEmpty)
}

@Test(arguments: ["synced", "anthropic-skills"])
func claudeReservedSkillNamesRemainOwnedByTheHost(name: String) async throws {
  let fixture = try SkillFixture()
  defer { fixture.cleanup() }
  let source = fixture.source.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
  try FileManager.default.moveItem(at: fixture.source, to: source)
  try fixture.write("---\nname: \(name)\ndescription: A reserved-name test.\n---\n# Reserved\n", to: source.appending(path: "SKILL.md"))
  let claude = SkillTarget(host: .claude, scope: .global)

  await #expect(throws: (any Error).self) { try await fixture.store.install(source: .local(source), target: claude) }
  #expect(try await fixture.store.list(claude).isEmpty)
  #expect(FileManager.default.fileExists(atPath: source.appending(path: "SKILL.md").path))
}

private struct SkillFixture {
  let base: URL
  let home: URL
  let project: URL
  let source: URL
  let store: SkillStore
  let target = SkillTarget(host: .codex, scope: .global)

  init() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "FolioAgents-" + UUID().uuidString, directoryHint: .isDirectory)
    self.base = base
    home = base.appending(path: "Home", directoryHint: .isDirectory)
    project = base.appending(path: "Project", directoryHint: .isDirectory)
    source = base.appending(path: "Sources/demo-skill", directoryHint: .isDirectory)
    store = SkillStore(home: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try writeManifest()
  }

  func writeManifest(name: String = "demo-skill", description: String = "A useful test skill.") throws {
    try write("---\nname: \(name)\ndescription: \(description)\n---\n\n# Demo\n\nInstructions.\n", to: source.appending(path: "SKILL.md"))
  }

  func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  func text(at file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

  @discardableResult func git(_ arguments: [String]) async throws -> String {
    let result = try await AgentCommand.run(executable: URL(filePath: "/usr/bin/git"),
      arguments: ["-c", "user.name=Folio Tests", "-c", "user.email=folio-tests@example.invalid", "-c", "core.hooksPath=/dev/null", "-c", "init.templateDir="] + arguments,
      directory: source, environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"])
    try #require(result.status == 0, "Local Git fixture failed: \(result.output)")
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func cleanup() { try? FileManager.default.removeItem(at: base) }
}
