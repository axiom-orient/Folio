import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import SwiftUI

/// One reviewed statement and its original facets. A single Save uses the shared record submission lane.
struct FolioKnowledgeAssertionView: View {
  let model: WikiAppModel
  let focus: WikiKnowledgeEvidence
  let existing: WikiKnowledgeAssertionRecord?
  let review: WikiKnowledgeAssertionReview?
  private let generation: Int
  private let recordID: String
  @Environment(\.dismiss) private var dismiss
  @State private var statement: String
  @State private var conditions: [ConditionInput]
  @State private var value: String
  @State private var unit: String
  @State private var edition: String
  @State private var polarity: WikiKnowledgeAssertion.Polarity
  @State private var evidence: [WikiKnowledgeEvidence]
  @State private var selected: Set<String>
  @State private var roles: [String: WikiKnowledgeAssertionEvidence.Role]
  @State private var concepts: [WikiKnowledgeConceptRecord] = []
  @State private var selectedConcepts: Set<String>
  @State private var saving = false
  @State private var loadingContext = false
  @State private var message: String?
  @State private var task: Task<Void, Never>?
  @State private var findingEvidence = false

  private struct ConditionInput: Identifiable {
    let id = UUID()
    var text: String
  }

  init(model: WikiAppModel, focus: WikiKnowledgeEvidence, candidates: [WikiKnowledgeEvidence] = [],
    conceptID: String? = nil, existing: WikiKnowledgeAssertionRecord? = nil,
    review: WikiKnowledgeAssertionReview? = nil) {
    self.model = model; self.focus = focus; self.existing = existing; self.review = review
    generation = model.workspaceGeneration; recordID = existing?.assertion.id ?? UUID().uuidString.lowercased()
    let old = existing?.assertion
    _statement = State(initialValue: old?.statement.text ?? Self.initialStatement(focus.text))
    _conditions = State(initialValue: old?.conditions.map { ConditionInput(text: $0.text) } ?? [ConditionInput(text: "")])
    _value = State(initialValue: old?.value?.text ?? "")
    _unit = State(initialValue: old?.unit?.text ?? "")
    _edition = State(initialValue: old?.edition?.text ?? "")
    _polarity = State(initialValue: old?.polarity ?? .unspecified)
    var seen = Set<String>()
    let pool = old?.allEvidence ?? ([focus] + candidates.filter {
      $0.source.scopeID == focus.source.scopeID && $0.source.relativePath == focus.source.relativePath
        && $0.source.revision == focus.source.revision
    })
    _evidence = State(initialValue: pool.filter { seen.insert($0.id).inserted })
    _selected = State(initialValue: Set(old?.allEvidence.map(\.id) ?? [focus.id]))
    _roles = State(initialValue: Dictionary(uniqueKeysWithValues: old?.evidence.map { ($0.evidence.id, $0.role) }
      ?? [(focus.id, .support)]))
    _selectedConcepts = State(initialValue: Set(old?.conceptIDs ?? conceptID.map { [$0] } ?? []))
  }

