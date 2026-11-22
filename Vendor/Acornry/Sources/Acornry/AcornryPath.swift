import Foundation

package enum AcornryPath {
  package static func validate(_ value: String) throws -> String {
    guard !value.isEmpty else { throw AcornryError.invalidPath(value) }
    let normalized = value.replacingOccurrences(of: "\\", with: "/")
      .precomposedStringWithCanonicalMapping
    guard !normalized.hasPrefix("/"), normalized.utf8.count <= 4_096 else {
      throw AcornryError.invalidPath(value)
    }
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      !components.contains(where: { component in
        component.isEmpty || component == "." || component == ".." || component.utf8.count > 255
          || component.unicodeScalars.contains(where: {
            $0.value == 0 || CharacterSet.controlCharacters.contains($0)
          })
      })
    else { throw AcornryError.invalidPath(value) }
    return normalized
  }

  package static func safeDescendant(_ relativePath: String, under root: URL) throws -> URL {
    let validated = try validate(relativePath)
    let canonicalRoot = root.standardizedFileURL
    let target = canonicalRoot.appendingPathComponent(validated, isDirectory: false)
      .standardizedFileURL
    let rootPrefix =
      canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
    guard target.path.hasPrefix(rootPrefix) else { throw AcornryError.invalidPath(relativePath) }
    return target
  }

  package static func ensureDirectory(_ url: URL, fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw AcornryError.invalidPath(url.path)
    }
  }

  package static func requireDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw AcornryError.invalidPath(url.path)
    }
  }

  package static func requireRegularFile(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw AcornryError.invalidPath(url.path)
    }
  }

  /// Staging and committed payloads use the same path, size and digest checks.
  static func verifyFile(_ url: URL, expected: AcornryManifestFile, under root: URL) throws {
    try verifyNoSymlinks(from: root, to: url)
    try requireRegularFile(url)
    let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
    guard size == expected.byteCount,
      try AcornrySHA256.hexDigest(ofFileAt: url) == expected.checksumSHA256
    else { throw AcornryError.integrityMismatch(expected.relativePath) }
  }

  package static func createSafeParentDirectories(
    for target: URL,
    under root: URL,
    fileManager: FileManager = .default
  ) throws {
    try ensureDirectory(root, fileManager: fileManager)
    let rootComponents = root.standardizedFileURL.pathComponents
    let parentComponents = target.deletingLastPathComponent().standardizedFileURL.pathComponents
    guard parentComponents.count >= rootComponents.count,
      Array(parentComponents.prefix(rootComponents.count)) == rootComponents
    else { throw AcornryError.invalidPath(target.path) }

    var current = root.standardizedFileURL
    for component in parentComponents.dropFirst(rootComponents.count) {
      current.appendPathComponent(component, isDirectory: true)
      if fileManager.fileExists(atPath: current.path) {
        let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw AcornryError.invalidPath(current.path)
        }
      } else {
        try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
      }
    }
  }

  package static func removeIfPresent(_ url: URL, fileManager: FileManager = .default) throws {
    do { try fileManager.removeItem(at: url) } catch let error as CocoaError
      where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    { return }
  }

  package static func verifyNoSymlinks(from root: URL, to target: URL) throws {
    try requireDirectory(root)
    let rootComponents = root.standardizedFileURL.pathComponents
    let components = target.standardizedFileURL.pathComponents
    guard components.count >= rootComponents.count,
      Array(components.prefix(rootComponents.count)) == rootComponents
    else { throw AcornryError.invalidPath(target.path) }
    var current = root.standardizedFileURL
    for component in components.dropFirst(rootComponents.count) {
      current.appendPathComponent(component)
      guard FileManager.default.fileExists(atPath: current.path) else { continue }
      let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw AcornryError.invalidPath(current.path) }
    }
  }
}
