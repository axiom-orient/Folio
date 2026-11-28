import FolioKnowledge
import FolioKnowledgeApple
import SwiftUI
import Foundation

struct WikiDocumentView: View {
  let model: WikiAppModel
  @Bindable var window: WikiWindowState
  var documentID: String? = nil
  @Environment(\.colorScheme) private var scheme
  @State private var infoSelection: InfoSelection?
  private struct InfoSelection: Identifiable {
    let document: WikiDocument
    let root: URL?
    let context: FolioDocumentContext?
    let workspaceGeneration: Int
    var id: String { document.id }
  }
  @State private var discardTarget: (id: String, context: FolioDocumentContext, text: String)?
  @State private var sendSource: FolioSendSource?
  @State private var assertionSelection: WikiKnowledgeAssertionReview?
  @State private var showingAssertions = false
  @State private var openingAssertion = false
  private var document: WikiDocument? { model.snapshot?.documents.first { $0.id == (documentID ?? window.selectedDocumentID) } }
  private var unavailableDocument: WikiDocument? {
    model.snapshot?.staleDocuments.first { $0.id == (documentID ?? window.selectedDocumentID) }
  }
  private var draft: WikiAppModel.Draft? { document.flatMap { model.drafts[$0.id] } }
  private var contentInset: CGFloat {
    #if os(macOS)
    32
    #else
    20
    #endif
  }
  var body: some View {
    Group {
      if let document {
        let editingGeneration = model.editorGeneration
        if window.isEditing {
          VStack(spacing: 0) {
            editingHeader(document)
            if let draft, draft.isDirty, draft.revision != document.revision {
              WikiStaleDraftBanner { showInformation(for: document) }
            }
            WikiRawEditor(text: editorText(for: document, generation: editingGeneration), documentID: document.id,
              startsAtEnd: window.editorStartsAtEnd,
              canEdit: { model.canAcceptPrivateEdits && model.editorGeneration == editingGeneration })
              .disabled(!model.canAcceptPrivateEdits)
              .id(document.id).id(model.openedSourceRoot).id(editingGeneration)
              .accessibilityIdentifier("document-editor")
          }
          .frame(maxWidth: 720).padding(.horizontal, contentInset)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
          WikiDocumentReaderView(model: model, window: window, document: document, draft: draft,
            activity: activity, contentInset: contentInset, onReview: { showInformation(for: document) })
        }
      } else if let unavailableDocument {
        let diagnostic = model.snapshot?.diagnostics.first { $0.path == unavailableDocument.relativePath }
        let generation = model.workspaceGeneration
        WikiUnavailableDocumentView(document: unavailableDocument, reason: diagnostic?.reason, contentInset: contentInset,
          canRecover: model.hasOpenWorkspace && diagnostic != nil, onRecover: {
            guard model.hasOpenWorkspace, model.workspaceGeneration == generation, let diagnostic,
              self.unavailableDocument?.id == unavailableDocument.id,
              self.unavailableDocument?.relativePath == diagnostic.path else { return }
            if diagnostic.reason == "source_conflict" { await model.showConflict(path: diagnostic.path) }
            else { await model.showSourceRepair(path: diagnostic.path) }
          })
      } else {
        ContentUnavailableView("문서를 선택하세요", systemImage: "doc.text")
      }
    }
    .background(FolioTheme.paper(scheme)).tint(FolioTheme.accent(scheme))
    .sheet(item: $sendSource) { WikiNearbyView(model: model, window: window, source: $0) }
    .sheet(item: savedCitationSelection) { saved in
      if canPresentSavedCitation(saved) {
        switch saved.content {
        case .markdown(let source, let sectionID, let location):
          FolioKnowledgeMarkdownView(document: source, sectionID: sectionID, location: location)
        case .pdf(let preview):
          FolioKnowledgePDFView(preview: preview)
        }
      }
    }
    .onChange(of: model.workspaceGeneration) { _, _ in window.savedCitation = nil }
    .onChange(of: model.hasOpenWorkspace) { _, open in if !open { window.savedCitation = nil } }
    .sheet(isPresented: $window.showConnections) {
      if let document {
        NavigationStack {
          ScrollView { WikiRelationsView(model: model, window: window, document: document).padding(24) }
            .navigationTitle("연결된 문서")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { window.showConnections = false } } }
        }
        #if os(macOS)
        .frame(width: 540, height: 500)
        #endif
      }
    }
    .sheet(item: $infoSelection) { captured in
      WikiDocumentInfoView(document: captured.document, isCurrent: infoIsCurrent(captured)) {
        guard infoIsCurrent(captured), window.selectedDocumentID == captured.document.id,
          let context = captured.context else { return }
        model.reviewSource(captured.document, in: window, context: context)
      }
    }
    .sheet(isPresented: $showingAssertions) {
      if let document {
        FolioKnowledgeAssertionsView(model: model,
          documentID: knowledgeRole == nil ? document.id : nil,
          conceptID: knowledgeRole == "concept" ? document.id : nil)
      }
    }
    .sheet(isPresented: Binding(get: { assertionSelection != nil }, set: { if !$0 { assertionSelection = nil } })) {
      if let review = assertionSelection, let focus = review.record.assertion.allEvidence.first {
        FolioKnowledgeAssertionView(model: model, focus: focus, existing: review.record, review: review)
      }
    }
    .onChange(of: model.workspaceGeneration) { _, _ in assertionSelection = nil; showingAssertions = false }
    .confirmationDialog("편집을 취소할까요?", isPresented: Binding(
      get: { discardTarget != nil }, set: { if !$0 { discardTarget = nil } }),
      titleVisibility: .visible, presenting: discardTarget) { target in
      Button("편집 취소", role: .destructive) {
        guard model.hasOpenWorkspace, model.documentContext == target.context,
          window.selectedDocumentID == target.id, model.drafts[target.id]?.text == target.text else {
          model.message = "편집 내용이 바뀌었습니다. 다시 확인해 주세요."; return
        }
        model.discardDraft(window); window.isEditing = false
      }
      Button("계속 편집", role: .cancel) {}
    } message: { _ in Text("저장하지 않은 변경을 취소합니다. 저장한 문서는 유지됩니다.") }
    #if os(iOS)
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    #endif
    .toolbar {
      #if os(iOS)
      ToolbarItemGroup(placement: .topBarTrailing) {
        if document != nil { primaryAction; documentOptions }
      }
      #else
      ToolbarItemGroup(placement: .primaryAction) {
        if document != nil { primaryAction; documentOptions }
      }
      #endif
    }
  }

  private var savedCitationSelection: Binding<WikiWindowState.SavedCitation?> {
    Binding(get: {
      guard let saved = window.savedCitation, canPresentSavedCitation(saved) else { return nil }
      return saved
    }, set: { value in
      if value == nil, window.savedCitation?.documentID == document?.id { window.savedCitation = nil }
    })
  }

  private func canPresentSavedCitation(_ saved: WikiWindowState.SavedCitation) -> Bool {
    model.hasOpenWorkspace && model.workspaceGeneration == saved.workspaceGeneration
      && document?.id == saved.documentID && window.selectedDocumentID == saved.documentID
  }

  private func editorText(for document: WikiDocument, generation: Int) -> Binding<String> {
    Binding(get: {
      let source = model.drafts[document.id]?.text ?? ""
      return FolioEditorContent(source: source).body
    }, set: { text in
      guard let current = model.drafts[document.id]?.text else { return }
      let source = FolioEditorContent(source: current).replacingBody(with: text)
      model.editText(source, documentID: document.id, generation: generation)
    })
  }

  private func editingHeader(_ document: WikiDocument) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(document.title).font(.headline).foregroundStyle(FolioTheme.text(scheme))
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("editor-document-title")
      if let activity { Text(activity).font(.caption).foregroundStyle(FolioTheme.muted(scheme)) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 8).padding(.bottom, 12)
  }

  private var activity: String? {
    if let document, model.savingDocuments.contains(document.id) { return "저장 중…" }
    if !model.hasOpenWorkspace { return "이전에 읽은 문서" }
    if draft?.isDirty == true { return "저장하지 않은 편집" }
    return draft == nil ? "문서를 확인하는 중…" : nil
  }

  @ViewBuilder private var primaryAction: some View {
    if window.isEditing {
      Button("저장") { save() }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("document-save")
        .disabled(draft?.isDirty != true || !model.hasOpenWorkspace
          || document.map { model.savingDocuments.contains($0.id) } == true)
        .keyboardShortcut("s", modifiers: .command)
    } else {
      Button(knowledgeRole == "assertion" ? "주장 수정" : draft?.isDirty == true ? "편집 이어쓰기" : (document.flatMap(WikiAttachmentImport.unmodifiedPDFPath(in:)) == nil ? "편집" : "노트 편집"),
        systemImage: "pencil") {
        if knowledgeRole == "assertion" { openAssertionEditor() }
        else { window.editorStartsAtEnd = false; window.isEditing = true }
      }
        .labelStyle(.titleOnly)
        .disabled(!model.hasOpenWorkspace || draft == nil || openingAssertion)
        .accessibilityIdentifier("document-edit")
    }
  }

  @ViewBuilder private var documentShare: some View {
    if let document, let share = model.markdownShare(document: document) {
      ShareLink(item: share, preview: SharePreview(document.title)) {
        Label(draft?.isDirty == true ? "저장한 문서 공유" : "공유", systemImage: "square.and.arrow.up")
      }
    }
  }

  private var documentOptionsTitle: String {
    #if os(macOS)
    "문서 작업"
    #else
    "문서 옵션"
    #endif
  }

  private var documentOptions: some View {
    Menu(documentOptionsTitle, systemImage: "ellipsis") {
      if window.isEditing {
        Button("저장한 원문 보기", systemImage: "eye") { window.isEditing = false }
          .accessibilityIdentifier("미리 보기")
          .keyboardShortcut(.escape, modifiers: [])
      } else if let document {
        Button("저장한 주장", systemImage: "text.book.closed") { showingAssertions = true }
          .disabled(!model.hasOpenWorkspace).accessibilityIdentifier("document-saved-assertions")
        if !isDerivedKnowledgeNote {
          Button("이 자료에 질문", systemImage: "text.bubble") {
            guard let context = model.documentContext else { return }
            window.knowledgeRequest = .init(documentID: document.id, initialQuestion: "",
              context: context, workspaceGeneration: model.workspaceGeneration)
          }
            .disabled(!model.hasOpenWorkspace).accessibilityIdentifier("knowledge-document-open")
        }
        Button("연결된 문서", systemImage: "link") { window.showConnections = true }
        if WikiAttachmentImport.unmodifiedPDFPath(in: document) == nil { attachmentMenu(for: document) }
      }
      if let document {
        Button("문서 정보", systemImage: "info.circle") { showInformation(for: document) }
      }
      Divider()
      if !window.isEditing, let document, let context = model.documentContext {
        if knowledgeRole == "assertion" {
          Button("텍스트 직접 편집", systemImage: "text.cursor") {
            window.editorStartsAtEnd = false; window.isEditing = true
          }.disabled(!model.hasOpenWorkspace || draft == nil)
        }
        Button("제목·태그 편집…", systemImage: "tag") { window.metadataSelection = .init(document: document, context: context) }
      }
      documentShare
      if let document, let share = model.markdownShare(document: document) {
        Button(draft?.isDirty == true ? "저장한 문서 보내기" : "기기로 보내기", systemImage: "laptopcomputer.and.iphone") { sendSource = .document(share) }
          .disabled(model.nearby.isWorking)
      }
      if window.isEditing {
        if let draft { ShareLink(item: draft.text) { Text("편집 복사본 공유") } }
        Divider()
        Button("편집 취소", role: .destructive) {
          if let document, let draft, let context = model.documentContext { discardTarget = (document.id, context, draft.text) }
        }
          .disabled(draft?.isDirty != true)
      } else if let document, let context = model.documentContext {
        Divider()
        WikiFileActionButtons(path: document.relativePath, revision: document.revision, context: context, action: $window.fileAction)
      }
    }
    .labelStyle(.iconOnly)
    .menuStyle(.borderlessButton)
  }

  private var knowledgeRole: String? {
    guard let text = draft?.text else { return nil }
    return (try? WikiOntologyRecord.read(bytes: Data(text.utf8)))?.role
  }

  private var isDerivedKnowledgeNote: Bool {
    guard let text = draft?.text else { return true }
    return (try? WikiMarkdownParser.isDerivedKnowledgeNote(bytes: Data(text.utf8))) ?? true
  }

  private func openAssertionEditor() {
    guard !openingAssertion, let document, let workspace = model.workspace, model.hasOpenWorkspace else { return }
    let generation = model.workspaceGeneration
    openingAssertion = true
    Task { @MainActor in
      defer { openingAssertion = false }
      do {
        let review = try await workspace.reviewKnowledgeAssertion(id: document.id)
        guard generation == model.workspaceGeneration, model.hasOpenWorkspace,
          self.document?.id == document.id, review.record.revision == document.revision else { return }
        assertionSelection = review
      } catch {
        if generation == model.workspaceGeneration {
          model.message = folioAssertionReviewMessage(error)
        }
      }
    }
  }

  @ViewBuilder private func attachmentMenu(for document: WikiDocument) -> some View {
    let paths = Set(document.declarations.compactMap { declaration -> String? in
      guard declaration.origin == .markdownLink,
        let path = WikiPath.resolveLink(declaration.target, from: document.relativePath), path.hasPrefix("attachments/") else { return nil }
      return path
    }).sorted()
    if !paths.isEmpty {
      Menu("첨부 파일", systemImage: "paperclip") {
        ForEach(paths, id: \.self) { path in
          Button(WikiWorkspace.attachmentDisplayName(relativePath: path)) { Task { await model.previewAttachment(path: path) } }
        }
      }.disabled(!model.hasOpenWorkspace)
    }
  }

  private func showInformation(for document: WikiDocument) {
    infoSelection = InfoSelection(document: document, root: model.openedSourceRoot,
      context: model.documentContext, workspaceGeneration: model.workspaceGeneration)
  }

  private func infoIsCurrent(_ captured: InfoSelection) -> Bool {
    guard model.hasOpenWorkspace, let context = captured.context, model.documentContext == context,
      model.workspaceGeneration == captured.workspaceGeneration, model.openedSourceRoot == captured.root,
      let current = model.session.document(id: captured.document.id) else { return false }
    return current.relativePath.utf8.elementsEqual(captured.document.relativePath.utf8)
      && current.revision.utf8.elementsEqual(captured.document.revision.utf8)
  }

  private func save() {
    guard let document, let context = model.documentContext else { return }
    guard let expectation = model.captureSaveExpectation(for: document, context: context) else { return }
    Task {
      guard model.documentContext == context, window.selectedDocumentID == document.id else { return }
      await model.save(window, expectation: expectation)
      #if os(iOS)
      if model.documentContext == context, window.selectedDocumentID == document.id,
        model.drafts[document.id]?.isDirty == false { window.isEditing = false }
      #endif
    }
  }


}

