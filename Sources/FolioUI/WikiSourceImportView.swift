import SwiftUI

struct WikiIncomingSource: Identifiable {
  let id = UUID()
  let url: URL
}

/// Keep the selected file while the user chooses a destination or corrects a failure.
struct WikiSourceImportView: View {
  let model: WikiAppModel
  let window: WikiWindowState
  let url: URL
  let imported: () -> Void
  @State private var isImporting = false
  @State private var error: String?
  @State private var showLibrary = false
  @Environment(\.dismiss) private var dismiss
  private var isWorkspace: Bool {
    url.pathExtension.lowercased() == "zip" || url.hasDirectoryPath
  }

  var body: some View {
    let target = model.receivedFileTarget
    NavigationStack {
      Form {
        Section {
          FolioFileHeader(name: url.lastPathComponent, icon: sourceIcon)
        }
        Section {
          if isWorkspace {
            LabeledContent("새 자료함", value: "이 기기")
          } else {
            destinationRow(target)
          }
        }
        if let error { Section { FolioMessage(message: error) } }
      }.formStyle(.grouped).navigationTitle(isWorkspace ? "자료함 가져오기" : "문서 추가")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(isImporting) }
          ToolbarItem(placement: .confirmationAction) {
            Button(actionTitle) { add(to: target) }
              .disabled(isImporting || model.isBusy || (!isWorkspace && target == nil))
          }
        }.disabled(isImporting)
        .interactiveDismissDisabled(isImporting)
        .modifier(WikiLibraryPresentation(model: model, window: window, isPresented: $showLibrary))
    }.folioSheetSize(width: 500, height: 400)
  }

  private var sourceIcon: String {
    if url.hasDirectoryPath { return "folder" }
    if isWorkspace { return "archivebox" }
    return url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.text"
  }

  private var actionTitle: String {
    if isImporting { return "가져오는 중…" }
    if isWorkspace { return "가져오기" }
    if model.hasPendingMarkdownImport(url) || model.fileIntake.hasPendingCapture(url) { return "결과 확인" }
    return "추가"
  }

  private func destinationRow(_ target: FolioReceivedTarget?) -> some View {
    let name = target.flatMap { _ in model.snapshot?.workspace.name }
    return Button { showLibrary = true } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(name ?? "자료함 선택").foregroundStyle(.primary)
          if let target { Text(target.storageTitle).font(.callout).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
          .foregroundStyle(.secondary).accessibilityHidden(true)
      }.frame(minHeight: 44).contentShape(Rectangle())
    }.buttonStyle(.plain)
      .accessibilityLabel("자료함 선택")
      .accessibilityValue([name, target?.storageTitle].compactMap { $0 }.joined(separator: ", "))
  }

  private func add(to target: FolioReceivedTarget?) {
    guard !isImporting, !model.isBusy else { return }
    isImporting = true; error = nil
    Task {
      if !isWorkspace, (target == nil || model.receivedFileTarget != target) {
        isImporting = false; error = "자료함이 바뀌었습니다. 추가할 위치를 다시 확인하세요."; return
      }
      let success: Bool
      if isWorkspace { success = await model.importWorkspaceSource(url, in: window) }
      else { success = await model.importSource(url, in: window, expectedTarget: target) }
      isImporting = false
      if success { imported() }
      else { error = model.message ?? "파일을 가져오지 못했습니다. 원본과 자료함을 확인하세요." }
    }
  }
}
