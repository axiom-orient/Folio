import FolioKnowledge
import FolioKnowledgeApple
import FolioSemanticModels
import Foundation
import PDFKit
import SwiftUI

/// One sheet owns the request, its admitted evidence, and the lifetime of its PDF snapshots.
struct FolioKnowledgeQueryView: View {
  let model: WikiAppModel
  let window: WikiWindowState?
  let documentID: String?
  let selectionSource: WikiKnowledgeSource?
  let onSelectEvidence: ((WikiKnowledgeEvidence) -> Void)?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme
  @FocusState private var questionFocused: Bool
  @State private var question: String
  @State private var searchMode = SearchMode.keyword
  @State private var phase = Phase.ready
  @State private var answer: WikiKnowledgeAnswer?
  @State private var message: String?
  @State private var detail: String?
  @State private var writing = false
  @State private var session: Session?
  @State private var task: Task<Void, Never>?
  @State private var operation = UUID()
  @State private var sheet: Sheet?

  private enum Phase: Equatable {
    case ready, finding, opening, unavailable
    var isBusy: Bool { self == .finding || self == .opening }
  }
  private enum SearchMode: Hashable { case keyword, meaning }
  private struct Session {
    let service: WikiSearchService
    let generation: Int
    let root: URL
  }
  private enum Sheet: Identifiable {
    case information, source(FolioKnowledgeSourceSelection), concept(WikiKnowledgeEvidence)
    case assertion(WikiKnowledgeEvidence), assertions(documentID: String?, conceptID: String?)
    var id: String {
      switch self {
      case .information: "information"
      case .source(let source): source.id.uuidString
      case .concept(let evidence): "concept:" + evidence.id
      case .assertion(let evidence): "assertion:" + evidence.id
      case .assertions(let documentID, let conceptID): "assertions:" + (documentID ?? "all") + (conceptID ?? "")
      }
    }
  }

  init(model: WikiAppModel, window: WikiWindowState? = nil, documentID: String? = nil, initialQuestion: String = "",
    selectionSource: WikiKnowledgeSource? = nil, onSelectEvidence: ((WikiKnowledgeEvidence) -> Void)? = nil) {
    self.model = model
    self.window = window
    self.documentID = documentID
    self.selectionSource = selectionSource; self.onSelectEvidence = onSelectEvidence
    _question = State(initialValue: initialQuestion)
  }