private struct WikiUnavailableDocumentView: View {
  @Environment(\.colorScheme) private var scheme
  let document: WikiDocument
  let reason: String?
  let contentInset: CGFloat
  let canRecover: Bool
  let onRecover: @MainActor () async -> Void
  @ScaledMetric(relativeTo: .title) private var titleSize = 28.0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text(document.title).font(.system(size: titleSize, weight: .semibold))
          .foregroundStyle(FolioTheme.text(scheme)).textSelection(.enabled)
          .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader).accessibilityIdentifier("unavailable-document-title")
        VStack(alignment: .leading, spacing: 8) {
          switch reason {
          case "download_pending":
            ProgressView("문서를 받는 중…").accessibilityIdentifier("document-download-pending")
          case "source_conflict":
            Label("문서의 변경 내용을 확인해 주세요", systemImage: "doc.on.doc")
              .accessibilityIdentifier("document-source-conflict")
          default:
            Label("원문을 확인할 수 없습니다", systemImage: "doc.text.magnifyingglass")
              .accessibilityIdentifier("document-source-unavailable")
          }
          if canRecover, reason != "download_pending" {
            Button(reason == "source_conflict" ? "변경 확인" : "원문 복구") { Task { await onRecover() } }
              .buttonStyle(.borderedProminent)
          }
        }
        .font(.callout).foregroundStyle(FolioTheme.muted(scheme))
        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: 720, alignment: .leading)
      .padding(.horizontal, contentInset).padding(.top, 24).padding(.bottom, 32)
      .frame(maxWidth: .infinity, alignment: .top)
    }
  }
}

