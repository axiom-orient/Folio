import SwiftUI

struct WikiWorkspaceView: View {
  enum Action {
    case attachment, sendFile, sendArchive, ontology, refresh, rebuildSearch, publish
    #if os(iOS)
    case photo
    #endif
    #if os(macOS)
    case reveal, createFolder, connect
    #endif
  }
  let model: WikiAppModel
  var isAddingPhoto = false
  let action: (Action) -> Void

  var body: some View {
    List {
      Section("저장 위치") {
        Text(storageTitle)
        if model.isCloudWorkspace { WikiCloudStatusText(status: model.cloudStatus).font(.callout).foregroundStyle(.secondary) }
        if model.canPublishToCloud {
          actionRow("iCloud에서 함께 사용", icon: "icloud", action: .publish)
        }
      }
      Section("추가") {
        actionRow("파일 첨부…", icon: "paperclip", action: .attachment)
        #if os(iOS)
        actionRow("사진 추가", icon: "photo", action: .photo).disabled(isAddingPhoto)
        #endif
      }
      Section("공유") {
        if let archive = model.archiveShare {
          ShareLink(item: archive, preview: SharePreview(archive.title)) { FolioActionLabel(title: "자료함 내보내기", icon: "square.and.arrow.up") }
          actionRow("자료함을 기기로 보내기", icon: "laptopcomputer.and.iphone", action: .sendArchive)
            .disabled(model.nearby.isWorking)
        }
        actionRow("다른 파일 보내기…", icon: "doc", action: .sendFile).disabled(model.nearby.isWorking)
      }
      Section {
        DisclosureGroup("고급") {
          actionRow("연결 규칙", icon: "link", action: .ontology)
          Button("새로고침") { action(.refresh) }
          Button("검색 다시 준비") { action(.rebuildSearch) }
          if let diagnostic = model.session.systemIndexDiagnostic {
            DisclosureGroup("시스템 검색 진단") {
              Text("앱 안에서는 일반 검색을 사용할 수 있습니다.").font(.callout)
              Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
          #if os(macOS)
          Button("Finder에서 원문 폴더 보기") { action(.reveal) }
          Button("폴더에 새 자료함 만들기…") { action(.createFolder) }
          if model.canConnectProvider {
            actionRow("SEMI에 연결", icon: "point.3.connected.trianglepath.dotted", action: .connect)
            Text(model.connectionMessage).font(.callout).foregroundStyle(.secondary)
          }
          #endif
        }
      }
    }.listStyle(.inset).buttonStyle(.plain).navigationTitle(model.snapshot?.workspace.name ?? "자료함 설정")
  }

  private func actionRow(_ title: String, icon: String, action target: Action) -> some View {
    Button { action(target) } label: { FolioActionLabel(title: title, icon: icon) }
  }

  private var storageTitle: String {
    switch model.currentWorkspaceLocation {
    case .managedCloud?: "iCloud"
    case .externalMac?: "폴더"
    default: "이 기기"
    }
  }
}
