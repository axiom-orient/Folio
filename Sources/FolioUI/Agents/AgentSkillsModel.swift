#if os(macOS)
import Foundation
import Observation
import FolioAgents

/// This window owns one operation at a time; the store owns all filesystem effects.
@MainActor @Observable
final class AgentSkillsModel {
  enum Activity {
    case refresh, install, update(String), remove(String)

    var title: String {
      switch self {
      case .refresh: "스킬을 불러오는 중…"
      case .install: "스킬을 설치하는 중…"
      case .update(let name): "\(name) 업데이트 중…"
      case .remove(let name): "\(name) 제거 중…"
      }
    }
  }

  enum State {
    case ready
    case running(Activity)
    case cancelling(Activity)
    case complete(String)
    case cancelled(String)
    case failed(String)
  }

  private enum Operation {
    case refresh
    case install(SkillSource)
    case update(InstalledSkill, authorizedSource: URL?)
    case remove(InstalledSkill)

    var activity: Activity {
      switch self {
      case .refresh: .refresh
      case .install: .install
      case .update(let skill, _): .update(skill.name)
      case .remove(let skill): .remove(skill.name)
      }
    }
  }

  var host: AgentHost = .codex
  var scope: SkillScope = .global
  var project: URL?
  private(set) var home: URL
  private(set) var skills: [InstalledSkill] = []
  private(set) var state: State = .ready
  @ObservationIgnored private var store: SkillStore
  @ObservationIgnored private var task: Task<Void, Never>?

  init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.home = home
    store = SkillStore(home: home)
  }

  var target: SkillTarget { SkillTarget(host: host, scope: scope, project: project) }
  var isBusy: Bool {
    switch state {
    case .running, .cancelling: true
    case .ready, .complete, .cancelled, .failed: false
    }
  }
  var canLoad: Bool { scope == .global || project != nil }
  var directory: URL? { try? target.directory(home: home) }

  func chooseHome(_ url: URL) {
    guard !isBusy else { return }
    home = url
    store = SkillStore(home: url)
    refresh()
  }

  func refresh() { start(.refresh) }
  func install(_ source: SkillSource) { start(.install(source)) }
  func update(_ skill: InstalledSkill, authorizedSource: URL? = nil) {
    guard !isBusy, skill.isManaged else { return }
    if case .local(let expected) = skill.source, let authorizedSource,
      expected.standardizedFileURL.resolvingSymlinksInPath() !=
        authorizedSource.standardizedFileURL.resolvingSymlinksInPath() {
      state = .failed("설치할 때 사용한 원본 폴더를 선택해 주세요: \(expected.path)")
      return
    }
    start(.update(skill, authorizedSource: authorizedSource))
  }
  func remove(_ skill: InstalledSkill) {
    guard skill.isManaged else { return }
    start(.remove(skill))
  }

  func reportPickerError(_ error: any Error) {
    guard !isBusy else { return }
    state = .failed(error.localizedDescription)
  }

  func cancel() {
    guard task != nil, case .running(let activity) = state else { return }
    state = .cancelling(activity)
    task?.cancel()
  }

  private func start(_ operation: Operation) {
    guard task == nil else { return }
    guard canLoad else { skills = []; state = .ready; return }
    let destination = target
    if case .refresh = operation { skills = [] }
    state = .running(operation.activity)
    task = Task { [weak self] in
      guard let self else { return }
      await perform(operation, target: destination)
      task = nil
    }
  }

  private func perform(_ operation: Operation, target: SkillTarget) async {
    let folders = accessFolders(for: operation, target: target)
    let accesses = folders.filter { $0.startAccessingSecurityScopedResource() }
    defer { for url in accesses { url.stopAccessingSecurityScopedResource() } }

    do {
      try Task.checkCancellation()
      let message: String?
      switch operation {
      case .refresh:
        message = nil
      case .install(let source):
        let installed = try await store.install(source: source, target: target)
        message = "\(installed.name)을 설치했습니다."
      case .update(let skill, _):
        let installed = try await store.update(skill, target: target)
        message = "\(installed.name)을 업데이트했습니다."
      case .remove(let skill):
        try await store.remove(skill, target: target)
        message = "\(skill.name)을 제거했습니다."
      }
      skills = try await store.list(target)
      if Task.isCancelled {
        state = .cancelled("취소를 요청한 뒤 현재 설치 목록을 다시 불러왔습니다.")
      } else {
        state = message.map(State.complete) ?? .ready
      }
    } catch {
      // A cancellation can race a completed filesystem transaction. Reconcile
      // the captured target before making another operation available.
      if let current = try? await store.list(target) { skills = current }
      if error is CancellationError || Task.isCancelled {
        state = .cancelled("작업을 취소했습니다. 현재 설치 목록을 확인하세요.")
      } else {
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func accessFolders(for operation: Operation, target: SkillTarget) -> [URL] {
    var folders = target.scope == .global ? [home] : target.project.map { [$0] } ?? []
    if case .install(.local(let url)) = operation { folders.append(url) }
    if case .update(_, let authorizedSource) = operation, let authorizedSource {
      folders.append(authorizedSource)
    }
    return folders
  }
}
#endif