  private var canFind: Bool {
    phase == .ready && !writing && session.map(workspaceIsCurrent) == true
      && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  private var scopeTitle: String? {
    guard session.map(workspaceIsCurrent) == true, let snapshot = model.snapshot else { return nil }
    if let documentID { return snapshot.documents.first { $0.id == documentID }?.title ?? "선택한 자료" }
    return "\(snapshot.workspace.name) 전체"
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if phase.isBusy || writing {
            ProgressView(writing ? "노트 저장 중…" : phase == .opening ? "원문 여는 중…" : "자료 찾는 중…")
              .padding(.vertical, 12).accessibilityIdentifier("knowledge-progress")
          }
          if let message { Text(message).padding(.vertical, 12).textSelection(.enabled) }
          if let answer, session.map(workspaceIsCurrent) == true { results(answer) }
        }
        .frame(maxWidth: 656, alignment: .leading).padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
      }
      .background(FolioTheme.paper(scheme)).tint(FolioTheme.accent(scheme))
      .safeAreaInset(edge: .top, spacing: 0) { questionField }
      .navigationTitle(onSelectEvidence == nil ? "근거 찾기" : "근거 추가")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("닫기") { task?.cancel(); dismiss() }.disabled(writing)
        }
        ToolbarItem(placement: .primaryAction) {
          Menu("검색 옵션", systemImage: "ellipsis") {
            Button("저장한 주장", systemImage: "text.book.closed") {
              sheet = .assertions(documentID: documentID, conceptID: nil)
            }.accessibilityIdentifier("knowledge-saved-assertions")
            Button("검색 정보", systemImage: "info.circle") { sheet = .information }
          }.labelStyle(.iconOnly).accessibilityIdentifier("knowledge-options")
        }
      }
      .interactiveDismissDisabled(writing)
      .task { bindSession() }
      .onChange(of: question) { _, _ in clearResult() }
      .onChange(of: searchMode) { _, _ in clearResult() }
      .onChange(of: model.workspaceGeneration) { _, _ in invalidate() }
      .onChange(of: model.openedSourceRoot) { _, _ in invalidate() }
      .onChange(of: model.hasOpenWorkspace) { _, open in if !open { invalidate() } }
      .onDisappear { task?.cancel(); releaseResources() }
      .sheet(item: $sheet) { destination in
        switch destination {
        case .information: informationView
        case .concept(let evidence):
          FolioKnowledgeConceptView(model: model, evidence: evidence, initialName: question)
        case .assertion(let evidence):
          FolioKnowledgeAssertionView(model: model, focus: evidence, candidates: answer?.evidence ?? [evidence],
            conceptID: answer?.concepts?.selectedConceptID)
        case .assertions(let documentID, let conceptID):
          FolioKnowledgeAssertionsView(model: model, documentID: documentID, conceptID: conceptID)
        case .source(let selection):
          if let session, workspaceIsCurrent(session) {
            FolioKnowledgeSourceView(selection: selection)
          } else {
            ContentUnavailableView("자료함을 다시 열어 주세요", systemImage: "doc.richtext")
          }
        }
      }
    }
    .folioSheetSize(width: 700, height: 680)
  }

  private var questionField: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let scopeTitle {
        Label(scopeTitle, systemImage: documentID == nil ? "books.vertical" : "doc.text")
          .font(.subheadline).foregroundStyle(.secondary)
      }
      TextField("어떤 근거를 찾으세요?", text: $question, axis: .vertical)
        .focused($questionFocused).lineLimit(1...4).textFieldStyle(.roundedBorder)
        .onSubmit(find).accessibilityIdentifier("knowledge-question")
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { modePicker; findButton }
        VStack(alignment: .trailing, spacing: 8) { modePicker; findButton }
      }
    }
    .disabled(phase.isBusy || writing || phase == .unavailable)
    .frame(maxWidth: 656).padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity)
    .background(FolioTheme.paper(scheme)).overlay(alignment: .bottom) { Divider() }
  }

  private var modePicker: some View {
    Picker("검색 방식", selection: $searchMode) {
      Text("키워드").tag(SearchMode.keyword)
      Text("뜻").accessibilityLabel("뜻으로 찾기").tag(SearchMode.meaning)
    }.pickerStyle(.segmented).labelsHidden()
  }

  private var findButton: some View {
    Button("찾기", action: find)
      .buttonStyle(.borderedProminent).disabled(!canFind).accessibilityIdentifier("knowledge-find")
      .frame(minHeight: 44)
  }

  @ViewBuilder private func results(_ answer: WikiKnowledgeAnswer) -> some View {
    let coverage = answer.coverage
    if let concepts = answer.concepts, concepts.isAmbiguous {
      VStack(alignment: .leading, spacing: 8) {
        Text("어떤 뜻으로 찾으세요?").font(.subheadline)
        ForEach(concepts.choices) { choice in
          Button {
            find(conceptID: choice.id)
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(choice.name + (choice.domain.isEmpty ? "" : " · " + choice.domain))
              if !choice.sourceTitle.isEmpty { Text(choice.sourceTitle).font(.caption).foregroundStyle(.secondary) }
            }
          }.buttonStyle(.bordered)
        }
      }.padding(.vertical, 12)
    }
    if !coverage.complete || (answer.semanticUsed && !coverage.semanticComplete) {
      Label(coverage.unreadablePages > 0 ? "읽지 못한 PDF 페이지가 있습니다." : "일부 자료만 확인했습니다.",
        systemImage: "exclamationmark.circle")
        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
    }
    let visible = answer.evidence.filter { selectionSource == nil || $0.source == selectionSource }
    if visible.isEmpty {
      ContentUnavailableView("관련 근거를 찾지 못했습니다", systemImage: "text.magnifyingglass",
        description: Text("다른 표현이나 검색 방식으로 찾아보세요."))
    } else {
      if onSelectEvidence == nil {
        ViewThatFits(in: .horizontal) {
          HStack { resultCount(answer); Spacer(); saveButton(answer) }
          VStack(alignment: .leading, spacing: 6) { resultCount(answer); saveButton(answer) }
        }.padding(.vertical, 10)
      }
      Divider()
      ForEach(visible) { evidence in evidenceRow(evidence) }
    }
  }

  private func resultCount(_ answer: WikiKnowledgeAnswer) -> some View {
    Text("근거 \(answer.evidence.count)개").font(.subheadline).foregroundStyle(.secondary)
  }

  private func saveButton(_ answer: WikiKnowledgeAnswer) -> some View {
    Button("노트로 저장", systemImage: "square.and.pencil") { save(answer) }
      .disabled(phase.isBusy || writing || model.isBusy)
      .accessibilityIdentifier("knowledge-save")
  }

  private func evidenceRow(_ evidence: WikiKnowledgeEvidence) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Button { open(evidence) } label: {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(evidence.source.title + " · " + evidence.displayLocation).fontWeight(.semibold)
              .multilineTextAlignment(.leading)
            Image(systemName: "arrow.up.right").font(.caption)
          }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
        }
        .font(.callout).disabled(phase.isBusy || writing)
        .accessibilityHint("원문 위치를 엽니다.")
        .accessibilityIdentifier("knowledge-source-" + evidence.id)
        if let onSelectEvidence {
          Button { onSelectEvidence(evidence); dismiss() } label: {
            Label("추가", systemImage: "plus").frame(minWidth: 44, minHeight: 44).contentShape(.rect)
          }
            .disabled(phase.isBusy || writing).accessibilityIdentifier("knowledge-select-" + evidence.id)
        } else { Menu {
          Button("주장 저장", systemImage: "text.quote") { sheet = .assertion(evidence) }
          Button("저장한 주장", systemImage: "text.book.closed") {
            sheet = .assertions(documentID: evidence.source.documentID, conceptID: answer?.concepts?.selectedConceptID)
          }
          Button("용어 연결", systemImage: "link") { sheet = .concept(evidence) }
        } label: {
          Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("근거 추가 작업")
        .accessibilityIdentifier("knowledge-evidence-options-" + evidence.id)
        .disabled(phase.isBusy || writing)
        }
      }
      Text(verbatim: evidence.text).font(.body).lineSpacing(4)
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16).padding(.top, 6)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var informationView: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("결과는 저장한 원문에서 가져온 인용입니다. 출처를 열어 문맥을 확인할 수 있습니다.")
          Text("키워드는 입력한 단어를, 뜻은 비슷한 한국어·영어 표현을 찾습니다.")
          Text("‘스캔 인식’은 이미지에서 읽은 글자입니다. 수치와 수식 기호는 원문에서 확인할 수 있습니다.")
          if let answer {
            let coverage = answer.coverage
            Text("자료 \(coverage.sourceCount)개 · 구간 \(coverage.blockCount)개")
            if !coverage.diagnostics.isEmpty {
              DisclosureGroup("확인하지 못한 자료") {
                ForEach(Array(coverage.diagnostics.enumerated()), id: \.offset) { item in
                  Text(item.element).font(.callout).textSelection(.enabled).padding(.vertical, 4)
                }
              }
            }
            if let concepts = answer.concepts, !concepts.complete {
              Text("일부 용어 연결을 확인하지 못했습니다. 원문 검색 결과는 유지됩니다.")
              ForEach(Array(concepts.diagnostics.enumerated()), id: \.offset) { item in
                Text(item.element).font(.callout).textSelection(.enabled)
              }
            }
          }
          if let detail { Text(detail).font(.caption.monospaced()).textSelection(.enabled) }
        }.padding(24)
      }
      .navigationTitle("자료 검색 정보")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { sheet = nil } } }
    }.folioSheetSize(width: 540, height: 420)
  }

  private func isCurrent(_ captured: Session) -> Bool {
    !Task.isCancelled && workspaceIsCurrent(captured)
  }

  private func workspaceIsCurrent(_ captured: Session) -> Bool {
    model.hasOpenWorkspace && model.workspaceGeneration == captured.generation
      && model.openedSourceRoot == captured.root
  }

  private func bindSession() {
    guard session == nil, phase == .ready else { return }
    guard let service = model.session.service, let root = model.openedSourceRoot,
      model.hasOpenWorkspace else { invalidate(); return }
    session = Session(service: service, generation: model.workspaceGeneration, root: root)
  }

  private func find() { find(conceptID: nil) }

  private func find(conceptID: String?) {
    guard canFind else { return }
    let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
    let useSemantic = searchMode == .meaning
    questionFocused = false
    clearResult()
    run(.finding) { captured in
      let result = try await captured.service.knowledgeAnswer(submitted, documentID: documentID,
        useSemantic: useSemantic, conceptID: conceptID)
      guard isCurrent(captured) else { return }
      answer = result
    }
  }

  private func open(_ evidence: WikiKnowledgeEvidence) {
    run(.opening) { captured in
      let selection = try await FolioKnowledgeSourceSelection.load(evidence, in: captured.service.workspace)
      guard isCurrent(captured) else { return }
      sheet = .source(selection)
    }
  }

  private func run(_ next: Phase, action: @escaping @MainActor (Session) async throws -> Void) {
    guard !phase.isBusy, !writing, let captured = session, isCurrent(captured) else { return }
    let intent = UUID()
    operation = intent; phase = next; message = nil; detail = nil
    task = Task { @MainActor in
      do { try await action(captured) }
      catch {
        guard operation == intent, isCurrent(captured) else { return }
        switch error {
        case WikiError.changedSource:
          answer = nil
          message = "원문이 바뀌었습니다. 다시 찾아 주세요."
        case WikiError.invalidSource(let reason) where next == .finding,
          WikiError.unavailable(let reason) where next == .finding:
          message = reason
        case WikiSemanticEmbeddingError.tokenBudget:
          message = error.localizedDescription
        case SemanticResourceError.systemPressure:
          message = "기기의 메모리 부담이 줄어든 뒤 다시 시도하거나 키워드로 찾아 주세요."
        default:
          message = "자료를 확인하지 못했습니다. 다시 찾아 주세요."
        }
        detail = String(describing: error)
      }
      guard operation == intent, isCurrent(captured) else { return }
      phase = .ready; task = nil
    }
  }

  private func save(_ answer: WikiKnowledgeAnswer) {
    guard let window, !phase.isBusy, !writing, !model.isBusy, let captured = session, isCurrent(captured) else { return }
    writing = true; message = nil
    task = Task { @MainActor in
      defer { writing = false }
      let saved = await model.saveKnowledgeAnswer(answer, in: window)
      guard isCurrent(captured) else { return }
      if saved { dismiss() }
      else { message = model.message ?? "지금은 노트를 저장할 수 없습니다. 잠시 후 다시 시도해 주세요." }
      task = nil
    }
  }

  private func invalidate() {
    task?.cancel(); task = nil; operation = UUID(); releaseResources()
    answer = nil; sheet = nil; session = nil
    phase = .unavailable; message = "자료함이 닫혔거나 바뀌었습니다. 다시 열어 주세요."; detail = nil
  }

  private func clearResult() {
    answer = nil; message = nil; detail = nil
  }

  private func releaseResources() {
    guard let service = session?.service else { return }
    Task { await service.releaseKnowledgeResources() }
  }
}

