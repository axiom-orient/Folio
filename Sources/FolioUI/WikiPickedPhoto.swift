#if os(iOS)
import CoreTransferable
import Foundation
import FolioKnowledgeApple
import FolioKnowledge
import UniformTypeIdentifiers

struct WikiPickedPhoto: Transferable, Sendable {
  /// The temporary copy belongs to the selection until its deferred import
  /// finishes or is abandoned by a dismissed presentation.
  private final class Storage: Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  }
  private let storage: Storage
  var url: URL { storage.url }

  private init(url: URL) { storage = Storage(url: url) }
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      let size = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard size > 0, size <= 50 * 1024 * 1024 else { throw WikiError.invalidSource("사진은 50 MiB 이하여야 합니다.") }
      let parent = FileManager.default.temporaryDirectory.appendingPathComponent("FolioPhoto/\(UUID())")
      try WikiLocalStorage.createDirectory(parent)
      let destination = parent.appendingPathComponent(received.file.lastPathComponent)
      do { try FileManager.default.copyItem(at: received.file, to: destination) }
      catch {
        try? FileManager.default.removeItem(at: parent)
        throw error
      }
      return WikiPickedPhoto(url: destination)
    }
  }
}
#endif
