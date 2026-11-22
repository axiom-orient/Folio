import SwiftUI
import UniformTypeIdentifiers

/// One immutable set of file types per native presentation, including cancellation.
struct WikiFilePicker: View {
  static var documentContentTypes: [UTType] {
    [.pdf, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
  }

  let contentTypes: [UTType]
  let cancellation: () -> Void
  let completion: (Result<[URL], Error>) -> Void
  @State private var isPresented = false
  @ViewBuilder
  var body: some View {
    #if os(macOS)
    if contentTypes.contains(.folder) {
      WikiFolderPicker(contentTypes: contentTypes, cancellation: cancellation, completion: completion)
        .frame(width: 0, height: 0)
    } else { swiftUIPicker }
    #else
    swiftUIPicker
    #endif
  }
  private var swiftUIPicker: some View {
    Color.clear.frame(width: 0, height: 0)
      .fileImporter(isPresented: $isPresented, allowedContentTypes: contentTypes,
        allowsMultipleSelection: false, onCompletion: completion, onCancellation: cancellation)
      .task { isPresented = true }
  }
}
