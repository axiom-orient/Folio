#if os(macOS)
import AppKit
import SwiftUI
import FolioAgents

struct AgentSkillListView: View {
  let skills: [InstalledSkill]
  let isBusy: Bool
  let needsProject: Bool
  let update: (InstalledSkill) -> Void
  let remove: (InstalledSkill) -> Void

  var body: some View {
    if skills.isEmpty && isBusy {
      ProgressView("설치 상태를 확인하는 중…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if skills.isEmpty {
      ContentUnavailableView {
        Label(needsProject ? "프로젝트 폴더를 선택하세요" : "설치된 스킬이 없습니다",
          systemImage: needsProject ? "folder" : "sparkles.rectangle.stack")
      } description: {
        Text(needsProject ? "프로젝트에서 사용할 스킬의 설치 위치를 선택하세요." :
          "로컬 폴더 또는 Git 저장소에서 스킬을 추가할 수 있습니다.")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(skills) { skill in
        AgentSkillRow(skill: skill, isBusy: isBusy,
          update: { update(skill) }, remove: { remove(skill) })
          .padding(.vertical, 5)
      }
      .listStyle(.inset)
    }
  }
}

private struct AgentSkillRow: View {
  let skill: InstalledSkill
  let isBusy: Bool
  let update: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(skill.name).font(.headline)
          if !skill.isManaged {
            Text("외부 설치").font(.caption).foregroundStyle(.secondary)
          }
          if skill.isSymbolicLink {
            Image(systemName: "link").foregroundStyle(.secondary)
              .accessibilityLabel("심볼릭 링크")
          }
        }
        if !skill.summary.isEmpty {
          Text(skill.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let source = skill.source {
          Text(sourceDescription(source)).font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if let revision = skill.revision {
          Text("리비전 \(revision)").font(.caption.monospaced()).foregroundStyle(.secondary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if let warning = skill.warning {
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading).lineLimit(nil)
      Menu {
        Button("Finder에서 보기", systemImage: "folder") {
          NSWorkspace.shared.activateFileViewerSelecting([skill.directory])
        }
        if skill.isManaged {
          Button(updateTitle, systemImage: "arrow.clockwise", action: update)
            .disabled(isBusy)
          Divider()
          Button("제거…", systemImage: "trash", role: .destructive, action: remove)
            .disabled(isBusy)
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton).fixedSize()
      .accessibilityLabel("\(skill.name) 작업")
    }
  }

  private var updateTitle: String {
    if case .local = skill.source { "원본 폴더를 선택하여 업데이트…" }
    else { "소스에서 업데이트" }
  }

  private func sourceDescription(_ source: SkillSource) -> String {
    switch source {
    case .local(let url): "로컬: \(url.path)"
    case .git(let repository, let reference, let subdirectory):
      "Git: \(repository) · \(reference)\(subdirectory.isEmpty ? "" : " · \(subdirectory)")"
    }
  }
}
#endif
