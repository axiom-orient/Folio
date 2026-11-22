import SwiftUI

struct FolioMessage: View {
  let message: String
  var body: some View {
    Label { Text(message).textSelection(.enabled) } icon: { Image(systemName: "info.circle") }
      .font(.callout).fixedSize(horizontal: false, vertical: true)
  }
}

struct FolioFileHeader: View {
  let name: String
  var detail: String? = nil
  var icon = "doc.text"
  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon).font(.title).foregroundStyle(.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(name).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct FolioActionLabel: View {
  let title: String
  let icon: String
  var body: some View {
    Label(title, systemImage: icon).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
  }
}

extension View {
  @ViewBuilder func folioSheetSize(width: CGFloat, height: CGFloat) -> some View {
    #if os(macOS)
    frame(width: width, height: height)
    #else
    self
    #endif
  }
}