/// Quotations, concepts and assertions open the same admitted in-memory source snapshot.
struct FolioKnowledgeSourceSelection: Identifiable {
  enum Content {
    case pdf(WikiKnowledgePDFPreview)
    case markdown(WikiDocument, sectionID: String, location: String)
  }
  let id = UUID()
  let title: String
  let content: Content

  static func load(_ evidence: WikiKnowledgeEvidence, in workspace: WikiWorkspace) async throws -> Self {
    let content: Content
    if evidence.source.kind == .pdf { content = .pdf(try await workspace.previewKnowledgePDF(evidence)) }
    else if let reference = evidence.markdownReference {
      content = .markdown(try await workspace.previewKnowledgeMarkdown(evidence),
        sectionID: reference.sectionID, location: evidence.displayLocation)
    } else { throw WikiError.changedSource }
    return .init(title: evidence.source.title, content: content)
  }
}

struct FolioKnowledgeSourceView: View {
  let selection: FolioKnowledgeSourceSelection
  var body: some View {
    switch selection.content {
    case .pdf(let preview): FolioKnowledgePDFView(preview: preview, title: selection.title)
    case .markdown(let document, let sectionID, let location):
      FolioKnowledgeMarkdownView(document: document, sectionID: sectionID, location: location)
    }
  }
}

