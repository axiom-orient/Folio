#if os(macOS)
import SwiftUI
import FolioAgents
import UniformTypeIdentifiers

struct AgentSkillTargetView: View {
  private enum FolderPurpose { case home, project }
  @Bindable var model: AgentSkillsModel
  @State private var folderPurpose: FolderPurpose?

  var body: some View {
    Form {
      Picker("에이전트", selection: $model.host) {
        ForEach(AgentHost.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      if model.scope == .global {
        folderRow("홈 폴더", url: model.home, purpose: .home)
      }
      Picker("설치 범위", selection: $model.scope) {
        ForEach(SkillScope.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      if model.scope == .project {
        folderRow("프로젝트", url: model.project, purpose: .project)
      }
      if let directory = model.directory {
        LabeledContent("설치 폴더") {
          Text(directory.path).textSelection(.enabled).font(.callout.monospaced())
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped).lineLimit(nil)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
    .disabled(model.isBusy)
    .background {
      if let purpose = folderPurpose {
        WikiFilePicker(contentTypes: [.folder], cancellation: { folderPurpose = nil }) { result in
          folderPurpose = nil
          switch result {
          case .success(let urls):
            guard let url = urls.first else { return }
            switch purpose {
            case .home: model.chooseHome(url)
            case .project: model.project = url
            }
          case .failure(let error): model.reportPickerError(error)
          }
        }
      }
    }
  }

  private func folderRow(_ title: LocalizedStringKey, url: URL?, purpose: FolderPurpose) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
      Spacer()
      if let url {
        Text(url.path).foregroundStyle(.secondary).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("폴더 선택…") { folderPurpose = purpose }
    }
  }
}
#endif
