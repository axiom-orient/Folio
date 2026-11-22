import FolioNearbyTransport
import SwiftUI

struct WikiReceivedFile: Identifiable, Hashable {
  let receipt: AcornryImportReceipt
  let file: AcornrySavedFile
  var id: String { receipt.transferID.rawValue.uuidString + "/" + file.relativePath }
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.file == rhs.file && lhs.receipt.state == rhs.receipt.state }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct WikiReceivedFileView: View {
  let model: WikiAppModel
  let window: WikiWindowState
  let selection: WikiReceivedFile
  let added: () -> Void
  @State private var error: String?
  @State private var isAdding = false
  @State private var showLibrary = false
  private var receipt: AcornryImportReceipt {
    (model.nearby.received + model.nearby.archived).first { $0.transferID == selection.receipt.transferID } ?? selection.receipt
  }
  private var file: AcornrySavedFile { receipt.savedFiles.first { $0.relativePath == selection.file.relativePath } ?? selection.file }
  private var kind: FolioTransferFileKind { FolioTransferFileKind(url: file.fileURL) }

  var body: some View {
    let target = model.receivedFileTarget
    Form {
      Section {
        HStack(alignment: .top) {
          FolioFileHeader(name: receipt.displayName,
            detail: ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file),
            icon: kind == .archive ? "archivebox" : kind == .document ? "doc.text" : "paperclip")
          fileOptions
        }.padding(.vertical, 8)
      }
      Section {
        DisclosureGroup("원본 파일 정보") {
          LabeledContent("파일명") { Text(file.relativePath).textSelection(.enabled) }
        }
      }
      Section("대상") {
        if kind == .archive {
          LabeledContent("저장 위치", value: "이 기기")
          Text("새 자료함으로 가져옵니다. 기존 자료함은 유지합니다.").font(.callout).foregroundStyle(.secondary)
        } else {
          LabeledContent("자료함", value: model.snapshot?.workspace.name ?? "선택 필요")
          LabeledContent("저장 위치", value: target?.storageTitle ?? "선택 필요")
          Button(model.hasOpenWorkspace ? "다른 자료함 선택" : "자료함 선택") { showLibrary = true }
        }
      }
      if receipt.state == .partial {
        Section {
          FolioMessage(message: "파일 저장을 완료하지 못했습니다.")
          if model.nearby.canRetryStorage(selection.receipt.transferID) {
            Button("저장 다시 시도") { Task { await model.nearby.retryStorage(selection.receipt.transferID) } }
              .disabled(model.nearby.isWorking)
          } else {
            Text("수신 원본을 확인할 수 없습니다. 기존 파일은 보존했습니다.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section {
        Text("받은 원본과 전송 기록은 보관합니다.").font(.callout).foregroundStyle(.secondary)
      }
      if let error { Section { FolioMessage(message: error) } }
    }
    .formStyle(.grouped).navigationTitle("받은 파일 추가")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(isAdding ? "추가 중…" : kind == .archive ? "가져오기" : kind == .document ? "문서 추가" : "첨부 추가") { add(to: target) }
          .disabled(isAdding || model.isImportingReceived || model.isBusy || (kind != .archive && target == nil))
      }
    }
    .disabled(isAdding || model.isImportingReceived)
    .modifier(WikiLibraryPresentation(model: model, window: window, isPresented: $showLibrary))
  }

  private var fileOptions: some View {
    Menu("파일 옵션", systemImage: "ellipsis") {
      ShareLink(item: FolioReceivedShare(owner: model.nearby, transferID: selection.receipt.transferID, file: file),
        preview: SharePreview(receipt.displayName)) { Label("원본 공유", systemImage: "square.and.arrow.up") }
      if receipt.state == .completed {
        let archived = model.nearby.archived.contains { $0.transferID == selection.receipt.transferID }
        Button(archived ? "받은 파일로 복원" : "보관") {
          Task { await model.nearby.moveReceived(selection.receipt.transferID, toArchive: !archived) }
        }.disabled(model.nearby.isWorking || model.isImportingReceived)
      }
    }.menuStyle(.borderlessButton).fixedSize()
  }

  private func add(to target: FolioReceivedTarget?) {
    guard !isAdding else { return }
    isAdding = true; error = nil
    Task {
      defer { isAdding = false }
      if kind != .archive, (target == nil || model.receivedFileTarget != target) { error = "자료함이 바뀌었습니다. 추가할 위치를 다시 확인하세요."; return }
      if await model.importReceived(file, receipt: receipt, target: target, in: window) { added() }
      else { error = model.message ?? "파일을 추가하지 못했습니다. 원본은 보관되어 있습니다." }
    }
  }
}
