import SwiftUI
import FolioKnowledge
import FolioKnowledgeApple

/// Opt-in local discovery. Preview and approval retain the writer's exact plan;
/// recovery reads the durable proposal/operation binding, never reruns an edit.
struct FolioSemanticReviewView: View {
  let model: WikiAppModel
  let window: WikiWindowState
  let document: WikiDocument?
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var predicate = ""
  @State private var report: WikiSemanticSearchReport?
  @State private var proposals: [WikiRelationProposal] = []
  @State private var history: [WikiRelationProposalStatus] = []
  @State private var preview: Review?
  @State private var message: String?
  @State private var busy = false
  @State private var writing = false
  @State private var information = false
  @State private var showHistory = false
  @State private var technicalDetail: String?
  @State private var started = false
  @State private var task: Task<Void, Never>?
  @State private var resourceService: WikiSearchService?
  private struct Review: Identifiable {
    let id: String
    let plan: WikiPreparedEdit
    let source: String
    let target: String
    let sourceTitle: String
    let targetTitle: String
    let predicate: String
  }
  private var predicates: [String] {
    guard let type = document?.type else { return [] }
    return model.snapshot?.ontology?.relations.filter { $0.value.from.contains(type) }.keys.sorted() ?? []
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          if let document {
            if predicates.count > 1 {
              Picker("관계", selection: $predicate) {
                Text("관계 선택").tag("")
                ForEach(predicates, id: \.self) { Text(FolioRelationLabel.title($0)).tag($0) }
              }.accessibilityIdentifier("semantic-predicate").disabled(busy)
            }
            if predicates.isEmpty { Text("이 문서에 사용할 연결 규칙이 없습니다.").foregroundStyle(.secondary) }
            else {
              Button("다시 찾기", systemImage: "arrow.clockwise") { generate(document) }
                .accessibilityIdentifier("semantic-generate").disabled(predicate.isEmpty || busy)
            }
            ForEach(proposals) { proposal in
              VStack(alignment: .leading, spacing: 10) {
                Text(proposal.targetTitle).font(.headline)
                Text(FolioRelationLabel.title(proposal.predicate)).font(.caption).foregroundStyle(.secondary)
                HStack {
                  Button("검토") { prepare(proposal) }.accessibilityIdentifier("semantic-prepare-" + proposal.id)
                  Spacer()
                  Button("제외", role: .destructive) { reject(proposal) }
                }.disabled(busy)
              }.padding(.vertical, 4)
            }
            DisclosureGroup("이전 제안·작업 결과 확인", isExpanded: $showHistory) {
              ForEach(history, id: \.proposal.id) { item in
                VStack(alignment: .leading, spacing: 4) {
                  Text(item.proposal.targetTitle)
                  Text(statusText(item.state)).font(.callout).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
              }
            }.accessibilityIdentifier("semantic-history-toggle").onChange(of: showHistory) { _, value in if value { loadHistory(document.id) } }
          } else {
            if let report {
              if !report.indexComplete || !report.coverageComplete || report.relevanceComplete == false {
                Text("일부 내용만 확인했습니다. 기본 검색에서도 찾아보세요.").font(.callout).foregroundStyle(.secondary)
              }
              ForEach(report.matches) { match in
                Button {
                  run { service, generation in
                    await service.releaseSemanticResources()
                    guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
                    await model.openSemanticEvidence(match.reference, in: window)
                    guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
                    dismiss()
                  }
                } label: {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(match.title).font(.headline)
                    Text(FolioReadingExcerpt.semantic(match.excerpt)).lineLimit(3).foregroundStyle(.secondary)
                  }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(busy)
                  .accessibilityIdentifier("semantic-result-" + match.reference.documentID).padding(.vertical, 8)
              }
              if report.matches.isEmpty { Text("관련된 문서를 찾지 못했습니다.").foregroundStyle(.secondary) }
            }
          }
          if busy { ProgressView(writing ? "연결 저장 중…" : "찾는 중…") }
          if let message { Text(message).textSelection(.enabled).foregroundStyle(.secondary) }
        }.frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity).padding(24)
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        if document == nil {
          searchField.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8).background(.background)
        }
      }
      .navigationTitle(document == nil ? "뜻으로 찾기" : "연결 제안")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("닫기") { task?.cancel(); dismiss() }.disabled(writing) }
        ToolbarItem(placement: .primaryAction) {
          Button("정보", systemImage: "info.circle") { information = true }.labelStyle(.iconOnly)
        }
      }
      .interactiveDismissDisabled(writing)
      .onAppear {
        guard !started else { return }; started = true; query = window.query
        if let document, predicates.count == 1 { predicate = predicates[0]; generate(document) }
        else if document == nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search() }
      }
      .onChange(of: query) { _, _ in report = nil }
      .onChange(of: model.workspaceGeneration) { _, _ in
        task?.cancel(); releaseResources()
        preview = nil; proposals = []; history = []; report = nil
        message = "자료함이 바뀌었습니다. 다시 찾아주세요."
      }
      .onDisappear { task?.cancel(); releaseResources() }
      .sheet(isPresented: $information) { informationView }
      .sheet(item: $preview) { review in approvalView(review) }
    }
    #if os(macOS)
    .frame(width: 600, height: 600)
    #endif
  }

  private var searchField: some View {
    HStack {
      TextField("찾을 내용", text: $query).accessibilityIdentifier("semantic-query")
        .textFieldStyle(.roundedBorder).disabled(busy).onSubmit { search() }
      Button("찾기", systemImage: "magnifyingglass") { search() }.labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("semantic-search")
        .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private var informationView: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("한국어와 영어로 이 기기에서 찾습니다. 본문은 외부로 전송하지 않습니다. 후보가 누락되거나 무관한 내용이 나타날 수 있습니다. 연결은 두 문서의 근거를 확인하고 승인해야 추가됩니다.")
          if let report {
            Text("후보 \(report.matches.count)개 · 검사한 구간 \(report.indexedSections)개")
            ForEach(report.matches) { match in
              Text("\(match.title) · 유사도 \(match.similarity, format: .number.precision(.fractionLength(3)))")
                .font(.callout).textSelection(.enabled)
            }
          }
          if let technicalDetail { Text(technicalDetail).font(.caption.monospaced()).textSelection(.enabled) }
          ForEach(history, id: \.proposal.id) { item in
            VStack(alignment: .leading) {
              Text(item.proposal.targetTitle + " · " + statusText(item.state))
              if let operation = item.operationID { Text(operation.uuidString).font(.caption.monospaced()).textSelection(.enabled) }
            }
          }
        }.padding(24)
      }.navigationTitle("검색 정보")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { information = false } } }
    }.folioSheetSize(width: 540, height: 460)
  }

  private func approvalView(_ review: Review) -> some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 6) {
            Text(review.sourceTitle).font(.headline)
            Label(FolioRelationLabel.title(review.predicate), systemImage: "arrow.down").font(.callout).foregroundStyle(.secondary)
            Text(review.targetTitle).font(.headline)
          }
          Text("두 근거를 확인하고 연결을 승인하세요.").font(.callout).foregroundStyle(.secondary)
          if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
          Text("이 문서의 근거").font(.headline)
          WikiMarkdownReader(source: review.source, titleToOmit: review.sourceTitle).equatable().textSelection(.enabled)
          Text("연결할 문서의 근거").font(.headline)
          WikiMarkdownReader(source: review.target, titleToOmit: review.targetTitle).equatable().textSelection(.enabled)
          DisclosureGroup("원문 변경 상세") {
            VStack(alignment: .leading, spacing: 12) {
              Text("변경 전").font(.headline)
              Text(review.plan.before).font(.system(.body, design: .monospaced)).textSelection(.enabled)
              Text("변경 후").font(.headline)
              Text(review.plan.after).font(.system(.body, design: .monospaced)).textSelection(.enabled)
              Text(review.plan.operationID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
            }.padding(.top, 12)
          }.accessibilityIdentifier("semantic-exact-changes")
        }.frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity).padding(24)
      }.navigationTitle("연결 추가 승인")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("취소") { preview = nil }.disabled(writing) }
          ToolbarItem(placement: .confirmationAction) { Button("승인하고 연결 추가") { apply(review) }.accessibilityIdentifier("semantic-approve").disabled(busy) }
        }.interactiveDismissDisabled(writing)
    }.folioSheetSize(width: 620, height: 600)
  }

  private func run(_ action: @escaping @MainActor (WikiSearchService, Int) async throws -> Void) {
    guard !busy, let service = model.session.service else { return }
    resourceService = service
    busy = true; message = nil; technicalDetail = nil
    let generation = model.workspaceGeneration
    task = Task { @MainActor in
      defer { busy = false }
      do { try await action(service, generation) }
      catch { if generation == model.workspaceGeneration, !Task.isCancelled {
        technicalDetail = error.localizedDescription
        message = "작업을 마치지 못했습니다. 잠시 후 다시 시도해 주세요. 자세한 내용은 정보에서 확인할 수 있습니다."
      } }
    }
  }
  private func releaseResources() {
    let previous = resourceService; resourceService = nil
    if let previous { Task { await previous.releaseSemanticResources() } }
  }
  private func search() {
    let input = query; let filter = window.filter
    guard input.utf8.count <= 512 else {
      message = "찾을 내용을 조금 짧게 입력해 주세요."; return
    }
    run { service, generation in
      let value = try await service.semanticSearch(input, filter: filter)
      guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
      report = value
    }
  }
  private func generate(_ document: WikiDocument) {
    let selected = predicate
    run { service, generation in
      let value = try await service.suggestRelations(documentID: document.id, predicate: selected)
      guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
      proposals = value
      if value.isEmpty { message = "새로 연결할 문서를 찾지 못했습니다." }
    }
  }
  private func prepare(_ proposal: WikiRelationProposal) {
    run { service, generation in
      try checkDrafts()
      let text = try await service.workspace.read([proposal.source, proposal.target])
      let plan = try await service.workspace.prepareRelationProposal(id: proposal.id, operationID: UUID())
      guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
      await service.releaseSemanticResources()
      guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
      preview = Review(id: proposal.id, plan: plan, source: text[0], target: text[1],
        sourceTitle: document?.title ?? "이 문서", targetTitle: proposal.targetTitle, predicate: proposal.predicate)
    }
  }
  private func apply(_ review: Review) {
    run { service, generation in
      writing = true; defer { writing = false }
      try checkDrafts()
      do {
        _ = try await service.workspace.executeRelationProposal(id: review.id, plan: review.plan)
        guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
        preview = nil; proposals.removeAll { $0.id == review.id }; message = "연결을 저장했습니다."
        model.session.requestRefresh()
      } catch {
        let status = try? await service.workspace.relationProposalStatus(id: review.id)
        guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
        preview = nil
        message = status?.state == .accepted ? "원문 반영이 확인되었습니다. 다시 실행하지 않습니다."
          : "저장 결과를 확인해 주세요. 이전 제안·작업 결과에서 확인할 수 있습니다. 자동으로 다시 저장하지 않습니다."
        technicalDetail = "작업: \(review.plan.operationID). \(error.localizedDescription)"
      }
    }
  }
  private func reject(_ proposal: WikiRelationProposal) {
    run { service, generation in
      try await service.workspace.rejectRelationProposal(id: proposal.id)
      guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
      proposals.removeAll { $0.id == proposal.id }
    }
  }
  private func loadHistory(_ id: String) {
    run { service, generation in
      let value = try await service.workspace.relationProposalHistory(documentID: id)
      guard generation == model.workspaceGeneration, !Task.isCancelled else { return }
      history = value
    }
  }
  private func checkDrafts() throws {
    guard model.hasOpenWorkspace, !model.isBusy, model.savingDocuments.isEmpty,
      !model.drafts.values.contains(where: { $0.isDirty }) else {
      throw WikiError.unavailable("열린 문서의 편집과 저장을 마친 뒤 연결을 추가해 주세요.")
    }
  }
  private func statusText(_ state: WikiRelationProposalStatus.State) -> String {
    switch state {
    case .proposed: "검토 대기"
    case .prepared: "승인 계획 준비됨 · 아직 반영 확인 없음"
    case .rejected: "거절됨"
    case .stale: "원문 변경됨 · 새 제안 필요"
    case .uncertain: "결과 미확인 · 자동 재실행 금지"
    case .accepted: "원문 반영 확인됨"
    }
  }
}

