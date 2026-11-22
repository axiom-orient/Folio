import FolioNearbyTransport
import SwiftUI

/// Destination selection and inbox browsing remain projections of the app-owned session.
struct WikiNearbyView: View {
  let model: WikiAppModel
  let window: WikiWindowState
  var source: FolioSendSource? = nil
  var focusTransferID: UUID? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var selectedFile: WikiReceivedFile?
  @State private var preparation = FolioSendPreparation()
  @State private var preparationAttempt = 0
  @State private var checkingFiles = true
  private var transfer: FolioNearbyModel { model.nearby }
  private var focusedFile: WikiReceivedFile? {
    guard let focusTransferID, let receipt = (transfer.received + transfer.archived).first(where: { $0.transferID.rawValue == focusTransferID }),
      let file = receipt.savedFiles.first else { return nil }
    return WikiReceivedFile(receipt: receipt, file: file)
  }

  var body: some View {
    NavigationStack {
      Group {
        if let source { destinations(source) }
        else if let focusedFile { WikiReceivedFileView(model: model, window: window, selection: focusedFile) { dismiss() } }
        else { inbox }
      }
      .navigationTitle(source == nil ? "받은 파일" : "기기로 보내기")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
      .navigationDestination(item: $selectedFile) { selection in
        WikiReceivedFileView(model: model, window: window, selection: selection) {
          if selectedFile?.id == selection.id { dismiss() }
        }
      }
      .task(id: preparationAttempt) { await prepare() }
    }
    .onDisappear { preparation.discard() }
    .folioSheetSize(width: 500, height: 520)
  }

  private func destinations(_ source: FolioSendSource) -> some View {
    List {
      Section { FolioFileHeader(name: source.title).padding(.vertical, 8) }
      Section("받을 기기") {
        if preparation.isPreparing { ProgressView("보낼 파일 준비 중…") }
        if transfer.isRunning && transfer.snapshot?.discoveries.isEmpty == true {
          VStack(alignment: .leading, spacing: 8) {
            ProgressView("근처 기기 찾는 중…")
            Text("같은 Apple 계정의 다른 기기에서 Folio를 열어 주세요.").font(.callout).foregroundStyle(.secondary)
          }.padding(.vertical, 8)
        }
        ForEach(transfer.snapshot?.discoveries ?? []) { device in
          Button {
            if preparation.send(to: device, title: source.title, using: transfer) { dismiss() }
          } label: {
            Label(device.displayName, systemImage: "laptopcomputer.and.iphone")
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
          }.disabled(!transfer.canSend || preparation.file == nil)
        }
        if !transfer.isRunning && !transfer.isStarting {
          Button("연결 다시 준비") { preparationAttempt += 1 }.disabled(preparation.isPreparing)
        }
      }
      if let error = preparation.error {
        Section { FolioMessage(message: error); Button("파일 다시 준비") { preparationAttempt += 1 }.disabled(preparation.isPreparing) }
      }
      transferRecovery
      transferNotice
    }.listStyle(.inset)
  }

  private var inbox: some View {
    List {
      if checkingFiles || transfer.isStarting { ProgressView("수신 기록 확인 중…") }
      else if let focusTransferID, !transfer.pendingImports.contains(where: { $0.transferID.rawValue == focusTransferID }) {
        ContentUnavailableView("받은 파일을 찾지 못했습니다", systemImage: "doc.questionmark",
          description: Text("수신 기록과 파일을 확인해 주세요."))
      }
      if !checkingFiles, transfer.received.isEmpty && transfer.archived.isEmpty && transfer.pendingImports.isEmpty && focusTransferID == nil {
        if transfer.snapshot == nil {
          ContentUnavailableView("수신 기록 확인 필요", systemImage: "tray",
            description: Text("연결과 저장 상태를 다시 확인하세요."))
          Button("다시 확인") { preparationAttempt += 1 }
        } else {
          ContentUnavailableView("아직 받은 파일이 없습니다", systemImage: "tray",
            description: Text("다른 기기에서 보내면 여기에 나타납니다."))
        }
      }
      pendingImports
      if !transfer.received.isEmpty {
        Section("받은 파일") { ForEach(transfer.received, id: \.transferID) { receipt in fileRows(receipt) } }
      }
      if !transfer.archived.isEmpty {
        Section {
          DisclosureGroup("보관한 파일 · \(transfer.archived.count)") {
            ForEach(transfer.archived, id: \.transferID) { receipt in fileRows(receipt) }
          }
        }
      }
      transferRecovery
      transferNotice
    }.listStyle(.inset)
  }

