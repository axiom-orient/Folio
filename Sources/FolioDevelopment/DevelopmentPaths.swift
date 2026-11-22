import Darwin
import Foundation
import CryptoKit

struct DevelopmentBuildPaths: Sendable {
  let root: URL
  var swiftPM: URL { root.appendingPathComponent("SwiftPM", isDirectory: true) }
  var products: URL { root.appendingPathComponent("Products", isDirectory: true) }
  var macApp: URL { products.appendingPathComponent("FolioMac.app", isDirectory: true) }
  var ios: URL { root.appendingPathComponent("IOSSimulator", isDirectory: true) }
  var iosApp: URL { ios.appendingPathComponent("Build/Products/Debug-iphonesimulator/FolioIOS.app", isDirectory: true) }
  var signedMac: URL { root.appendingPathComponent("SignedMac", isDirectory: true) }
  var signedMacApp: URL { signedMac.appendingPathComponent("Build/Products/Debug/FolioMac.app", isDirectory: true) }
  var iphone: URL { root.appendingPathComponent("IPhone", isDirectory: true) }
  var iphoneApp: URL { iphone.appendingPathComponent("Build/Products/Debug-iphoneos/FolioIOS.app", isDirectory: true) }
}

enum DevelopmentPaths {
  static func buildRoot(repository: URL, override: String?) throws -> URL {
    if let override {
      guard override.hasPrefix("/"), !override.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw DevelopmentError.invalidArguments
      }
      let components = lexicalComponents(URL(fileURLWithPath: override))
      return URL(fileURLWithPath: "/" + components.dropFirst().joined(separator: "/"), isDirectory: true)
    }
    let identity = SHA256.hash(data: Data(repository.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Developer/FolioBuilds/Development", isDirectory: true)
      .appendingPathComponent(identity, isDirectory: true)
  }
  static func repository(_ path: String) throws -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    let supplied = URL(fileURLWithPath: expanded, isDirectory: true)
    guard let pointer = realpath(supplied.path, nil) else { throw DevelopmentError.invalidRepository }
    defer { free(pointer) }
    let root = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    let package = try? root.appendingPathComponent("Package.swift").resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    let project = try? root.appendingPathComponent("Folio.xcodeproj").resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard package?.isRegularFile == true, package?.isSymbolicLink != true,
      project?.isDirectory == true, project?.isSymbolicLink != true else { throw DevelopmentError.invalidRepository }
    return root
  }

  static func validate(_ url: URL, root: URL) throws {
    let components = lexicalComponents(url)
    let prefix = lexicalComponents(root)
    guard components.count > prefix.count, Array(components.prefix(prefix.count)) == prefix else { throw DevelopmentError.unsafeOutput }
    var current = root
    for component in components.dropFirst(prefix.count) {
      current.appendPathComponent(component)
      var value = stat()
      if lstat(current.path, &value) == 0 {
        guard value.st_mode & S_IFMT != S_IFLNK else { throw DevelopmentError.unsafeOutput }
      } else if errno != ENOENT { throw DevelopmentError.unsafeOutput }
    }
  }

  /// URL.standardizedFileURL rewrites /private/tmp aliases based on whether
  /// endpoints exist. Scope checks need lexical dot removal without I/O.
  static func lexicalComponents(_ url: URL) -> [String] {
    var result: [String] = []
    for component in url.pathComponents {
      if component == "." { continue }
      if component == ".." {
        if result.count > 1 { result.removeLast() }
      } else { result.append(component) }
    }
    return result
  }

  static func canonicalExisting(_ url: URL) throws -> URL {
    guard let pointer = realpath(url.path, nil) else { throw DevelopmentError.unsafeOutput }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
  }

  static func validateBuildPaths(_ request: DevelopmentRequest) throws {
    let output = lexicalComponents(request.buildRoot)
    let repository = lexicalComponents(request.root)
    guard !output.starts(with: repository), !repository.starts(with: output) else { throw DevelopmentError.unsafeOutput }
    try validate(request.buildRoot, root: URL(fileURLWithPath: "/", isDirectory: true))
    let paths = request.buildPaths
    for path in [paths.swiftPM, paths.products, paths.ios, paths.signedMac, paths.iphone] {
      try validate(path, root: request.buildRoot)
    }
  }
}
