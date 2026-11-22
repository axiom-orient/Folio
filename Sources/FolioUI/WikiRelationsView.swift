import FolioKnowledge
import SwiftUI

/// Optional relation sheet, including incoming edges and exact declaration evidence.
struct WikiRelationsView: View {
  let model: WikiAppModel
  @Bindable var window: WikiWindowState
  let document: WikiDocument
  @Environment(\.colorScheme) private var scheme
  @State private var showSuggestions = false
  @State private var observation: Observation?
  private struct Observation: Identifiable { let id = UUID(); let text: String; let path: String; let line: Int; let detail: FolioRelationDetail }
  private var relations: [WikiRelation] { model.snapshot?.relations(for: document.id) ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Button("연결 제안", systemImage: "sparkle.magnifyingglass") { showSuggestions = true }
        .accessibilityIdentifier("relation-suggestions")
        .sheet(isPresented: $showSuggestions) { FolioSemanticReviewView(model: model, window: window, document: document) }
      relationGroup("이 문서의 연결", items: relations.filter { $0.sourceID == document.id }, outgoing: true)
      relationGroup("이 문서를 참조", items: relations.filter { $0.sourceID != document.id }, outgoing: false)
      if relations.isEmpty { Text("아직 연결된 문서가 없습니다.").foregroundStyle(.secondary) }
    }
    .tint(FolioTheme.accent(scheme))
    .sheet(item: $observation) { evidence in
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("\(evidence.path) · \(evidence.line)줄").font(.callout).foregroundStyle(.secondary)
            Text(evidence.detail.status).font(.headline)
            Text("선택한 연결의 상태입니다. 원문을 변경하면 다시 확인해 주세요.").font(.caption).foregroundStyle(.secondary)
            Text(evidence.detail.explanation).font(.callout).foregroundStyle(.secondary)
            Text(evidence.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
          }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("연결 근거")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { observation = nil } } }
      }
      #if os(macOS)
      .frame(width: 480, height: 320)
      #endif
    }
  }

  @ViewBuilder private func relationGroup(_ title: String, items: [WikiRelation], outgoing: Bool) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.caption).foregroundStyle(FolioTheme.muted(scheme))
        ForEach(targets(in: items, outgoing: outgoing), id: \.self) { targetID in
          let declarations = items.filter { (outgoing ? $0.targetID : $0.sourceID) == targetID }
          let target = model.snapshot?.documents.first { $0.id == targetID }
          HStack(alignment: .center, spacing: 12) {
            Button {
              if target != nil { window.selectedDocumentID = targetID }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(target?.title ?? "확인할 문서").foregroundStyle(FolioTheme.accent(scheme))
                Text(Array(Set(declarations.map { FolioRelationLabel.title($0.predicate) })).sorted().joined(separator: " · "))
                  .font(.caption).foregroundStyle(FolioTheme.muted(scheme))
                if declarations.contains(where: { $0.status != .valid }) {
                  Label(declarations.contains(where: { $0.status == .invalid }) ? "관계 규칙 확인 필요" : "대상 확인 필요", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                }
              }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(target == nil)
            Group {
              if declarations.count == 1, let relation = declarations.first {
                Button("관계의 근거", systemImage: "text.quote") { loadObservation(relation) }
                  .buttonStyle(.plain)
              } else {
                Menu("관계의 근거", systemImage: "ellipsis") {
                  ForEach(Array(declarations.enumerated()), id: \.offset) { _, relation in
                    Button("\(relation.predicate) · \(relation.range.startLine)줄 원문") { loadObservation(relation) }
                  }
                }
              }
            }.menuStyle(.borderlessButton).labelStyle(.iconOnly).fixedSize()
              .accessibilityLabel("\(target?.title ?? "확인할 문서") 관계의 근거")
            #if os(macOS)
              .menuIndicator(.hidden)
            #else
              .frame(minWidth: 44, minHeight: 44)
            #endif
          }
        }
      }
    }
  }

  private func targets(in items: [WikiRelation], outgoing: Bool) -> [String] {
    var seen = Set<String>()
    return items.compactMap { relation in
      let id = outgoing ? relation.targetID : relation.sourceID
      return seen.insert(id).inserted ? id : nil
    }
  }

  private func loadObservation(_ relation: WikiRelation) {
    let generation = model.editorGeneration
    Task {
      do {
        let detail = FolioRelationDetail(relation: relation)
        let path = model.snapshot?.documents.first { $0.id == relation.sourceID }?.relativePath ?? ""
        let text = try await model.declarationText(relation)
        guard generation == model.editorGeneration, window.selectedDocumentID == document.id else { return }
        observation = Observation(text: text, path: path, line: relation.range.startLine, detail: detail)
      }
      catch {
        if generation == model.editorGeneration, window.selectedDocumentID == document.id { model.message = error.localizedDescription }
      }
    }
  }
}

enum FolioRelationLabel {
  static func title(_ predicate: String) -> String {
    predicate == "related" ? "관련 문서" : predicate
  }
}