/// An admitted Markdown snapshot is read in place over the query or saved note.
struct FolioKnowledgeMarkdownView: View {
  let document: WikiDocument
  let location: String
  @State private var anchor: String?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme

  init(document: WikiDocument, sectionID: String, location: String) {
    self.document = document
    self.location = location
    _anchor = State(initialValue: sectionID)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 22) {
          let titleSectionID = document.sections.first { $0.headingPath == [document.title] }?.id
          Text(document.title).font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
          ForEach(document.sections) { section in
            let source = section.range.startLine == 1 ? FolioEditorContent(source: section.sourceText).body : section.sourceText
            WikiMarkdownReader(source: source, titleToOmit: section.id == titleSectionID ? document.title : nil)
              .lineSpacing(5).id(section.id)
          }
        }.scrollTargetLayout().frame(maxWidth: 660, alignment: .leading)
          .padding(20).frame(maxWidth: .infinity)
      }
      .scrollPosition(id: $anchor, anchor: .top)
      .background(FolioTheme.paper(scheme))
      .navigationTitle("원문 · \(location)")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
    }.folioSheetSize(width: 700, height: 680)
  }

}

/// PDFKit only receives a verified in-memory snapshot, never an original file URL.
struct FolioKnowledgePDFView: View {
  let preview: WikiKnowledgePDFPreview
  var title: String? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var document: PDFDocument?
  @State private var loaded = false

