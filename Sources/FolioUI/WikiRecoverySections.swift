import FolioKnowledge
import SwiftUI

/// Blocking recovery stays visible; one row opens one correction task.
struct WikiRecoverySections: View {
  let model: WikiAppModel
  let window: WikiWindowState
  let snapshot: WikiSnapshot
  @State private var legacySelection: LegacyDraftSelection?
  @State private var expanded = false

  private struct LegacyDraftSelection: Identifiable {
    let id: String
    let draft: FolioDraft
  }

  private var orphanedDraftIDs: [String] {
    let documents = Set(snapshot.documents.map(\.id))
    return model.drafts.keys.filter { model.drafts[$0]?.isDirty == true && !documents.contains($0) }.sorted()
  }

  var body: some View {
    let count = orphanedDraftIDs.count + model.legacyDrafts.values.filter(\.isDirty).count
      + model.pendingAttachments.count + snapshot.diagnostics.count
    if count > 0 {
      Section {
        DisclosureGroup(isExpanded: $expanded) { recoveryItems } label: {
          Label("복구·확인 \(count)개", systemImage: "exclamationmark.circle")
        }.accessibilityIdentifier("recovery-items")
      }
    }
  }

  @ViewBuilder private var recoveryItems: some View {
    let orphanedDraftIDs = self.orphanedDraftIDs
    let legacyDraftIDs = model.legacyDrafts.keys.filter { model.legacyDrafts[$0]?.isDirty == true }.sorted()
    if !legacyDraftIDs.isEmpty {
      Section("이전 편집 복사본") {
        ForEach(legacyDraftIDs, id: \.self) { id in
          if let draft = model.legacyDrafts[id] {
            Button { legacySelection = LegacyDraftSelection(id: id, draft: draft) } label: {
              recoveryLabel(draftTitle(draft), action: id.hasPrefix("accountless:") ? "계정 미확인 복사본" : "위치 미확인 복사본")
            }.help(draft.path)
          }
        }
      }
      .sheet(item: $legacySelection) { selection in
        WikiLegacyDraftView(draft: selection.draft)
      }
    }
    if !orphanedDraftIDs.isEmpty {
      Section("이어서 편집") {
        ForEach(orphanedDraftIDs, id: \.self) { id in
          Button { Task { await model.showDraftRecovery(id: id) } } label: {
            recoveryLabel(draftTitle(id), action: "열기")
          }.help(model.drafts[id]?.path ?? id)
        }
      }
    }
    if !model.pendingAttachments.isEmpty {
      Section("첨부 연결 확인") {
        ForEach(model.pendingAttachments) { record in
          Button { Task { await model.linkAttachment(record, in: window) } } label: {
            recoveryLabel(record.filename, action: "연결 복구")
          }
        }
      }
    }
    if !snapshot.diagnostics.isEmpty {
      Section("확인이 필요한 자료") {
        ForEach(snapshot.diagnostics, id: \.self) { diagnostic in
          let action = recoveryAction(for: diagnostic)
          Button { Task { await action.perform() } } label: {
            recoveryLabel(snapshot.documents.first { $0.relativePath == diagnostic.path }?.title
              ?? recoveryFilename(diagnostic.path), action: action.title)
          }.help(diagnostic.path).accessibilityValue(diagnostic.path)
        }
      }
    }
  }

  private func recoveryLabel(_ title: String, action: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.body).fixedSize(horizontal: false, vertical: true)
      Text(action).font(.caption).foregroundStyle(.secondary)
    }.lineLimit(nil).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
  }

  private func draftTitle(_ id: String) -> String {
    guard let draft = model.drafts[id] else { return "이어서 편집" }
    return draftTitle(draft)
  }

  private func draftTitle(_ draft: FolioDraft) -> String {
    return (try? WikiMarkdownParser.document(relativePath: draft.path, bytes: Data(draft.original.utf8)))?.title
      ?? "저장하지 않은 문서"
  }

  private func recoveryFilename(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    return UUID(uuidString: url.deletingPathExtension().lastPathComponent) == nil
      ? url.lastPathComponent : "확인할 문서"
  }

  private func recoveryAction(for diagnostic: WikiDiagnostic) -> (title: String, perform: @MainActor () async -> Void) {
    switch diagnostic.reason {
    case "source_conflict":
      ("변경 확인", { [model] in await model.showConflict(path: diagnostic.path) })
    case "download_pending":
      ("원문 다운로드", { [model] in await model.requestDownload(path: diagnostic.path) })
    default:
      ("원문 복구", { [model] in await model.showSourceRepair(path: diagnostic.path) })
    }
  }
}

/// An older UUID-only recovery file does not identify its source location.
/// This view only exposes a captured copy for the user to inspect or share.
private struct WikiLegacyDraftView: View {
  let draft: FolioDraft
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("이전 편집 복사본의 원래 자료함이나 iCloud 계정을 확인할 수 없습니다. 내용을 확인한 후 원하는 자료함에 직접 복사해 주세요. 복사본은 이 기기에 보관됩니다.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Text(draft.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
          Text(draft.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
      }
      .navigationTitle("이전 편집 복사본")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          ShareLink(item: draft.text) { Label("복사본 공유", systemImage: "square.and.arrow.up") }
        }
      }
    }.folioSheetSize(width: 600, height: 540)
  }
}
