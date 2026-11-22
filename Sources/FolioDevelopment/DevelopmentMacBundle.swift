import Darwin
import Foundation

enum DevelopmentMacBundle {
  static func preview(_ request: DevelopmentRequest) -> [DevelopmentCommand] {
    [binPathCommand(request), signCommand(request, bundle: request.buildPaths.products.appendingPathComponent(".FolioMac-<stage>.app")), DevelopmentPlan.macProcessCommand(request)]
  }

  @MainActor static func prepare(_ request: DevelopmentRequest) throws {
    let root = request.root
    let paths = request.buildPaths
    let path = try DevelopmentProcess.capture(binPathCommand(request))
    guard path.hasPrefix("/"), !path.contains("\n") else { throw DevelopmentError.unsafeOutput }
    let products = try DevelopmentPaths.canonicalExisting(URL(fileURLWithPath: path, isDirectory: true))
    try DevelopmentPaths.validate(products, root: paths.swiftPM)
    let binary = products.appendingPathComponent("FolioMac")
    let build = paths.products
    let destination = paths.macApp
    try DevelopmentPaths.validate(destination, root: request.buildRoot)
    let manager = FileManager.default
    try manager.createDirectory(at: build, withIntermediateDirectories: true)
    let stage = build.appendingPathComponent(".FolioMac-" + UUID().uuidString + ".app", isDirectory: true)
    try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let stagedIdentity = try Identity(stage)
    defer { if stagedIdentity.owns(stage) { try? manager.removeItem(at: stage) } }
    let executableDirectory = stage.appendingPathComponent("Contents/MacOS", isDirectory: true)
    let resources = stage.appendingPathComponent("Contents/Resources", isDirectory: true)
    try manager.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
    try manager.createDirectory(at: resources, withIntermediateDirectories: true)
    let executable = executableDirectory.appendingPathComponent("FolioMac")
    try manager.copyItem(at: binary, to: executable)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let icon = root.appendingPathComponent("Assets/FolioIcon.icns")
    if manager.fileExists(atPath: icon.path) { try manager.copyItem(at: icon, to: resources.appendingPathComponent(icon.lastPathComponent)) }
    for resource in try manager.contentsOfDirectory(at: products, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
      guard resource.pathExtension == "bundle", try resource.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
      try manager.copyItem(at: resource, to: resources.appendingPathComponent(resource.lastPathComponent))
    }
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: stage.appendingPathComponent("Contents/Info.plist"), options: .withoutOverwriting)
    try DevelopmentProcess.run(signCommand(request, bundle: stage))
    try commit(stage: stage, destination: destination, root: request.buildRoot) {
      // The app may have launched during compilation or signing.
      try DevelopmentProcess.requireStopped(DevelopmentPlan.macProcessCommand(request), matchingExecutable: nil)
    }
  }

  static func commit(stage: URL, destination: URL, root: URL, requireStopped: () throws -> Void) throws {
    guard DevelopmentPaths.lexicalComponents(stage) != DevelopmentPaths.lexicalComponents(destination),
      DevelopmentPaths.lexicalComponents(stage.deletingLastPathComponent()) ==
        DevelopmentPaths.lexicalComponents(destination.deletingLastPathComponent()) else {
      throw DevelopmentError.unsafeOutput
    }
    try DevelopmentPaths.validate(stage, root: root)
    try DevelopmentPaths.validate(destination, root: root)
    let stagedIdentity = try Identity(stage)
    try requireStopped()
    let manager = FileManager.default
    if manager.fileExists(atPath: destination.path) {
      let previous = try Identity(destination)
      guard previous.device != stagedIdentity.device || previous.inode != stagedIdentity.inode else {
        throw DevelopmentError.unsafeOutput
      }
      guard stagedIdentity.owns(stage), previous.owns(destination),
        renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else { throw DevelopmentError.unsafeOutput }
      do {
        guard previous.owns(stage) else { throw DevelopmentError.unsafeOutput }
        try manager.removeItem(at: stage)
      } catch { throw DevelopmentError.bundleCleanup(stage) }
    } else {
      guard stagedIdentity.owns(stage),
        renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw DevelopmentError.unsafeOutput }
    }
  }

  private static func binPathCommand(_ request: DevelopmentRequest) -> DevelopmentCommand {
    DevelopmentPlan.command(request, "/usr/bin/xcrun", ["swift", "build", "--package-path", request.root.appendingPathComponent("MacApp").path, "--scratch-path", request.buildPaths.swiftPM.path, "--show-bin-path"])
  }
  private static func signCommand(_ request: DevelopmentRequest, bundle: URL) -> DevelopmentCommand {
    DevelopmentPlan.command(request, "/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "com.axient.Folio", bundle.path])
  }

  private struct Identity {
    let device: dev_t
    let inode: ino_t
    init(_ url: URL) throws {
      var value = stat()
      guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw DevelopmentError.unsafeOutput }
      device = value.st_dev; inode = value.st_ino
    }
    func owns(_ url: URL) -> Bool {
      var value = stat()
      return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR && value.st_dev == device && value.st_ino == inode
    }
  }

  private static let info: [String: any Sendable] = [
    "CFBundleExecutable": "FolioMac", "CFBundleIdentifier": "com.axient.Folio", "CFBundleName": "Folio",
    "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "27.0", "CFBundleDisplayName": "Folio",
    "CFBundleIconFile": "FolioIcon", "NSPrincipalClass": "NSApplication",
    "CFBundleURLTypes": [["CFBundleURLSchemes": ["folio", "sourcewiki"]]],
    "SEMICapabilityProvider": ["contractVersion": 2, "transport": "xpc-rendezvous", "features": ["data-transfer-review"]] as [String: any Sendable],
  ]
}
