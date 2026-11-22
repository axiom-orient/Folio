import Foundation
import Testing
@testable import FolioDevelopment

@Test func localSimulatorBuildCannotAcquireSigningOrProvisioningEffects() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  let request = try fixture.request(["ios", "--local-simulator"])
  let commands = DevelopmentPlan(request).commands
  let build = try #require(commands.first { $0.executable == "/usr/bin/xcodebuild" })
  #expect(build.arguments.contains("generic/platform=iOS Simulator"))
  #expect(build.arguments.contains("CODE_SIGNING_ALLOWED=NO"))
  #expect(build.arguments.contains("FOLIO_IOS_INFO_PLIST=Apps/IOSLocalInfo.plist"))
  #expect(!build.arguments.contains("-allowProvisioningUpdates"))
  #expect(!commands.contains { $0.arguments.contains("devicectl") })
}

@Test func signedBuildAndExplicitDeviceInstallationKeepDistinctEffects() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  let build = DevelopmentPlan(try fixture.request(["cloud", "--iphone"]))
  #expect(!build.commands.contains { $0.arguments.contains("devicectl") })
  #expect(build.commands.contains { $0.arguments.contains("-allowProvisioningUpdates") })
  #expect(!build.commands.contains { $0.arguments.contains("CODE_SIGNING_ALLOWED=NO") })
  let device = "literal-device;no-shell"
  let install = DevelopmentPlan(try fixture.request(["cloud", "--install-iphone", device]))
  let deviceCommands = install.commands.filter { $0.arguments.contains("devicectl") }
  #expect(deviceCommands.count == 2)
  #expect(deviceCommands.allSatisfy { $0.arguments.contains(device) })
  #expect(deviceCommands.first?.arguments.contains("install") == true)
  #expect(deviceCommands.last?.arguments.contains("launch") == true)
  #expect(install.commands.allSatisfy { !["/bin/sh", "/bin/bash", "/bin/zsh"].contains($0.executable) })
}

@Test func dryRunPlanningDoesNotCreateBuildOutputsOrExposeInheritedSecrets() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  let initial = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
  let request = try fixture.request(["--dry-run", "mac", "--verify"], environment: [
    "DEVELOPER_DIR": "", "FOLIO_DEVELOPMENT_TEAM": "", "GITHUB_TOKEN": "never-serialize-this-secret"])
  let data = try DevelopmentPlan(request).dryRunJSON()
  #expect(request.dryRun)
  #expect(request.developerDirectory == "/Applications/Xcode.app/Contents/Developer")
  #expect(request.developmentTeam == "7WR76382QB")
  #expect(!String(decoding: data, as: UTF8.self).contains("never-serialize-this-secret"))
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == initial)
  #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "build").path))
  #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".build").path))
}

@Test func macDiagnosticsReplaceTheForegroundProcessAfterBuilding() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  for mode in ["--debug", "--logs", "--telemetry"] {
    let plan = DevelopmentPlan(try fixture.request(["mac", mode]))
    guard case .foreground(let command) = try #require(plan.actions.last) else {
      Issue.record("A terminal diagnostic must own the foreground process."); continue
    }
    #expect(command.directory == plan.request.root)
    #expect(plan.commands.contains { $0.arguments.contains("FolioMac") && $0.arguments.contains("build") })
  }
  let buildOnly = DevelopmentPlan(try fixture.request(["mac", "--build-only"]))
  #expect(!buildOnly.commands.contains { $0.executable == "/usr/bin/open" })
}

@Test(arguments: [
  ["cloud", "--install-iphone"], ["cloud", "--install-iphone", "--mac"],
  ["ios", "--iphone"], ["mac", "--logs", "extra"], ["assets", "extra"],
  ["mac", "--dry-run", "--dry-run"], ["cloud", "--iphone", "unexpected-device"],
])
func invalidDevelopmentCommandsCannotExpandTheirEffects(_ arguments: [String]) throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  #expect(throws: DevelopmentError.self) { try fixture.request(arguments) }
}

