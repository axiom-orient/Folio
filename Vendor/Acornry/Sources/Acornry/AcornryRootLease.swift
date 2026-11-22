import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Process-lifetime ownership for a dedicated persistence root.
package final class AcornryRootLease: @unchecked Sendable {
  private let descriptor: Int32

  package init(root: URL) throws {
    try AcornryPath.ensureDirectory(root)
    let fd = open(
      root.appendingPathComponent(".acornry.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW,
      mode_t(0o600))
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      _ = close(fd)
      throw AcornryError.invalidConfiguration("root is already owned: \(root.path) (errno \(code))")
    }
    descriptor = fd
  }

  deinit { _ = close(descriptor) }
}
