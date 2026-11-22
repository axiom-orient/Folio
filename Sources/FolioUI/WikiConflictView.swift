import FolioKnowledgeApple
import FolioKnowledge
import Foundation
import SwiftUI

struct WikiConflictView: View {
  let model: WikiAppModel
  let selection: WikiAppModel.ConflictSelection
  @State private var selectedID: String
  @State private var isResolving = false
  @Environment(\.dismiss) private var dismiss

  init(model: WikiAppModel, selection: WikiAppModel.ConflictSelection) {
    self.model = model; self.selection = selection
    _selectedID = State(initialValue: selection.versions.first(where: { $0.isCurrent })?.id ?? "")
  }
  private var chosen: WikiConflictVersion? { selection.versions.first { $0.id == selectedID } }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Picker("남길 내용", selection: $selectedID) {
          ForEach(selection.versions) { version in
            Text(contentTitle(version)).tag(version.id)
          }
        }
        if let chosen {
          let metadataDiffers = self.metadataDiffers
          if chosen.isCurrent { versionPane(chosen, title: "지금 문서", showMetadata: metadataDiffers) }
          else if let current = selection.versions.first(where: { $0.isCurrent }) {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 16) {
                versionPane(current, title: "지금 문서", showMetadata: metadataDiffers)
                versionPane(chosen, title: "받은 내용", showMetadata: metadataDiffers)
              }
              VStack(spacing: 16) {
                versionPane(current, title: "지금 문서", showMetadata: metadataDiffers)
                versionPane(chosen, title: "받은 내용", showMetadata: metadataDiffers)
              }
            }
          }
        }
        if let message = model.message { FolioMessage(message: message) }
      }.padding(24).navigationTitle("변경 내용 확인")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("나중에") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button(isResolving ? "적용 중…" : "이 내용 사용") {
              guard let chosen, !isResolving else { return }
              isResolving = true
              Task { await model.resolveConflict(selection, version: chosen); isResolving = false }
            }.disabled(chosen == nil || !model.hasOpenWorkspace || model.openedSourceRoot != selection.sourceRoot || isResolving)
          }
        }.disabled(isResolving)
    }.folioSheetSize(width: 640, height: 560)
  }

  private func contentTitle(_ version: WikiConflictVersion) -> String {
    if version.isCurrent { return "지금 문서" }
    return version.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "받은 내용"
  }

  private func versionPane(_ version: WikiConflictVersion, title: String, showMetadata: Bool) -> some View {
    let content = FolioEditorContent(source: version.text)
    return VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      if let date = version.modifiedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
      if showMetadata {
        DisclosureGroup("문서 정보") {
          if let info = try? WikiMarkdownParser.document(relativePath: selection.path, bytes: Data(version.text.utf8)) {
            LabeledContent("제목", value: info.title)
            LabeledContent("태그", value: info.tags.joined(separator: " · "))
          }
          DisclosureGroup("자세히") {
            Text(verbatim: content.metadata)
              .font(.caption.monospaced()).textSelection(.enabled)
          }
        }
      }
      ScrollView {
        Text(content.body).font(.body).textSelection(.enabled)
          .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
        .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
  }

  private var metadataDiffers: Bool {
    guard let first = selection.versions.first else { return false }
    let metadata = Data(FolioEditorContent(source: first.text).metadata.utf8)
    return selection.versions.dropFirst().contains {
      Data(FolioEditorContent(source: $0.text).metadata.utf8) != metadata
    }
  }
}
