import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import SwiftUI

/// Renders the selected document while its window continues to own navigation.
struct WikiDocumentReaderView: View {
  let model: WikiAppModel
  @Bindable var window: WikiWindowState
  let document: WikiDocument
  let draft: WikiAppModel.Draft?
  let activity: String?
  let contentInset: CGFloat
  let onReview: () -> Void
  @Environment(\.colorScheme) private var scheme
  @ScaledMetric(relativeTo: .title) private var titleSize = 28.0
  @ScaledMetric(relativeTo: .body) private var bodySize = 17.0

  private func header(_ document: WikiDocument) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(document.title).font(.system(size: titleSize, weight: .semibold)).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
      if let activity {
        Text(activity).font(.callout).foregroundStyle(FolioTheme.muted(scheme))
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 24).id(document.id)
  }

  var body: some View {
      let titleSectionID = document.sections.first { $0.headingPath == [document.title] }?.id
      return ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
          header(document)
          if let draft, draft.isDirty, draft.revision != document.revision {
            WikiStaleDraftBanner(onReview: onReview)
          }
          if let pdf = WikiAttachmentImport.unmodifiedPDFPath(in: document) {
            Button {
              Task { await model.previewAttachment(path: pdf) }
            } label: {
              Label("PDF 원문 열기", systemImage: "doc.richtext")
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasOpenWorkspace)
            .accessibilityIdentifier("document-open-pdf")
          } else {
            ForEach(document.sections) { section in
              // A metadata-only note can contain a projected whole-source section.
              let readableSource = section.range.startLine == 1
                ? FolioEditorContent(source: section.sourceText).body : section.sourceText
              WikiMarkdownReader(source: readableSource, titleToOmit:
                section.id == titleSectionID ? document.title : nil)
                .equatable()
                .font(.system(size: bodySize)).lineSpacing(6)
                .environment(\.openURL, OpenURLAction { url in
                  if url.scheme == nil {
                    Task { await model.openMarkdownLink(url.relativeString, from: document, in: window) }; return .handled
                  }
                  if ["folio", "sourcewiki"].contains(url.scheme?.lowercased() ?? "") {
                    Task { await model.openLink(url, in: window) }; return .handled
                  }
                  return ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
                })
                .frame(maxWidth: .infinity, alignment: .leading).id(section.id)
            }
          }
        }.scrollTargetLayout().frame(maxWidth: 720, alignment: .leading)
          .foregroundStyle(FolioTheme.text(scheme))
          .padding(.horizontal, contentInset).padding(.bottom, 32).frame(maxWidth: .infinity)
      }
      .scrollPosition(id: Binding<String?>(get: { window.readingAnchors[document.id] },
        set: { if let id = $0 { window.readingAnchors[document.id] = id } }), anchor: .top)
      .onChange(of: window.selectedSectionID) { _, _ in applySelectedSection(document) }
      .id(document.id)
  }

  private func applySelectedSection(_ document: WikiDocument) {
    if let id = window.selectedSectionID, document.sections.contains(where: { $0.id == id }) {
      window.readingAnchors[document.id] = id
    }
  }

}

struct WikiStaleDraftBanner: View {
  let onReview: () -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("새 변경을 받았습니다. 저장할 때 함께 확인합니다.")
        .foregroundStyle(FolioTheme.text(scheme)).fixedSize(horizontal: false, vertical: true)
      Button("원문 버전 확인", action: onReview)
    }
    .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .background(FolioTheme.accent(scheme).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }
}
