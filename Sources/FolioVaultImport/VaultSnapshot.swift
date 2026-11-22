import Darwin
import Foundation

struct VaultSnapshot {
  static let maximumFiles = 10_000
  static let maximumBytes = 256 * 1024 * 1024
  static let maximumMarkdownBytes = 256 * 1024
  let locations: VaultImportLocations
  let files: [VaultInputFile]

  init(_ request: VaultImportRequest) throws {
    let locations = try VaultImportLocations(request)
    self.locations = locations
    files = try Self.readFiles(locations.source)
    guard files.contains(where: \.isMarkdown) else {
      throw VaultImportError.invalid("원본 폴더에 Markdown 문서가 필요합니다.")
    }
  }

  private static func readFiles(_ source: URL) throws -> [VaultInputFile] {
    let root = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(root) }
    var failure: (any Error)?
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey]
    guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys,
      errorHandler: { _, error in failure = error; return false }) else {
      throw VaultImportError.invalid("원본 폴더를 읽지 못했습니다.")
    }
    var result: [VaultInputFile] = []; var total = 0
    for case let url as URL in enumerator {
      let metadata = try url.resourceValues(forKeys: Set(keys))
      if url.lastPathComponent.hasPrefix(".") || metadata.isHidden == true {
        if metadata.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard metadata.isSymbolicLink != true else { throw VaultImportError.invalid("심볼릭 링크가 포함된 원본은 가져오지 않습니다.") }
      if metadata.isDirectory == true { continue }
      guard metadata.isRegularFile == true else { throw VaultImportError.invalid("원본은 일반 파일과 폴더로 구성되어야 합니다.") }
      guard result.count < maximumFiles else { throw VaultImportError.invalid("원본은 파일 10,000개 이하여야 합니다.") }
      let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
      let markdown = VaultInputFile.isMarkdownExtension(url.pathExtension)
      let limit = min(maximumBytes - total, markdown ? maximumMarkdownBytes : maximumBytes)
      let data = try read(root: root, relative: relative, limit: limit)
      total += data.count
      result.append(VaultInputFile(relativePath: relative, data: data))
    }
    if let failure { throw failure }
    return result.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
  }

  private static func read(root: Int32, relative: String, limit: Int) throws -> Data {
    let components = relative.split(separator: "/").map(String.init)
    guard let filename = components.last else { throw VaultImportError.invalid("원본 파일 경로를 확인하세요.") }
    var directory = dup(root)
    guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(directory) }
    for component in components.dropLast() {
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw VaultImportError.invalid("원본 폴더가 변경되었거나 심볼릭 링크입니다.") }
      close(directory); directory = next
    }
    let descriptor = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw VaultImportError.invalid("원본 파일을 안전하게 읽지 못했습니다.") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= limit else {
      throw VaultImportError.invalid("Markdown 256 KiB·전체 256 MiB 크기 제한 또는 파일 형식을 확인하세요.")
    }
    var data = Data()
    while let chunk = try handle.read(upToCount: min(1_048_576, limit + 1 - data.count)), !chunk.isEmpty {
      data.append(chunk)
      guard data.count <= limit else { throw VaultImportError.invalid("원본 파일이 크기 제한을 넘었습니다.") }
    }
    var final = stat()
    guard fstat(descriptor, &final) == 0, data.count == metadata.st_size,
      final.st_size == metadata.st_size, final.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
      final.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec,
      final.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec,
      final.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec else {
      throw VaultImportError.invalid("읽는 동안 원본 파일이 변경되었습니다. 안정된 원본에서 다시 가져오세요.")
    }
    return data
  }
}
