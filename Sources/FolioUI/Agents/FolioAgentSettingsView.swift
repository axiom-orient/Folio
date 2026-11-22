#if os(macOS)
import SwiftUI
import FolioAgents
import UniformTypeIdentifiers

public struct FolioAgentSettingsView: View {
  @State private var model = AgentSkillsModel()

  public init() {}

  public var body: some View {
    TabView {
      AgentSkillsView(model: model)
        .tabItem { Label("스킬", systemImage: "sparkles.rectangle.stack") }
      AgentPluginsView(projectRoot: model.project)
        .tabItem { Label("플러그인", systemImage: "puzzlepiece.extension") }
    }
    .frame(minWidth: 680, idealWidth: 780, minHeight: 560, idealHeight: 700)
  }
}

private struct AgentSkillsView: View {
  @Bindable var model: AgentSkillsModel
  @State private var showsInstaller = false
  @State private var removal: InstalledSkill?
  @State private var localUpdate: InstalledSkill?

  var body: some View {
    VStack(spacing: 0) {
      AgentSkillTargetView(model: model)
      Divider()
      AgentSkillListView(skills: model.skills, isBusy: model.isBusy,
        needsProject: !model.canLoad, update: beginUpdate,
        remove: { removal = $0 })
      Divider()
      footer
    }
    .task { model.refresh() }
    .onChange(of: model.target) { _, _ in model.refresh() }
    .sheet(isPresented: $showsInstaller) {
      AgentSkillInstallView { source in
        model.install(source)
        showsInstaller = false
      }
    }
    .background {
      if let skill = localUpdate {
        WikiFilePicker(contentTypes: [.folder], cancellation: { localUpdate = nil }) { result in
          localUpdate = nil
          switch result {
          case .success(let urls):
            if let url = urls.first { model.update(skill, authorizedSource: url) }
          case .failure(let error): model.reportPickerError(error)
          }
        }
      }
    }
    .confirmationDialog("스킬을 제거할까요?", isPresented: removalPresented,
      titleVisibility: .visible, presenting: removal) { skill in
      Button("\(skill.name) 제거", role: .destructive) { model.remove(skill) }
    } message: { skill in
      Text("\(skill.directory.path)\n이 폴더의 설치 사본을 제거합니다. 원본 소스는 유지됩니다.")
    }
  }

  private var removalPresented: Binding<Bool> {
    Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
  }

  private func beginUpdate(_ skill: InstalledSkill) {
    if case .local = skill.source { localUpdate = skill }
    else { model.update(skill) }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 10) {
      AgentSkillOperationStatus(state: model.state)
      HStack {
        Button("스킬 추가…", systemImage: "plus") { showsInstaller = true }
          .disabled(model.isBusy || !model.canLoad)
        Button("새로고침", systemImage: "arrow.clockwise", action: model.refresh)
          .disabled(model.isBusy || !model.canLoad)
        Spacer()
        if model.isBusy {
          Button("취소", action: model.cancel)
            .disabled(isCancelling)
        } else {
          Text("\(model.skills.count)개 스킬").font(.callout).foregroundStyle(.secondary)
        }
      }
    }
    .padding()
  }

  private var isCancelling: Bool {
    if case .cancelling = model.state { true } else { false }
  }
}

private struct AgentSkillOperationStatus: View {
  let state: AgentSkillsModel.State

  @ViewBuilder var body: some View {
    switch state {
    case .ready:
      EmptyView()
    case .running(let activity):
      HStack(spacing: 8) { ProgressView().controlSize(.small); Text(activity.title) }
        .font(.callout)
    case .cancelling:
      HStack(spacing: 8) { ProgressView().controlSize(.small); Text("취소 요청을 처리하는 중…") }
        .font(.callout)
    case .complete(let message):
      Label(message, systemImage: "checkmark.circle").font(.callout)
    case .cancelled(let message):
      Label(message, systemImage: "stop.circle").font(.callout)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
    }
  }
}
#endif
