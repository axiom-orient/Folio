#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import FolioAgents

struct AgentSkillInstallView: View {
  private enum SourceKind: String, CaseIterable, Identifiable {
    case local, git
    var id: Self { self }
    var title: String { self == .local ? "로컬 폴더" : "Git 저장소" }
  }

  let install: (SkillSource) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var kind: SourceKind = .local
  @State private var localFolder: URL?
  @State private var repository = ""
  @State private var reference = "HEAD"
  @State private var subdirectory = ""
  @State private var selectsFolder = false
  @State private var pickerError: String?

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          Picker("소스", selection: $kind) {
            ForEach(SourceKind.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          if kind == .local { localSource } else { gitSource }
          if let pickerError { FolioMessage(message: pickerError) }
        } header: {
          Text("스킬 추가").font(.title2)
        } footer: {
          Text("SKILL.md가 있는 폴더를 설치합니다. 원본을 복사하며 설치 후에도 원본 폴더는 유지됩니다.")
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("설치") { if let source { install(source) } }
          .disabled(source == nil).keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 580, height: kind == .local ? 290 : 410)
    .background {
      if selectsFolder {
        WikiFilePicker(contentTypes: [.folder], cancellation: { selectsFolder = false }) { result in
          selectsFolder = false
          switch result {
          case .success(let urls): localFolder = urls.first; pickerError = nil
          case .failure(let error): pickerError = error.localizedDescription
          }
        }
      }
    }
  }

  private var localSource: some View {
    HStack(alignment: .firstTextBaseline) {
      if let localFolder {
        Text(localFolder.path).font(.callout).textSelection(.enabled)
          .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
      } else {
        Text("스킬 폴더를 선택하세요.").foregroundStyle(.secondary)
      }
      Spacer()
      Button("폴더 선택…") { selectsFolder = true }
    }
  }

  private var gitSource: some View {
    Group {
      TextField("저장소", text: $repository, prompt: Text("https://github.com/owner/repo.git"))
      TextField("브랜치·태그·커밋", text: $reference, prompt: Text("HEAD"))
      TextField("스킬 폴더", text: $subdirectory, prompt: Text("skills/my-skill (루트이면 비워 두세요)"))
      Text("비공개 저장소는 이 Mac에 설정한 Git 자격 증명과 SSH 구성을 사용합니다.")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  private var source: SkillSource? {
    switch kind {
    case .local: return localFolder.map(SkillSource.local)
    case .git:
      let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
      let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
      return repository.isEmpty ? nil :
        .git(repository: repository, reference: reference.isEmpty ? "HEAD" : reference,
          subdirectory: subdirectory.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}
#endif
