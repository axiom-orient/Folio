#if os(macOS)
import FolioAgents
import SwiftUI
import UniformTypeIdentifiers

struct AgentPluginsView: View {
  let projectRoot: URL?
  @State private var model = AgentPluginsModel()
  @State private var choosingExecutable = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("플러그인과 마켓플레이스").font(.title2.bold())
        Text("호스트 CLI가 패키지 다운로드, 인증과 설정을 관리합니다.")
          .foregroundStyle(.secondary)
        settings
        commands
        result
        Link("공식 설치 문서", destination: documentation)
      }
      .padding(24)
      .frame(maxWidth: 850, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onChange(of: model.host, initial: true) { model.resetHost() }
    .fileImporter(isPresented: $choosingExecutable, allowedContentTypes: [.item]) { selection in
      if case .success(let selected) = selection { model.executable = selected }
    }
    .confirmationDialog(model.removalTitle,
      isPresented: Binding(get: { model.hasPendingRemoval }, set: { if !$0 { model.dismissRemoval() } }),
      titleVisibility: .visible) {
        if let pendingRemoval = model.pendingRemoval {
          Button("삭제", role: .destructive) { model.confirmRemoval(pendingRemoval) }
        }
        Button("취소", role: .cancel, action: model.dismissRemoval)
      } message: {
        Text(model.removalMessage)
      }
    .onDisappear(perform: model.endPresentation)
  }

  private var settings: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        Picker("호스트", selection: $model.host) {
          Text("Codex").tag(AgentHost.codex)
          Text("Claude").tag(AgentHost.claude)
        }
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("CLI 실행 파일").font(.headline)
            if let executable = model.executable {
              Text(executable.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
              Text("CLI가 없습니다. 설치한 실행 파일을 선택하세요.").foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button("선택…") { choosingExecutable = true }
        }
        if model.host == .claude {
          Picker("설치 범위", selection: $model.scope) {
            ForEach(AgentPluginScope.allCases) { scope in
              Text(scope.title).tag(scope)
            }
          }
          if model.scope != .user, projectRoot == nil {
            Text("스킬 탭에서 프로젝트 폴더를 선택하세요.").foregroundStyle(.secondary)
          }
        } else {
          Text("Codex CLI는 플러그인 작업에 설치 범위 옵션을 제공하지 않습니다.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(8)
      .disabled(model.state.isRunning)
    }
  }

  private var commands: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        Picker("작업", selection: $model.action) {
          ForEach(model.availableActions) { action in
            Text(action.title).tag(action)
          }
        }.disabled(model.state.isRunning)
        if model.action.needsInput {
          TextField(model.action.inputTitle, text: $model.input)
            .textFieldStyle(.roundedBorder)
            .disabled(model.state.isRunning)
          Text(model.action.hint).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          if model.state.isRunning {
            ProgressView().controlSize(.small)
            Text(model.state.isCancelling ? "중단 결과 확인 중…" : "CLI 실행 중…").foregroundStyle(.secondary)
            Spacer()
            Button("중단", action: model.cancel)
              .disabled(model.state.isCancelling)
          } else {
            Button(model.action.title, role: model.action.isRemoval ? .destructive : nil) {
              model.submit(projectRoot: projectRoot)
            }
              .disabled(!model.canSubmit(projectRoot: projectRoot))
          }
        }
      }
      .padding(8)
    }
  }

  @ViewBuilder private var result: some View {
    switch model.state {
    case .idle, .running, .cancelling: EmptyView()
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
    case .completed(let output):
      GroupBox("CLI 결과") {
        Text(output.isEmpty ? "완료했습니다." : output)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
      }
    }
  }

  private var documentation: URL {
    URL(string: model.host == .codex ? "https://developers.openai.com/plugins/build/plugins"
      : "https://code.claude.com/docs/en/discover-plugins")!
  }
}
#endif
