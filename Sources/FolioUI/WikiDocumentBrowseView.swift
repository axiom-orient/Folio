import SwiftUI
import FolioKnowledge

/// Browsing changes the same filter used by both the list and search results.
struct WikiDocumentBrowseView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme
  let model: WikiAppModel
  @Bindable var window: WikiWindowState

  var body: some View {
    #if os(macOS)
    WikiDocumentBrowseChoices(model: model, window: window)
      .frame(width: 360, height: 420).tint(FolioTheme.accent(scheme))
    #else
    NavigationStack {
      WikiDocumentBrowseChoices(model: model, window: window)
        .navigationTitle("찾아보기").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
    }.tint(FolioTheme.accent(scheme))
    #endif
  }
}

private struct WikiDocumentBrowseChoices: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme
  let model: WikiAppModel
  @Bindable var window: WikiWindowState

  private var options: WikiDocumentFilterOptions {
    .init(documents: model.snapshot?.documents ?? [], folders: model.documentLibrary.folders, filter: window.filter)
  }

  var body: some View {
    #if os(macOS)
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 8) {
        allDocumentsChoice
        heading("폴더")
        folderChoices
        if !options.tagChoices.isEmpty {
          heading("태그")
          tagChoices
        }
        if !options.typeChoices.isEmpty || window.filter.documentType != .all {
          heading("문서 유형")
          typeChoices
        }
        WikiDocumentLibraryNotice(model: model)
      }.padding(12)
    }.accessibilityIdentifier("document-browse-sheet")
    #else
    List {
      allDocumentsChoice
      Section("폴더") { folderChoices }
      if !options.tagChoices.isEmpty {
        Section("태그") { tagChoices }
      }
      if !options.typeChoices.isEmpty || window.filter.documentType != .all {
        Section("문서 유형") { typeChoices }
      }
      WikiDocumentLibraryNotice(model: model)
    }.accessibilityIdentifier("document-browse-sheet")
    #endif
  }

  private var allDocumentsChoice: some View {
    choice("모든 문서", systemImage: "doc.text", selected: window.filter == .init()) {
      window.filter = .init(); dismiss()
    }.accessibilityIdentifier("document-browse-all")
  }

  @ViewBuilder private var folderChoices: some View {
    if window.filter.folder != nil { choice("모든 폴더", selected: false) { selectFolder(nil) } }
    ForEach(options.folderChoices, id: \.self) { folder in
      choice(WikiFileAction.folderLabel(folder), systemImage: "folder", selected: window.filter.folder == folder) {
        selectFolder(folder)
      }
    }
  }

  @ViewBuilder private var tagChoices: some View {
    if window.filter.tag != nil { choice("모든 태그", selected: false) { selectTag(nil) } }
    ForEach(options.tagChoices) { tag in
      choice(tag.label, systemImage: "tag", selected: window.filter.tag.map(WikiTags.key) == tag.key) {
        selectTag(tag.label)
      }
    }
  }

  @ViewBuilder private var typeChoices: some View {
    choice("모든 유형", selected: window.filter.documentType == .all) { selectType(.all) }
    choice("유형 없음", selected: window.filter.documentType == .untyped) { selectType(.untyped) }
    ForEach(options.typeChoices, id: \.self) { type in
      choice(FolioTheme.typeName(type), selected: window.filter.documentType == .named(type)) { selectType(.named(type)) }
    }
  }

  #if os(macOS)
  private func heading(_ title: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider().accessibilityHidden(true)
      Text(title).font(.caption.weight(.medium)).foregroundStyle(FolioTheme.muted(scheme))
        .accessibilityAddTraits(.isHeader)
    }.padding(.top, 4)
  }
  #endif

  private func choice(_ title: String, systemImage: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary).accessibilityHidden(true) }
        Text(title).foregroundStyle(.primary).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        if selected { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true) }
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    #if os(macOS)
    .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityAddTraits(.isButton)
    .accessibilityAction { action() }
    #endif
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func selectFolder(_ folder: String?) {
    window.filter = .init(folder: folder, tag: window.filter.tag, documentType: window.filter.documentType)
    dismiss()
  }

  private func selectTag(_ tag: String?) {
    window.filter = .init(folder: window.filter.folder, tag: tag, documentType: window.filter.documentType)
    dismiss()
  }

  private func selectType(_ type: WikiDocumentTypeFilter) {
    window.filter = .init(folder: window.filter.folder, tag: window.filter.tag, documentType: type)
    dismiss()
  }
}

struct WikiDocumentLibraryNotice: View {
  let model: WikiAppModel
  var body: some View {
    if let problem = model.documentLibrary.loadProblem {
      Section {
        Label(problem.title, systemImage: "exclamationmark.circle")
          .font(.callout).fixedSize(horizontal: false, vertical: true)
        Button("다시 확인", systemImage: "arrow.clockwise") {
          guard let context = model.documentContext else { return }
          Task { await model.reloadDocumentLibrary(context: context) }
        }
        DisclosureGroup("자세히") { Text(problem.detail).font(.caption).textSelection(.enabled) }
      }
    }
  }
}