  @ViewBuilder private var transferNotice: some View {
    if let message = transfer.message ?? transfer.connectionGuidance {
      Section { FolioMessage(message: message) }
    }
  }

  @ViewBuilder private var pendingImports: some View {
    if !transfer.pendingImports.isEmpty {
      Section("저장을 마칠 수신 파일") {
        Text("수신 원본을 보존했습니다. 다시 시도하면 같은 전송의 파일과 완료 기록을 확인하고 저장을 마무리합니다.")
          .font(.callout).foregroundStyle(.secondary)
        ForEach(transfer.pendingImports) { pending in
          VStack(alignment: .leading, spacing: 8) {
            switch pending.state {
            case .ready(let manifest):
              FolioFileHeader(name: manifest.displayName,
                detail: "\(manifest.files.count)개 파일 · " + ByteCountFormatter.string(fromByteCount: manifest.totalBytes, countStyle: .file))
              Text("보낸 기기: " + manifest.sender.displayName).font(.caption).foregroundStyle(.secondary)
              Button("저장 다시 시도") { Task { await transfer.retryStorage(pending.transferID) } }
                .disabled(transfer.isWorking || transfer.isStarting)
                .accessibilityIdentifier("nearby-pending-import-" + pending.transferID.description)
            case .needsReview(let diagnostic):
              Label("수신 복구 자료를 확인해 주세요", systemImage: "exclamationmark.triangle")
              Text("원본은 보존했으며 자동으로 다시 저장하지 않습니다.").font(.callout)
              DisclosureGroup("자세히") { Text(diagnostic).font(.caption).textSelection(.enabled) }
            }
          }.padding(.vertical, 6)
        }
      }
    }
  }

  @ViewBuilder private func fileRows(_ receipt: AcornryImportReceipt) -> some View {
    ForEach(receipt.savedFiles, id: \.relativePath) { file in
      Button { selectedFile = WikiReceivedFile(receipt: receipt, file: file) } label: {
        HStack(spacing: 12) {
          Image(systemName: "doc.text").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 4) {
            Text(receipt.displayName).fixedSize(horizontal: false, vertical: true)
            Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
          }
          Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
    }
    if receipt.state == .partial {
      FolioMessage(message: "파일 저장 확인이 필요합니다.")
      if transfer.canRetryStorage(receipt.transferID) {
        Button("저장 다시 시도") { Task { await transfer.retryStorage(receipt.transferID) } }
          .disabled(transfer.isWorking)
      } else {
        Text("다시 저장할 수신 원본을 확인할 수 없습니다. 기존 파일은 보존했습니다.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var transferRecovery: some View {
    if let operations = transfer.snapshot?.unknownOutgoingOperations, !operations.isEmpty {
      Section("전송 결과 확인") {
        Text("상대 기기의 저장 결과가 아직 확인되지 않았습니다.").font(.callout).foregroundStyle(.secondary)
        ForEach(operations) { operation in
          Menu(operation.recordedAt.formatted(date: .abbreviated, time: .shortened)) {
            ForEach(transfer.snapshot?.discoveries ?? []) { device in
              Button(device.displayName) { Task { await transfer.reconcile(operation, through: device) } }
            }
          }.disabled(transfer.isWorking || transfer.snapshot?.discoveries.isEmpty != false)
        }
      }
    }
  }

  private func prepare() async {
    checkingFiles = true
    await transfer.ready()
    checkingFiles = false
    guard let source, !Task.isCancelled else { return }
    await preparation.prepare(source, using: transfer)
  }
}
