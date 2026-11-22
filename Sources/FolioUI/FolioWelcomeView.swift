import SwiftUI

struct FolioWelcomeView: View {
  let openLibrary: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    ContentUnavailableView {
      Label { Text("열린 자료함이 없습니다") } icon: {
        FolioBrandMark().frame(width: 64, height: 44).foregroundStyle(FolioTheme.accent(scheme))
      }
    } actions: {
      Button("자료함 열기", action: openLibrary)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("library-picker")
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
