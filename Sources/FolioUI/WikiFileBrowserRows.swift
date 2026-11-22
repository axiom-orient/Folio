import FolioKnowledgeApple
import SwiftUI

struct WikiFileBrowserBreadcrumb: View {
  @Environment(\.colorScheme) private var scheme
  let workspace: String
  let folder: String
  let showingTrash: Bool
  let navigate: (String) -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        workspaceLabel
        if !showingTrash {
          Image(systemName: "chevron.right").font(.caption2).foregroundStyle(FolioTheme.muted(scheme)).accessibilityHidden(true)
          crumbs
        }
      }.fixedSize(horizontal: true, vertical: false)
      VStack(alignment: .leading, spacing: 6) {
        workspaceLabel
        if !showingTrash { VStack(alignment: .leading, spacing: 4) { crumbs } }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private var workspaceLabel: some View {
    Text(workspace).font(.callout).foregroundStyle(FolioTheme.muted(scheme))
      .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var crumbs: some View {
    let components = folder.split(separator: "/").map(String.init)
    ForEach(components.indices, id: \.self) { index in
      let path = components.prefix(index + 1).joined(separator: "/")
      HStack(spacing: 6) {
        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(FolioTheme.muted(scheme)).accessibilityHidden(true) }
        if index == components.count - 1 {
          Text(index == 0 ? "문서" : components[index]).foregroundStyle(FolioTheme.text(scheme))
        } else {
          Button(index == 0 ? "문서" : components[index]) { navigate(path) }.buttonStyle(.plain).foregroundStyle(.blue)
        }
      }.font(.callout).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct WikiFileBrowserFolders: View {
  @Environment(\.colorScheme) private var scheme
  @ScaledMetric(relativeTo: .body) private var minimumTileWidth: CGFloat = 140
  let entries: [WikiLibraryEntry]
  let context: FolioDocumentContext
  @Binding var action: WikiFileAction?
  let open: (WikiLibraryEntry) -> Void

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTileWidth), alignment: .top)], spacing: 16) {
      ForEach(entries) { entry in
        VStack(spacing: 8) {
          Button { open(entry) } label: {
            VStack(spacing: 10) {
              Image(systemName: "folder.fill").font(.system(size: 56)).symbolRenderingMode(.hierarchical).foregroundStyle(.blue)
              Text((entry.relativePath as NSString).lastPathComponent).font(.body).foregroundStyle(FolioTheme.text(scheme))
                .multilineTextAlignment(.center).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 112, alignment: .top).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityElement(children: .ignore)
            .accessibilityLabel((entry.relativePath as NSString).lastPathComponent).accessibilityAddTraits(.isButton)
          #if os(macOS)
          WikiFileBrowserItemActions(entry: entry, context: context, action: $action)
          #endif
        }
        #if os(iOS)
        .overlay(alignment: .topTrailing) {
          WikiFileBrowserItemActions(entry: entry, context: context, action: $action)
        }
        #endif
        .accessibilityElement(children: .contain)
          .contextMenu { WikiFileActionButtons(path: entry.relativePath, revision: entry.revision, context: context, action: $action) }
      }
    }.accessibilityElement(children: .contain).padding(.vertical, 8)
  }
}

struct WikiFileBrowserDocumentRow: View {
  @Environment(\.colorScheme) private var scheme
  let entry: WikiLibraryEntry
  let title: String
  let documentType: String?
  let context: FolioDocumentContext
  @Binding var action: WikiFileAction?
  let open: () -> Void

  private var isProject: Bool { documentType == "project" || documentType == "project_hub" }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Button(action: open) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: isProject ? "briefcase" : "doc.text").font(.title2).foregroundStyle(FolioTheme.muted(scheme))
          VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.body).foregroundStyle(FolioTheme.text(scheme))
            if isProject { Text(FolioTheme.typeName(documentType)).font(.caption).foregroundStyle(FolioTheme.muted(scheme)) }
            Text((entry.relativePath as NSString).lastPathComponent).font(.caption).foregroundStyle(FolioTheme.muted(scheme))
          }.lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
      #if os(macOS)
      .accessibilityElement(children: .ignore).accessibilityLabel(title)
        .accessibilityValue((entry.relativePath as NSString).lastPathComponent)
        .accessibilityAddTraits(.isButton).accessibilityAction { open() }
      #endif
      WikiFileBrowserItemActions(entry: entry, context: context, action: $action)
    }.padding(.vertical, 8)
      #if os(macOS)
      .accessibilityElement(children: .contain)
      #endif
      .contextMenu { WikiFileActionButtons(path: entry.relativePath, revision: entry.revision, context: context, action: $action) }
  }
}

