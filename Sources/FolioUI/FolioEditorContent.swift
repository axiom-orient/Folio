import Foundation

/// A reversible presentation of the same draft. Metadata bytes stay with the source owner.
struct FolioEditorContent {
  private static let maximumMetadataBytes = 65_536
  let metadata: String
  let body: String
  private let newline: String

  init(source: String) {
    let bytes = Array(source.utf8.prefix(Self.maximumMetadataBytes + 1))
    func line(at start: Int) -> (text: ArraySlice<UInt8>, end: Int) {
      let end = bytes[start...].firstIndex(of: 10).map { $0 + 1 } ?? bytes.count
      var contentEnd = end
      if contentEnd > start, bytes[contentEnd - 1] == 10 { contentEnd -= 1 }
      if contentEnd > start, bytes[contentEnd - 1] == 13 { contentEnd -= 1 }
      return (bytes[start..<contentEnd], end)
    }
    newline = source.utf8.prefix(Self.maximumMetadataBytes).contains(13) ? "\r\n" : "\n"
    guard !bytes.isEmpty else { metadata = ""; body = source; return }
    let first = line(at: 0)
    guard first.text.elementsEqual([45, 45, 45]) || first.text.elementsEqual([239, 187, 191, 45, 45, 45]) else {
      metadata = ""; body = source; return
    }
    var cursor = first.end
    while cursor < bytes.count {
      let next = line(at: cursor)
      if next.end > Self.maximumMetadataBytes { break }
      if next.text.elementsEqual([45, 45, 45]) {
        let prefix = String(decoding: bytes[..<next.end], as: UTF8.self)
        metadata = prefix; body = String(source.dropFirst(prefix.count)); return
      }
      cursor = next.end
    }
    // An incomplete header is editable as written; never silently hide ambiguous text.
    metadata = ""; body = source
  }

  func replacingBody(with text: String) -> String {
    let separator = !metadata.isEmpty && metadata.utf8.last != 10 && !text.isEmpty ? newline : ""
    return metadata + separator + text
  }
}
