import Foundation
import FolioKnowledgeApple
import SwiftUI

/// A chosen quote and one explicit save; terminology management stays out of the main screen.
struct FolioKnowledgeConceptView: View {
  let model: WikiAppModel
  let evidence: WikiKnowledgeEvidence
  private let generation: Int
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var aliases = ""
  @State private var domain = ""
  @State private var saving = false
  @State private var message: String?
  @State private var task: Task<Void, Never>?
  @State private var records: [WikiKnowledgeConceptRecord] = []
  @State private var existingID: String?

  init(model: WikiAppModel, evidence: WikiKnowledgeEvidence, initialName: String) {
    self.model = model; self.evidence = evidence; generation = model.workspaceGeneration
    _name = State(initialValue: initialName.count <= 80 ? initialName : "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("용어", text: $name).accessibilityIdentifier("concept-name")
          TextField("다른 이름 · 쉼표로 구분", text: $aliases).accessibilityIdentifier("concept-aliases")
          if !matchingRecords.isEmpty {
            Picker("연결 대상", selection: $existingID) {
              Text("새 용어").tag(String?.none)
              ForEach(matchingRecords, id: \.concept.id) { record in
                Text(record.concept.labels[0].preferred + (record.concept.domain.isEmpty ? "" : " · " + record.concept.domain)
                  + (record.concept.mentions.first.map { " · " + $0.evidence.source.title } ?? ""))
                  .tag(Optional(record.concept.id))
              }
            }.accessibilityIdentifier("concept-target")
          }
          DisclosureGroup("구분") {
            TextField("분야 또는 구분 · 선택", text: $domain)
          }
        }
        Section("연결할 원문") {
          Text(evidence.source.title + " · " + evidence.displayLocation).font(.subheadline)
          Text(verbatim: evidence.text).textSelection(.enabled)
        }
        if saving { ProgressView("저장 중…") }
        if let message { Text(message).foregroundStyle(.secondary) }
      }
      .disabled(saving)
      .navigationTitle("용어 연결")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("닫기") { dismiss() }.disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("저장", action: save)
            .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !model.hasOpenWorkspace || generation != model.workspaceGeneration)
            .accessibilityIdentifier("concept-save")
        }
      }
      .interactiveDismissDisabled(saving)
      .onDisappear { task?.cancel() }
      .onChange(of: model.workspaceGeneration) { _, _ in task?.cancel(); dismiss() }
      .onChange(of: name) { _, _ in existingID = nil }
      .task {
        guard let workspace = model.workspace else { return }
        do {
          let inventory = try await workspace.knowledgeConceptInventory()
          guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
          records = inventory.records.filter { $0.concept.state == .accepted }
        } catch { message = "기존 용어를 확인하지 못했습니다. " + error.localizedDescription }
      }
    }.folioSheetSize(width: 540, height: 480)
  }

  private var matchingRecords: [WikiKnowledgeConceptRecord] {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    guard !key.isEmpty else { return [] }
    return records.filter { record in
      record.concept.labels.contains { label in
        ([label.preferred] + label.aliases).contains { $0.precomposedStringWithCanonicalMapping.lowercased() == key }
      }
    }
  }

  private func save() {
    guard !saving, generation == model.workspaceGeneration else { return }
    saving = true; message = nil
    let preferred = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var seen = Set([preferred])
    let alternatives = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
    task = Task { @MainActor in
      defer { saving = false; task = nil }
      let saved = await model.saveKnowledgeConcept(name: preferred, aliases: alternatives,
        domain: domain.trimmingCharacters(in: .whitespacesAndNewlines), evidence: evidence,
        existing: records.first { $0.concept.id == existingID })
      guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
      if saved { dismiss() }
      else { message = model.message ?? "지금은 용어를 저장할 수 없습니다." }
    }
  }
}