private struct WikiFileBrowserItemActions: View {
  let entry: WikiLibraryEntry
  let context: FolioDocumentContext
  @Binding var action: WikiFileAction?

  var body: some View {
    #if os(macOS)
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) { actions }
      VStack(alignment: .leading, spacing: 8) { actions }
    }.buttonStyle(.borderless).font(.callout)
      .accessibilityElement(children: .contain)
    #else
    Menu("항목 관리", systemImage: "ellipsis") {
      WikiFileActionButtons(path: entry.relativePath, revision: entry.revision, context: context, action: $action)
    }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
      .frame(minWidth: 44, minHeight: 44).accessibilityValue((entry.relativePath as NSString).lastPathComponent)
    #endif
  }

  #if os(macOS)
  @ViewBuilder private var actions: some View {
    Button("이름 변경") { action = .init(kind: .rename(path: entry.relativePath), context: context, revision: entry.revision) }
      .fixedSize().accessibilityValue((entry.relativePath as NSString).lastPathComponent)
    Button("이동") { action = .init(kind: .move(path: entry.relativePath), context: context, revision: entry.revision) }
      .fixedSize().accessibilityValue((entry.relativePath as NSString).lastPathComponent)
    Button("휴지통") { action = .init(kind: .trash(path: entry.relativePath), context: context, revision: entry.revision) }
      .fixedSize().accessibilityValue((entry.relativePath as NSString).lastPathComponent)
  }
  #endif
}

struct WikiFileBrowserTrashRow: View {
  @Environment(\.colorScheme) private var scheme
  let entry: WikiTrashEntry
  let context: FolioDocumentContext
  @Binding var action: WikiFileAction?
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(entry.metadataAvailable ? WikiFileAction.folderLabel(entry.originalPath)
        : entry.state == .downloading ? "문서를 불러오는 중" : "문서를 불러오지 못했어요",
        systemImage: entry.metadataAvailable ? (entry.isDirectory ? "folder" : "doc.text") : "icloud")
        .lineLimit(nil).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      if entry.metadataAvailable {
        Text(entry.deletedAt, style: .date).font(.caption).foregroundStyle(FolioTheme.muted(scheme))
      }
      if entry.state == .downloading {
        HStack {
          ProgressView().controlSize(.small)
          if entry.metadataAvailable { Text("문서를 불러오는 중").font(.callout).foregroundStyle(.secondary) }
        }
      }
      if entry.state != .ready {
        Button("다시 불러오기", action: retry).buttonStyle(.borderless)
        if entry.state == .needsReview, let diagnostic = entry.diagnostic {
          DisclosureGroup("자세히") { Text(diagnostic).font(.caption).textSelection(.enabled) }
        }
      } else { readyActions }
    }.padding(.vertical, 6)
  }

  private var readyActions: some View {
    HStack {
      Button("복원") { action = WikiFileAction(kind: .restore(id: entry.id, path: entry.originalPath), context: context, revision: entry.revision) }
        .disabled(!entry.isAvailable).buttonStyle(.borderless)
      Spacer()
      #if os(macOS)
      purgeButton.buttonStyle(.borderless).foregroundStyle(FolioTheme.muted(scheme))
      #else
      Menu("휴지통 항목 관리", systemImage: "ellipsis") { purgeButton }
        .labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(minWidth: 44, minHeight: 44).accessibilityValue(WikiFileAction.folderLabel(entry.originalPath))
      #endif
    }
  }

  private var purgeButton: some View {
    Button("영구 삭제", role: .destructive) {
      action = WikiFileAction(kind: .purge(id: entry.id, path: entry.originalPath), context: context, revision: entry.revision)
    }.disabled(entry.revision.isEmpty)
  }
}

struct WikiFileActionButtons: View {
  let path: String
  let revision: String
  let context: FolioDocumentContext
  @Binding var action: WikiFileAction?
  var body: some View {
    Button("이름 변경…", systemImage: "pencil") { action = .init(kind: .rename(path: path), context: context, revision: revision) }
    Button("이동…", systemImage: "folder") { action = .init(kind: .move(path: path), context: context, revision: revision) }
    Button("휴지통으로 이동…", systemImage: "trash", role: .destructive) { action = .init(kind: .trash(path: path), context: context, revision: revision) }
  }
}
