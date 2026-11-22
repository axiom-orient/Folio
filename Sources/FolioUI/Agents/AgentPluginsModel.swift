#if os(macOS)
import Foundation
import Observation
import FolioAgents

/// Owns the captured CLI request and its lifetime; the host CLI owns installation effects.
@MainActor @Observable
final class AgentPluginsModel {
  enum State {
    case idle, running, cancelling, completed(String), failed(String)

    var isRunning: Bool {
      switch self { case .running, .cancelling: true; default: false }
    }
    var isCancelling: Bool { if case .cancelling = self { true } else { false } }
  }

  enum Action: String, CaseIterable, Identifiable {
    case plugins, install, remove, update, enable, disable
    case marketplaces, addMarketplace, refreshMarketplace, removeMarketplace

    var id: String { rawValue }
    var claudeOnly: Bool { self == .update || self == .enable || self == .disable }
    var isRemoval: Bool { self == .remove || self == .removeMarketplace }
    var needsInput: Bool { self != .plugins && self != .marketplaces }
    var title: String {
      switch self {
      case .plugins: "플러그인 목록"
      case .install: "플러그인 설치"
      case .remove: "플러그인 제거"
      case .update: "플러그인 업데이트"
      case .enable: "플러그인 활성화"
      case .disable: "플러그인 비활성화"
      case .marketplaces: "마켓플레이스 목록"
      case .addMarketplace: "마켓플레이스 추가"
      case .refreshMarketplace: "마켓플레이스 갱신"
      case .removeMarketplace: "마켓플레이스 제거"
      }
    }
    var inputTitle: String {
      switch self {
      case .addMarketplace: "저장소 주소 또는 로컬 경로"
      case .refreshMarketplace, .removeMarketplace: "마켓플레이스 이름"
      default: "플러그인 ID (name@marketplace)"
      }
    }
    var hint: String {
      switch self {
      case .addMarketplace: "owner/repo, HTTPS·SSH 저장소 주소 또는 로컬 경로. 프라이빗 저장소는 기존 Git 인증을 사용합니다."
      case .refreshMarketplace, .removeMarketplace: "마켓플레이스 목록에 표시된 이름을 입력하세요."
      default: "목록의 ID를 입력하세요. npm 등 패키지 소스는 호스트 CLI가 설치합니다."
      }
    }
    func operation(_ input: String) -> AgentPluginOperation {
      switch self {
      case .plugins: .listPlugins
      case .install: .install(input)
      case .remove: .remove(input)
      case .update: .update(input)
      case .enable: .enable(input)
      case .disable: .disable(input)
      case .marketplaces: .listMarketplaces
      case .addMarketplace: .addMarketplace(input)
      case .refreshMarketplace: .refreshMarketplace(input)
      case .removeMarketplace: .removeMarketplace(input)
      }
    }
  }

  struct Request {
    let id = UUID()
    let host: AgentHost
    let scope: AgentPluginScope
    let action: Action
    let input: String
    let executable: URL
    let projectRoot: URL?

    var operation: AgentPluginOperation { action.operation(input) }
  }

  private struct Job {
    let request: Request
    let task: Task<Void, Never>
  }

  var host: AgentHost = .codex
  var scope: AgentPluginScope = .user
  var action: Action = .plugins
  var input = ""
  var executable: URL?
  private(set) var state: State = .idle
  private(set) var pendingRemoval: Request?
  @ObservationIgnored private var job: Job?

  var availableActions: [Action] {
    Action.allCases.filter { host == .claude || !$0.claudeOnly }
  }
  var hasPendingRemoval: Bool { pendingRemoval != nil }
  var removalTitle: String { "\(pendingRemoval?.action.title ?? "삭제")을 진행할까요?" }
  var removalMessage: String {
    guard let pendingRemoval else { return "" }
    let target = pendingRemoval.input
    if pendingRemoval.host == .claude {
      return "\(target)을(를) \(pendingRemoval.scope.title) 범위에서 제거합니다. 마지막 마켓플레이스 선언을 제거하면 소속 플러그인도 제거되며, 마지막 설치 제거 시 저장한 설정·비밀값·데이터도 삭제될 수 있습니다."
    }
    return "\(target)을(를) Codex에서 제거합니다. CLI가 해당 설정과 설치 캐시를 정리합니다."
  }

  func resetHost() {
    scope = .user
    executable = AgentPlugins.executable(for: host)
    action = .plugins
    input = ""
    state = .idle
  }

  func canSubmit(projectRoot: URL?) -> Bool {
    executable != nil && (!action.needsInput || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      && (scope == .user || projectRoot != nil)
  }

  func submit(projectRoot: URL?) {
    guard let executable else { return }
    let request = Request(host: host, scope: scope, action: action,
      input: input.trimmingCharacters(in: .whitespacesAndNewlines), executable: executable, projectRoot: projectRoot)
    do {
      _ = try AgentPlugins.arguments(for: request.operation, host: request.host, scope: request.scope)
      if action.isRemoval { pendingRemoval = request } else { start(request) }
    } catch { state = .failed(error.localizedDescription) }
  }

  func confirmRemoval(_ request: Request) {
    start(request)
    pendingRemoval = nil
  }

  func dismissRemoval() { pendingRemoval = nil }

  func cancel() {
    state = .cancelling
    job?.task.cancel()
  }

  func endPresentation() { job?.task.cancel() }

  private func start(_ request: Request) {
    guard job == nil else { return }
    state = .running
    job = Job(request: request, task: Task { await perform(request) })
  }

  private func perform(_ request: Request) async {
    let accessing = request.executable.startAccessingSecurityScopedResource()
    let accessingProject = request.projectRoot?.startAccessingSecurityScopedResource() == true
    defer {
      if accessing { request.executable.stopAccessingSecurityScopedResource() }
      if accessingProject { request.projectRoot?.stopAccessingSecurityScopedResource() }
      job = nil
    }
    do {
      let result = try await AgentPlugins.execute(request.operation, host: request.host,
        executable: request.executable, projectRoot: request.projectRoot, scope: request.scope)
      guard !Task.isCancelled, job?.request.id == request.id else { return }
      state = .completed(result.output)
    } catch is CancellationError {
      if job?.request.id == request.id {
        state = request.operation.changesInstallation
          ? .failed("실행을 중단했습니다. 호스트에 반영된 변경이 있을 수 있으니 플러그인·마켓플레이스 목록을 다시 조회하세요.")
          : .idle
      }
    } catch {
      if job?.request.id == request.id { state = .failed(error.localizedDescription) }
    }
  }
}
#endif
