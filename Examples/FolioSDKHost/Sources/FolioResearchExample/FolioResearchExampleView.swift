import Foundation
import Observation
import FolioCore
import FolioSDKUI
import SwiftUI

/// A reusable example host. It creates data only after an explicit user action.
@MainActor
public struct FolioResearchExampleView: View {
  @State private var model = ResearchHost()
  private let onUncheckpointedEdit: @MainActor (Bool) -> Void

  public init(onUncheckpointedEdit: @escaping @MainActor (Bool) -> Void = { _ in }) {
    self.onUncheckpointedEdit = onUncheckpointedEdit
  }

  public var body: some View {
    ResearchHostView(model: model, onUncheckpointedEdit: onUncheckpointedEdit)
  }
}

@MainActor
private struct ResearchHostView: View {
  let model: ResearchHost
  let onUncheckpointedEdit: @MainActor (Bool) -> Void

  var body: some View {
    Group {
      if let session = model.session {
        FolioLibraryView(session: session) { failed in
          model.hasUncheckpointedEdit = failed
          onUncheckpointedEdit(failed)
        }
          .toolbar {
            ToolbarItem {
              Button("자료함 닫기", systemImage: "xmark") {
                Task { await model.close() }
              }
              .disabled(session.isBusy || model.hasUncheckpointedEdit)
            }
          }
      } else {
        VStack(alignment: .leading, spacing: 20) {
          Image(systemName: "books.vertical").font(.largeTitle).foregroundStyle(.tint)
          Text("근거를 남기는 연구 자료함").font(.largeTitle.bold())
          Text("연구 기록, Swift SDK의 책임 분담, 팀 문서 운영을 담은 Markdown 문서 세 개를 읽고 편집합니다.")
            .foregroundStyle(.secondary)
          Text("자료함 만들기를 선택하면 이 예제 앱의 전용 저장 공간에 새 자료함을 만듭니다. 이전 자료함은 별도로 다시 열 수 있습니다.")
            .font(.callout)
          HStack {
            Button("연구 자료함 만들기", systemImage: "plus") {
              Task { await model.create() }
            }
            .buttonStyle(.borderedProminent)
            if model.canReopen {
              Button("이전 자료함 열기", systemImage: "folder") {
                Task { await model.reopen() }
              }
            }
            if model.isBusy { ProgressView().controlSize(.small) }
          }
          .disabled(model.isBusy)
        }
        .padding(36)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .leading)
      }
    }
    .alert("자료함을 열지 못했습니다", isPresented: Binding(
      get: { model.message != nil }, set: { if !$0 { model.message = nil } }
    )) {
      Button("확인", role: .cancel) { model.message = nil }
    } message: {
      Text(model.message ?? "")
    }
  }
}

/// Example-host policy, kept outside the SDK: sample creation, storage paths,
/// and remembering the last explicitly selected sample.
@MainActor @Observable
private final class ResearchHost {
  private(set) var session: FolioSession?
  private(set) var isBusy = false
  var hasUncheckpointedEdit = false
  var message: String?
  @ObservationIgnored private let defaults = UserDefaults(suiteName: "com.example.FolioSDKHost")
  private let lastLibraryKey = "lastResearchLibrary"

  var canReopen: Bool { defaults?.string(forKey: lastLibraryKey) != nil }

  func create() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      let base = try hostDirectory()
      let libraries = base.appendingPathComponent("Libraries", isDirectory: true)
      try FileManager.default.createDirectory(at: libraries, withIntermediateDirectories: true)
      let name = UUID().uuidString.lowercased()
      let root = libraries.appendingPathComponent(name, isDirectory: true)
      try FolioSession.createWorkspace(at: root, name: "근거를 남기는 연구 자료함")
      guard let resources = Bundle.module.url(forResource: "ResearchLibrary", withExtension: nil) else {
        throw HostError.resourcesUnavailable
      }
      let source = resources.appendingPathComponent("notes", isDirectory: true)
      let destination = root.appendingPathComponent("notes", isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
        // FileManager refuses a destination collision; resources are never
        // copied onto an existing user library or a bundled read-only source.
        try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
      }
      try await open(root)
      defaults?.set(name, forKey: lastLibraryKey)
    } catch { message = error.localizedDescription }
  }

  func reopen() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      guard let name = defaults?.string(forKey: lastLibraryKey),
        let id = UUID(uuidString: name), name == id.uuidString.lowercased() else {
        throw HostError.invalidSavedLocation
      }
      let root = try hostDirectory().appendingPathComponent("Libraries", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
      try await open(root)
    } catch { message = error.localizedDescription }
  }

  func close() async {
    guard !isBusy, !hasUncheckpointedEdit, let session else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await session.close()
      self.session = nil
    } catch { message = error.localizedDescription }
  }

  private func open(_ root: URL) async throws {
    let state = try hostDirectory().appendingPathComponent("State", isDirectory: true)
    let configuration = try FolioConfiguration(stateDirectory: state, namespace: "com.example.FolioSDKHost")
    let opened = FolioSession(configuration: configuration)
    try await opened.openWorkspace(at: root)
    session = opened
  }

  private func hostDirectory() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).appendingPathComponent("FolioSDKHost", isDirectory: true)
  }

  private enum HostError: LocalizedError {
    case resourcesUnavailable, invalidSavedLocation
    var errorDescription: String? {
      switch self {
      case .resourcesUnavailable: "예제 문서 리소스를 찾지 못했습니다."
      case .invalidSavedLocation: "이전 예제 자료함의 위치가 올바르지 않습니다."
      }
    }
  }
}