  var body: some View {
    NavigationStack {
      Group {
        if let document, let page = document.page(at: preview.pageIndex) {
          FolioKnowledgePDFCanvas(document: document, page: page, bounds: preview.bounds)
        } else if !loaded {
          ProgressView("원문 여는 중…")
        } else {
          ContentUnavailableView("페이지를 열지 못했습니다", systemImage: "doc.richtext",
            description: Text("자료에서 근거를 다시 찾아주세요."))
        }
      }
      .navigationTitle("인용 \(preview.pageIndex + 1)쪽")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .safeAreaInset(edge: .top, spacing: 0) {
        if title != nil || preview.usesOCR {
          VStack(alignment: .leading, spacing: 4) {
            if let title { Text(title).font(.subheadline) }
            if preview.usesOCR {
              Text("스캔 인식 영역 · 실제 글자와 기호를 원문에서 확인하세요.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 8).background(.background)
        }
      }
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
      .task {
        guard !loaded else { return }
        document = FolioKnowledgePDFCanvas.snapshot(preview)
        loaded = true
      }
    }.folioSheetSize(width: 860, height: 760)
  }
}

private struct FolioKnowledgePDFCanvas {
  let document: PDFDocument
  let page: PDFPage
  let bounds: [WikiPDFBounds]

  @MainActor static func snapshot(_ preview: WikiKnowledgePDFPreview) -> PDFDocument? {
    guard let document = PDFDocument(data: preview.data), let page = document.page(at: preview.pageIndex) else { return nil }
    let crop = page.bounds(for: .cropBox)
    for bound in preview.bounds {
      guard bound.isNormalized else { continue }
      let rect = CGRect(x: crop.minX + CGFloat(bound.x) * crop.width,
        y: crop.minY + CGFloat(bound.y) * crop.height,
        width: CGFloat(bound.width) * crop.width, height: CGFloat(bound.height) * crop.height)
      let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
      annotation.color = .systemYellow.withAlphaComponent(0.35)
      page.addAnnotation(annotation)
    }
    return document
  }

  @MainActor private func configure(_ view: PDFView) {
    view.autoScales = true
    #if os(iOS)
    view.displayMode = .singlePage
    view.usePageViewController(true)
    #else
    view.displayMode = .singlePageContinuous
    #endif
    view.displayBox = .cropBox
    view.document = document
  }

  @MainActor private func position(_ view: PDFView) {
    view.go(to: page)
    if let first = bounds.first(where: \.isNormalized) {
      let crop = page.bounds(for: .cropBox)
      let point = CGPoint(x: crop.minX + CGFloat(first.x) * crop.width,
        y: crop.minY + CGFloat(min(1, first.y + first.height)) * crop.height)
      view.go(to: PDFDestination(page: page, at: point))
    }
  }
}

#if os(macOS)
extension FolioKnowledgePDFCanvas: NSViewRepresentable {
  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    configure(view)
    position(view)
    return view
  }
  func updateNSView(_ view: PDFView, context: Context) {}
}
#else
extension FolioKnowledgePDFCanvas: UIViewRepresentable {
  func makeUIView(context: Context) -> PDFView {
    let view = AnchoredPDFView()
    configure(view)
    view.initialPosition = { view in position(view) }
    return view
  }
  func updateUIView(_ view: PDFView, context: Context) {}
}

/// PDFKit lays out and autosizes its scroll view after makeUIView.
/// Navigate after that first layout so autosizing cannot reset the cited page.
private final class AnchoredPDFView: PDFView {
  var initialPosition: ((PDFView) -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, initialPosition != nil { setNeedsLayout() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard window != nil, !bounds.isEmpty, let initialPosition else { return }
    self.initialPosition = nil
    Task { @MainActor [weak self] in
      guard let self, window != nil else { return }
      self.layoutIfNeeded()
      initialPosition(self)
    }
  }
}
#endif
