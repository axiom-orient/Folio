import FolioKnowledge
import SwiftUI

struct WikiDocumentInfoView: View {
  let document: WikiDocument
  var isCurrent = true
  var onReviewSource: () -> Void = {}
  @State private var revisionExpanded = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        if !isCurrent { Section { FolioMessage(message: "열었을 때의 문서 정보입니다. 최신 정보는 문서를 다시 열어 확인하세요.") } }
        Section {
          Text(document.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
          LabeledContent("유형", value: FolioTheme.typeName(document.type))
          if !document.tags.isEmpty {
            LabeledContent("태그") {
              Text(document.tags.joined(separator: " · ")).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        Section {
          DisclosureGroup("파일 위치") {
            Text(document.relativePath).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          DisclosureGroup("문서 구조 · \(document.sections.count)개 구획") {
            ForEach(document.sections) { section in
              VStack(alignment: .leading, spacing: 4) {
                Text(section.headingPath.isEmpty ? "본문" : section.headingPath.joined(separator: " › "))
                Text("\(section.range.startLine)–\(section.range.endLine)줄").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          DisclosureGroup("원문 버전", isExpanded: Binding(
            get: { revisionExpanded }, set: { expanded in
              let wasExpanded = revisionExpanded
              revisionExpanded = expanded
              if expanded && !wasExpanded && isCurrent { onReviewSource() }
            })) {
            Text(document.revision).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
        }
      }.formStyle(.grouped).lineLimit(nil).navigationTitle("문서 정보")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
    }.folioSheetSize(width: 480, height: 420)
  }
}
