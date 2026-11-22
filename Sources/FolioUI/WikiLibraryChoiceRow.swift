import SwiftUI

struct WikiLibraryChoiceRow: View {
  @Environment(\.colorScheme) private var scheme
  let choice: FolioLibraryChoice
  var isCurrent = false
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Image(systemName: "folder").font(.body).foregroundStyle(FolioTheme.accent(scheme)).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(choice.name).font(.body.weight(isCurrent ? .semibold : .regular)).foregroundStyle(FolioTheme.text(scheme))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          if let notice = choice.notice {
            Label(notice.text, systemImage: notice.symbol).font(.caption)
              .foregroundStyle(FolioTheme.text(scheme)).fixedSize(horizontal: false, vertical: true)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).lineLimit(nil)
        if isCurrent {
          Image(systemName: "checkmark").font(.body.weight(.semibold))
            .foregroundStyle(FolioTheme.accent(scheme)).accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier(choice.id.accessibilityIdentifier)
    .accessibilityLabel(choice.name)
    .accessibilityValue([choice.storage.title, choice.notice?.text].compactMap { $0 }.joined(separator: ", "))
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
    .accessibilityHint(isCurrent ? "현재 자료함으로 돌아갑니다" : "이 자료함의 문서를 엽니다")
    .help(choice.name)
  }
}
