import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import SwiftUI

/// Structured records are read directly. Only source opening and explicit editing create another sheet.
struct FolioKnowledgeAssertionsView: View {
  let model: WikiAppModel
  let documentID: String?
  let conceptID: String?
  private let generation: Int
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var records: [WikiKnowledgeAssertionRecord] = []
  @State private var complete = true
  @State private var message: String?
  @State private var loading = false
  @State private var sheet: Sheet?
  @State private var task: Task<Void, Never>?

  private enum Sheet: Identifiable {
    case source(FolioKnowledgeSourceSelection), edit(WikiKnowledgeAssertionReview)
    var id: String {
      switch self {
      case .source(let selection): selection.id.uuidString
      case .edit(let review): "edit:" + review.record.assertion.id
      }
    }
  }

  init(model: WikiAppModel, documentID: String? = nil, conceptID: String? = nil) {
    self.model = model; self.documentID = documentID; self.conceptID = conceptID
    generation = model.workspaceGeneration
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          if loading { ProgressView("주장 확인 중…") }
          if let message { Text(message).foregroundStyle(.secondary) }
          if !complete { Text("일부 주장만 확인했습니다. 검색어를 좁히거나 원문을 다시 확인해 주세요.").foregroundStyle(.secondary) }
          if !loading && records.isEmpty {
            ContentUnavailableView("저장한 주장이 없습니다", systemImage: "text.book.closed")
          }
          ForEach(records, id: \.assertion.id) { record in assertionRow(record) }
        }.frame(maxWidth: 660, alignment: .leading).padding(20).frame(maxWidth: .infinity)
      }
      .navigationTitle("저장한 주장")
      .searchable(text: $query, prompt: "주장·조건에서 찾기")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
      .task(id: query) { await load() }
      .onChange(of: model.workspaceGeneration) { _, _ in task?.cancel(); dismiss() }
      .onDisappear { task?.cancel() }
      .sheet(item: $sheet, onDismiss: { Task { await load() } }) { destination in
        switch destination {
        case .source(let selection):
          if isCurrent { FolioKnowledgeSourceView(selection: selection) }
          else { ContentUnavailableView("자료함을 다시 열어 주세요", systemImage: "doc.richtext") }
        case .edit(let review):
          if let focus = review.record.assertion.allEvidence.first, isCurrent {
            FolioKnowledgeAssertionView(model: model, focus: focus, existing: review.record, review: review)
          }
        }
      }
    }.folioSheetSize(width: 700, height: 650)
  }

  private var isCurrent: Bool { model.hasOpenWorkspace && model.workspaceGeneration == generation }
  private func assertionRow(_ record: WikiKnowledgeAssertionRecord) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        Text(verbatim: record.assertion.statement.text).font(.headline).textSelection(.enabled)
        Spacer(minLength: 8)
        Button { edit(record) } label: {
          Image(systemName: "pencil").frame(width: 44, height: 44).contentShape(.rect)
        }.accessibilityLabel("수정")
          .accessibilityIdentifier("assertion-edit-" + record.assertion.id)
      }
      if record.assertion.statement.origin == .interpretation {
        Label("작성한 해석", systemImage: "pencil").font(.caption).foregroundStyle(.secondary)
      }
      if record.assertion.polarity != .unspecified {
        Text(record.assertion.polarity == .negated ? "부정 · 직접 지정" : "긍정 · 직접 지정")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(Array(record.assertion.conditions.enumerated()), id: \.offset) { item in
        facet("조건", item.element, assertion: record.assertion)
      }
      if let value = record.assertion.value { facet("값", value, assertion: record.assertion) }
      if let unit = record.assertion.unit { facet("단위", unit, assertion: record.assertion) }
      if let edition = record.assertion.edition { facet("판본", edition, assertion: record.assertion) }
      if let source = try? record.assertion.sourceEvidence(for: record.assertion.statement).first {
        sourceButton(source)
      }
      DisclosureGroup("원문 근거") {
        ForEach(record.assertion.evidence, id: \.evidence.id) { item in
          VStack(alignment: .leading, spacing: 6) {
            Text(roleLabel(item.role)).font(.caption).foregroundStyle(.secondary)
            sourceButton(item.evidence)
            Text(verbatim: item.evidence.text).textSelection(.enabled)
          }.padding(.vertical, 6)
        }
      }.font(.callout)
      Divider()
    }
  }
  private func facet(_ label: String, _ field: WikiKnowledgeAssertionText, assertion: WikiKnowledgeAssertion) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: field.text).textSelection(.enabled)
        if field.origin == .interpretation {
          Label("작성한 해석", systemImage: "pencil").font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if let source = try? assertion.sourceEvidence(for: field).first {
        Button { open(source) } label: {
          Image(systemName: "arrow.up.right").frame(width: 44, height: 44).contentShape(.rect)
        }.accessibilityLabel(label + " 원문 열기")
      }
    }
  }
  private func sourceButton(_ evidence: WikiKnowledgeEvidence) -> some View {
    Button { open(evidence) } label: {
      Text(evidence.source.title + " · " + evidence.displayLocation)
        .frame(minHeight: 44).contentShape(.rect)
    }.font(.callout).accessibilityHint("원문 위치를 엽니다.")
  }
  private func roleLabel(_ role: WikiKnowledgeAssertionEvidence.Role) -> String {
    switch role { case .support: "지지 근거"; case .context: "주변 문맥"; case .refute: "반박 근거" }
  }
  private func edit(_ record: WikiKnowledgeAssertionRecord) {
    guard isCurrent, let workspace = model.workspace else { return }
    task?.cancel()
    task = Task { @MainActor in
      do {
        let review = try await workspace.reviewKnowledgeAssertion(id: record.assertion.id)
        guard isCurrent, !Task.isCancelled else { return }
        sheet = .edit(review)
      } catch {
        if isCurrent && !Task.isCancelled { message = folioAssertionReviewMessage(error) }
      }
    }
  }
  private func open(_ evidence: WikiKnowledgeEvidence) {
    guard isCurrent, let workspace = model.workspace else { return }
    task?.cancel()
    task = Task { @MainActor in
      do {
        let selection = try await FolioKnowledgeSourceSelection.load(evidence, in: workspace)
        guard isCurrent, !Task.isCancelled else { return }
        sheet = .source(selection)
      } catch { if isCurrent && !Task.isCancelled { message = "원문이나 연결한 개념이 바뀌었습니다. 다시 확인해 주세요." } }
    }
  }
  private func load() async {
    guard isCurrent, let workspace = model.workspace else { return }
    let submitted = query
    loading = true
    do {
      if !submitted.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
      let result = try await workspace.knowledgeAssertionInventory(conceptID: conceptID, documentID: documentID,
        query: submitted.isEmpty ? nil : submitted, limit: 100)
      guard isCurrent, !Task.isCancelled, query == submitted else { return }
      records = result.records; complete = result.complete
      message = result.diagnostics.isEmpty ? nil : result.diagnostics.joined(separator: "\n")
      loading = false
    } catch is CancellationError { }
    catch {
      guard isCurrent, query == submitted else { return }
      records = []; complete = false; message = error.localizedDescription; loading = false
    }
  }
}

func folioAssertionReviewMessage(_ error: any Error) -> String {
  if case WikiError.invalidSource(let reason) = error { return reason }
  return "주장이나 원문을 확인할 수 없습니다. 원문이 바뀌었다면 근거를 다시 찾은 뒤 저장해 주세요."
}