  var body: some View {
    NavigationStack {
      Form {
        if let review, review.requiresConceptReview {
          Section("개념 연결 다시 확인") {
            Text("연결한 개념이 바뀌었습니다. 현재 내용을 확인한 뒤 저장하면 같은 주장의 연결을 갱신합니다.")
              .font(.callout)
            ForEach(review.conceptChanges) { change in
              VStack(alignment: .leading, spacing: 6) {
                Text(change.name).font(.headline)
                if change.state == .unavailable {
                  if selectedConcepts.contains(change.conceptID) {
                    Text("이 개념은 지금 사용할 수 없습니다. 연결을 해제하면 주장을 검토해 저장할 수 있습니다.")
                      .font(.callout).foregroundStyle(.secondary)
                    Button("연결 해제") { selectedConcepts.remove(change.conceptID) }
                  } else { Text("연결을 해제했습니다.").font(.callout).foregroundStyle(.secondary) }
                } else {
                  if let concept = change.currentConcept {
                    if !concept.domain.isEmpty { Text(concept.domain).font(.callout).foregroundStyle(.secondary) }
                    ForEach(concept.labels, id: \.language) { label in
                      Text(([label.preferred] + label.aliases).joined(separator: " · "))
                        .font(.callout).textSelection(.enabled)
                    }
                  }
                  Text("저장하면 선택한 현재 개념으로 다시 연결합니다.").font(.callout).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        Section("주장") {
          TextField("원문에서 확인한 내용", text: $statement, axis: .vertical)
            .lineLimit(3...8).accessibilityIdentifier("assertion-statement")
          if statementIsInterpretation {
            Label("직접 작성한 해석으로 기록합니다.", systemImage: "pencil").font(.callout).foregroundStyle(.secondary)
          }
        }
        DisclosureGroup("조건·값·단위·판본") {
          ForEach($conditions) { $condition in
            TextField("적용 조건", text: $condition.text, axis: .vertical).lineLimit(1...3)
          }
          if conditions.count < 32 {
            Button("조건 추가", systemImage: "plus") { conditions.append(ConditionInput(text: "")) }
          }
          TextField("원문 값", text: $value).accessibilityIdentifier("assertion-value")
          TextField("단위 · 대소문자 유지", text: $unit).accessibilityIdentifier("assertion-unit")
          TextField("원문에서 확인한 판본", text: $edition).accessibilityIdentifier("assertion-edition")
          Picker("표현 구분", selection: $polarity) {
            Text("원문대로").tag(WikiKnowledgeAssertion.Polarity.unspecified)
            Text("긍정 · 직접 지정").tag(WikiKnowledgeAssertion.Polarity.affirmed)
            Text("부정 · 직접 지정").tag(WikiKnowledgeAssertion.Polarity.negated)
          }
          Text("값·단위·판본은 원문 표현을 그대로 입력합니다. 원문과 다르게 작성한 조건은 해석으로 남깁니다.")
            .font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("개념 연결") {
          ForEach(concepts, id: \.concept.id) { record in
            Toggle(record.concept.labels[0].preferred + (record.concept.domain.isEmpty ? "" : " · " + record.concept.domain),
              isOn: membership(record.concept.id, in: $selectedConcepts))
          }
          if concepts.isEmpty { Text("개념을 먼저 만들 필요 없이 저장할 수 있습니다.").foregroundStyle(.secondary) }
        }
        Section("원문 근거") {
          ForEach(evidence) { item in
            DisclosureGroup(item.source.title + " · " + item.displayLocation) {
              Toggle("이 근거 사용", isOn: membership(item.id, in: $selected))
              if selected.contains(item.id) {
                Picker("역할", selection: role(item.id)) {
                  Text("지지").tag(WikiKnowledgeAssertionEvidence.Role.support)
                  Text("문맥").tag(WikiKnowledgeAssertionEvidence.Role.context)
                  Text("반박").tag(WikiKnowledgeAssertionEvidence.Role.refute)
                }
              }
              Text(verbatim: item.text).textSelection(.enabled)
            }
          }
          Button("주변 문맥 추가", systemImage: "text.alignleft", action: addContext)
            .disabled(loadingContext || saving)
          Button("원문의 다른 부분 찾기", systemImage: "magnifyingglass") { findingEvidence = true }
            .disabled(loadingContext || saving)
          if loadingContext { ProgressView("문맥 확인 중…") }
        }
        if saving { ProgressView("저장 중…") }
        if let message { Text(message).foregroundStyle(.secondary) }
      }
      .disabled(saving)
      .navigationTitle(existing == nil ? "주장 저장" : "주장 수정")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.disabled(saving) }
        ToolbarItem(placement: .confirmationAction) {
          Button("저장", action: save).disabled(saving || loadingContext || selected.isEmpty
            || statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isCurrent || hasUnavailableConcepts)
            .accessibilityIdentifier("assertion-save")
        }
      }
      .interactiveDismissDisabled(saving)
      .sheet(isPresented: $findingEvidence) {
        FolioKnowledgeQueryView(model: model, documentID: focus.source.documentID,
          selectionSource: focus.source, onSelectEvidence: { item in
            guard isCurrent, item.source == focus.source else { return }
            if !evidence.contains(where: { $0.id == item.id }) { evidence.append(item) }
            selected.insert(item.id)
          })
      }
      .task {
        guard let workspace = model.workspace else { return }
        do {
          let inventory = try await workspace.knowledgeConceptInventory()
          guard isCurrent, !Task.isCancelled else { return }
          concepts = inventory.records.filter { $0.concept.state == .accepted }
        } catch { if isCurrent { message = error.localizedDescription } }
      }
      .onDisappear { task?.cancel() }
      .onChange(of: model.workspaceGeneration) { _, _ in task?.cancel(); dismiss() }
    }.folioSheetSize(width: 640, height: 650)
  }

  private var isCurrent: Bool { model.hasOpenWorkspace && generation == model.workspaceGeneration }
  private var hasUnavailableConcepts: Bool {
    review?.conceptChanges.contains { $0.state == .unavailable && selectedConcepts.contains($0.conceptID) } == true
  }
  private var chosen: [WikiKnowledgeEvidence] { evidence.filter { selected.contains($0.id) } }
  private func membership(_ id: String, in selection: Binding<Set<String>>) -> Binding<Bool> {
    Binding(get: { selection.wrappedValue.contains(id) }, set: { included in
      if included { selection.wrappedValue.insert(id) } else { selection.wrappedValue.remove(id) }
    })
  }
  private func role(_ id: String) -> Binding<WikiKnowledgeAssertionEvidence.Role> {
    Binding(get: { roles[id] ?? .context }, set: { roles[id] = $0 })
  }
  private var statementIsInterpretation: Bool {
    (try? field(statement, label: "주장", interpretation: true,
      previous: existing?.assertion.statement, supportOnly: true))?.origin == .interpretation
  }
  private func field(_ raw: String, label: String, interpretation: Bool,
    previous: WikiKnowledgeAssertionText? = nil, supportOnly: Bool = false) throws -> WikiKnowledgeAssertionText? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if let previous, previous.text == text, previous.citations.allSatisfy({ selected.contains($0.evidenceID) }) { return previous }
    let matches = chosen.filter { (supportOnly ? (roles[$0.id] ?? .context) == .support : (roles[$0.id] ?? .context) != .refute)
      && Data($0.text.utf8).range(of: Data(text.utf8)) != nil }
    guard interpretation || !matches.isEmpty else { throw WikiError.invalidSource(label + "은 선택한 원문의 표현으로 입력해 주세요.") }
    let sources = matches.isEmpty ? chosen.filter { (roles[$0.id] ?? .context) != .refute } : matches
    return .init(text: text, citations: sources.map { .init(evidenceID: $0.id, quote: $0.text) },
      origin: matches.isEmpty ? .interpretation : .quoted)
  }
  private func save() {
    guard isCurrent, !saving else { return }
    do {
      let claim = try field(statement, label: "주장", interpretation: true, previous: existing?.assertion.statement, supportOnly: true)
      guard let claim else { return }
      let facets = try conditions.compactMap { input in
        try field(input.text, label: "조건", interpretation: true,
          previous: existing?.assertion.conditions.first { $0.text == input.text })
      }
      let assertion = WikiKnowledgeAssertion(id: recordID, statement: claim, polarity: polarity,
        conceptIDs: selectedConcepts.sorted(), conditions: facets,
        value: try field(value, label: "값", interpretation: false, previous: existing?.assertion.value),
        unit: try field(unit, label: "단위", interpretation: false, previous: existing?.assertion.unit),
        edition: try field(edition, label: "판본", interpretation: false, previous: existing?.assertion.edition),
        evidence: chosen.map { .init(evidence: $0, role: roles[$0.id] ?? .context) })
      var fields: [(String, WikiKnowledgeAssertionText?)] = [("주장", claim)]
      fields += facets.map { ("조건", $0) }
      fields += [("값", assertion.value), ("단위", assertion.unit), ("판본", assertion.edition)]
      for (label, field) in fields {
        guard let field else { continue }
        do { _ = try assertion.sourceEvidence(for: field) }
        catch { throw WikiError.invalidSource(label + ": " + error.localizedDescription) }
      }
      var revisions = Dictionary(uniqueKeysWithValues: concepts.map { ($0.concept.id, $0.revision) })
      if let review {
        // An asynchronous inventory refresh cannot approve a newer, unseen version
        // of a Concept already displayed in the review warning.
        for id in review.record.assertion.conceptIDs {
          revisions[id] = review.currentConceptRevisions[id]
        }
      }
      let expectedConcepts = revisions.filter { selectedConcepts.contains($0.key) }
      guard Set(expectedConcepts.keys) == selectedConcepts else {
        throw WikiError.unavailable("개념 정보를 확인한 뒤 저장해 주세요. 사용할 수 없는 연결은 해제할 수 있습니다.")
      }
      saving = true; message = nil
      task = Task { @MainActor in
        defer { saving = false; task = nil }
        let saved = await model.saveKnowledgeAssertion(assertion, existing: existing,
          expectedConceptRevisions: expectedConcepts)
        guard isCurrent, !Task.isCancelled else { return }
        if saved { dismiss() } else { message = model.message ?? "지금은 주장을 저장할 수 없습니다." }
      }
    } catch { message = error.localizedDescription }
  }
  private func addContext() {
    guard isCurrent, !loadingContext, let workspace = model.workspace else { return }
    loadingContext = true; message = nil
    task = Task { @MainActor in
      defer { loadingContext = false; task = nil }
      do {
        let context = try await workspace.knowledgeEvidenceContext(focus)
        guard isCurrent, !Task.isCancelled else { return }
        var seen = Set(evidence.map(\.id))
        evidence += context.evidence.filter { seen.insert($0.id).inserted }
        if !context.complete { message = context.diagnostics.joined(separator: "\n") }
      } catch { if isCurrent { message = error.localizedDescription } }
    }
  }
  private static func initialStatement(_ text: String) -> String {
    text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? text
  }
}
