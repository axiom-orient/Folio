import Foundation

/// Atomic replacement + file synchronization. This does not claim power-loss metadata durability.
package enum AcornryPersistence {
  package static func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    let handle = try FileHandle(forWritingTo: url)
    try synchronizeAndClose(handle)
  }

  package static func synchronizeAndClose(_ handle: FileHandle) throws {
    do { try handle.synchronize() } catch {
      do { try handle.close() } catch let cleanup {
        throw AcornryError.invalidState("persistence failed: \(error); close failed: \(cleanup)")
      }
      throw error
    }
    try handle.close()
  }
}