@Test func aBuildCacheSymlinkCannotRedirectBundleChangesToUnrelatedFiles() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  let outside = fixture.root.appending(path: "Unrelated", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
  try Data("Preserve".utf8).write(to: outside.appending(path: "keep.txt"))
  try FileManager.default.createSymbolicLink(at: fixture.cache, withDestinationURL: outside)
  let request = try fixture.request(["mac", "--build-only"], environment: ["FOLIO_BUILD_ROOT": fixture.cache.path])
  #expect(throws: DevelopmentError.self) { try DevelopmentPaths.validateBuildPaths(request) }
  #expect(try Data(contentsOf: outside.appending(path: "keep.txt")) == Data("Preserve".utf8))
}

@Test func defaultDevelopmentBuildOutputsStayOutsideTheRepositoryInEveryBuildMode() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  for arguments in [["mac", "--build-only"], ["ios"], ["cloud", "--mac"], ["cloud", "--iphone"]] {
    let request = try fixture.request(arguments)
    let plan = DevelopmentPlan(request)
    #expect(!request.buildRoot.path.hasPrefix(fixture.root.path + "/"))
    #expect(request.buildRoot.path.contains("/Library/Developer/FolioBuilds/Development/"))
    try DevelopmentPaths.validateBuildPaths(request)
    let paths = developmentBuildArguments(plan)
    #expect(!paths.isEmpty)
    #expect(paths.allSatisfy { $0.hasPrefix(request.buildRoot.path + "/") })
    #expect(plan.commands.allSatisfy { !$0.arguments.contains(".build/folio") })
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "build").path))
  #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".build").path))
}

@Test func explicitDevelopmentBuildRootControlsScratchPackagingAndDeviceInstallationTogether() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  let environment = ["FOLIO_BUILD_ROOT": fixture.cache.path]
  let request = try fixture.request(["mac", "--build-only"], environment: environment)
  #expect(request.buildRoot == fixture.cache)
  #expect(developmentBuildArguments(DevelopmentPlan(request)).allSatisfy { $0.hasPrefix(fixture.cache.path + "/") })
  #expect(DevelopmentPlan(request).commands.contains { $0.arguments.contains(request.buildPaths.products.appendingPathComponent(".FolioMac-<stage>.app").path) })
  let install = DevelopmentPlan(try fixture.request(["cloud", "--install-iphone", "literal-device"], environment: environment))
  let installation = try #require(install.commands.first { $0.arguments.contains("install") })
  #expect(installation.arguments.last == fixture.cache.appendingPathComponent("IPhone/Build/Products/Debug-iphoneos/FolioIOS.app").path)
  #expect(developmentBuildArguments(install) == [fixture.cache.appendingPathComponent("IPhone").path])
  #expect(throws: DevelopmentError.self) {
    try fixture.request(["ios"], environment: ["FOLIO_BUILD_ROOT": "relative-cache"])
  }
  let inside = try fixture.request(["ios"], environment: ["FOLIO_BUILD_ROOT": fixture.root.appendingPathComponent("build").path])
  #expect(throws: DevelopmentError.self) { try DevelopmentPaths.validateBuildPaths(inside) }
}

@Test func cachePathsWithSpacesRemainLiteralAndDryRunCreatesNeitherCacheNorRepositoryOutputs() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  let initial = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
  let request = try fixture.request(["--dry-run", "mac", "--debug"], environment: ["FOLIO_BUILD_ROOT": fixture.cache.path])
  let plan = DevelopmentPlan(request)
  #expect(fixture.cache.path.contains(" ") && fixture.cache.path.contains("$(literal)"))
  #expect(developmentBuildArguments(plan).allSatisfy { $0 == fixture.cache.appendingPathComponent("SwiftPM").path })
  #expect(plan.commands.allSatisfy { !["/bin/sh", "/bin/bash", "/bin/zsh"].contains($0.executable) })
  let data = try plan.dryRunJSON()
  let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(json["buildRoot"] as? String == fixture.cache.path)
  #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == initial)
}

@Test func aLateRunningAppPreconditionPreservesBothAppBundles() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  let stage = fixture.root.appending(path: "build/.stage.app", directoryHint: .isDirectory)
  let destination = fixture.root.appending(path: "build/FolioMac.app", directoryHint: .isDirectory)
  try fixture.bundle(stage, content: "New executable")
  try fixture.bundle(destination, content: "Running executable")
  #expect(throws: DevelopmentError.self) {
    try DevelopmentMacBundle.commit(stage: stage, destination: destination, root: fixture.root) {
      throw DevelopmentError.runningApplication
    }
  }
  #expect(try fixture.bundleContents(destination) == "Running executable")
  #expect(try fixture.bundleContents(stage) == "New executable")
}

