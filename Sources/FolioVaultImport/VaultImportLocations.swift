import Darwin
import Foundation

/// Validates and retains the canonical, nonoverlapping roots before source reads.
struct VaultImportLocations {
  let source: URL
  let destination: URL
  let evidence: URL

  init(_ request: VaultImportRequest) throws {
    guard [request.source, request.destination, request.evidence].allSatisfy(\.isFileURL),
      !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw VaultImportError.invalid("원본·대상·증거 폴더와 자료함 이름을 확인하세요.")
    }
    for url in [request.source, request.destination, request.evidence] { try Self.validateAncestors(url) }
    let original = request.source.standardizedFileURL
    let values = try original.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw VaultImportError.invalid("원본은 심볼릭 링크가 아닌 실제 폴더여야 합니다.")
    }
    source = try Self.canonicalExisting(original)
    guard !Self.exists(request.destination), !Self.exists(request.evidence) else {
      throw VaultImportError.invalid("대상과 증거 폴더는 새 경로여야 합니다. 기존 자료를 덮어쓰지 않습니다.")
    }
    destination = try Self.canonicalProspective(request.destination)
    evidence = try Self.canonicalProspective(request.evidence)
    let roots = [source, destination, evidence]
    let paths = try roots.map(Self.comparisonPath)
    for first in roots.indices {
      for second in roots.indices where second > first {
        guard !Self.overlaps(paths[first], paths[second]) else {
          throw VaultImportError.invalid("원본·대상·증거 폴더는 서로 겹치거나 포함할 수 없습니다.")
        }
      }
    }
  }

  private static func exists(_ url: URL) -> Bool {
    var value = stat()
    return lstat(url.path, &value) == 0
  }

  private static func canonicalExisting(_ url: URL) throws -> URL {
    guard let pointer = realpath(url.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
  }

  private static func validateAncestors(_ url: URL) throws {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    let systemAliases = ["/tmp": "/private/tmp", "/var": "/private/var", "/etc": "/private/etc"]
    for component in url.standardizedFileURL.pathComponents.dropFirst() {
      current.appendPathComponent(component)
      var metadata = stat()
      if lstat(current.path, &metadata) != 0 { break }
      if metadata.st_mode & S_IFMT == S_IFLNK {
        guard let expected = systemAliases[current.path], metadata.st_uid == 0,
          try canonicalExisting(current).path == expected else {
          throw VaultImportError.invalid("사용자가 만든 심볼릭 링크 경로는 원본·출력 폴더로 사용할 수 없습니다.")
        }
      }
    }
  }

  private static func canonicalProspective(_ url: URL) throws -> URL {
    var ancestor = url.standardizedFileURL
    var suffix: [String] = []
    while !exists(ancestor) {
      let parent = ancestor.deletingLastPathComponent()
      guard parent != ancestor else { throw VaultImportError.invalid("출력 폴더의 상위 경로를 찾지 못했습니다.") }
      suffix.append(ancestor.lastPathComponent); ancestor = parent
    }
    let values = try ancestor.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else { throw VaultImportError.invalid("출력 폴더의 상위 경로가 폴더가 아닙니다.") }
    return suffix.reversed().reduce(try canonicalExisting(ancestor)) { $0.appendingPathComponent($1, isDirectory: true) }
  }

  private static func comparisonPath(_ url: URL) throws -> String {
    var existing = url
    while !exists(existing) { existing.deleteLastPathComponent() }
    let sensitive = try existing.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
    return sensitive == false ? VaultPaths.key(url.path) : url.path
  }

  private static func overlaps(_ first: String, _ second: String) -> Bool {
    first == "/" || second == "/" || first == second
      || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
  }
}
