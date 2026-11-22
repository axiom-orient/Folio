#if os(macOS)
import Darwin
import Foundation

enum SkillIO {
  /// Shared by separate stores and CLI processes. No suspension occurs while held.
  static func withMutationLock<T>(at root: URL, operation: () throws -> T) throws -> T {
    let descriptor = open(root.appendingPathComponent(".folio-mutations.lock").path,
      O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      throw SkillError.invalid("스킬 변경 잠금을 확인할 수 없습니다.")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK { throw SkillError.busy }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try operation()
  }

  static func read(_ url: URL, limit: Int) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
      status.st_size <= limit else { throw SkillError.invalid("파일 형식 또는 크기 제한을 확인해 주세요.") }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw SkillError.invalid("파일 크기 제한을 넘었습니다.") }
    return data
  }
}
#endif