@Test(arguments: [false, true])
func aPreparedBundleCommitsCompletelyForNewAndExistingDestinations(_ exists: Bool) throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  let stage = fixture.root.appending(path: "build/.stage.app", directoryHint: .isDirectory)
  let destination = fixture.root.appending(path: "build/FolioMac.app", directoryHint: .isDirectory)
  try fixture.bundle(stage, content: "Signed replacement")
  if exists { try fixture.bundle(destination, content: "Old executable") }
  var checked = 0
  try DevelopmentMacBundle.commit(stage: stage, destination: destination, root: fixture.root) { checked += 1 }
  #expect(checked == 1)
  #expect(try fixture.bundleContents(destination) == "Signed replacement")
  #expect(!FileManager.default.fileExists(atPath: stage.path))
}

@Test func aBundleSymlinkCannotAuthorizeReplacementOrDeleteItsTarget() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  let stage = fixture.root.appending(path: "build/.stage.app", directoryHint: .isDirectory)
  let destination = fixture.root.appending(path: "build/FolioMac.app", directoryHint: .isDirectory)
  let unrelated = fixture.root.appending(path: "Unrelated.app", directoryHint: .isDirectory)
  try fixture.bundle(stage, content: "New executable")
  try fixture.bundle(unrelated, content: "Preserve unrelated executable")
  try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: unrelated)
  #expect(throws: DevelopmentError.self) {
    try DevelopmentMacBundle.commit(stage: stage, destination: destination, root: fixture.root, requireStopped: {})
  }
  #expect(try fixture.bundleContents(unrelated) == "Preserve unrelated executable")
  #expect(try fixture.bundleContents(stage) == "New executable")
}

@Test @MainActor func joinedDevelopmentCommandsRunLiteralArgumentsAndRestoreSignalHandlers() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  let literal = "literal;$(never-executed)"
  let command = DevelopmentCommand(executable: "/usr/bin/printf", arguments: ["%s", literal],
    directory: fixture.root, environment: [:])
  #expect(try DevelopmentProcess.capture(command) == literal)
  #expect(try DevelopmentProcess.capture(command) == literal)
  #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "never-executed").path))
}

@Test func caseAliasesOfTheSameBundleCannotBeSwappedAndDeleted() throws {
  let fixture = try DevelopmentFixture()
  defer { fixture.cleanup() }
  guard try fixture.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false else { return }
  let stage = fixture.root.appending(path: "build/.stage.app", directoryHint: .isDirectory)
  let alias = fixture.root.appending(path: "build/.STAGE.app", directoryHint: .isDirectory)
  try fixture.bundle(stage, content: "Preserve same bundle")
  #expect(throws: DevelopmentError.self) {
    try DevelopmentMacBundle.commit(stage: stage, destination: alias, root: fixture.root, requireStopped: {})
  }
  #expect(try fixture.bundleContents(stage) == "Preserve same bundle")
}

private struct DevelopmentFixture {
  let root: URL
  let cache: URL
  init() throws {
    root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appending(path: "Folio Development $(literal)-" + UUID().uuidString, directoryHint: .isDirectory)
    cache = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appending(path: "Folio Cache $(literal)-" + UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root.appending(path: "Folio.xcodeproj"), withIntermediateDirectories: true)
    try Data("// temporary fixture\n".utf8).write(to: root.appending(path: "Package.swift"))
  }
  func request(_ arguments: [String], environment: [String: String] = [:]) throws -> DevelopmentRequest {
    try DevelopmentRequest.parse(["--root", root.path] + arguments, environment: environment)
  }
  func bundle(_ directory: URL, content: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(content.utf8).write(to: directory.appending(path: "executable"))
  }
  func bundleContents(_ directory: URL) throws -> String {
    try String(contentsOf: directory.appending(path: "executable"), encoding: .utf8)
  }
  func cleanup() {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: cache)
  }
}

private func developmentBuildArguments(_ plan: DevelopmentPlan) -> [String] {
  plan.commands.flatMap { command in
    ["--scratch-path", "-derivedDataPath"].compactMap { flag in
      guard let index = command.arguments.firstIndex(of: flag), index + 1 < command.arguments.count else { return nil }
      return command.arguments[index + 1]
    }
  }
}
