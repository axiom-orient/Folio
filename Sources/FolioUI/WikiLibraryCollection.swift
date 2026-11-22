import SwiftUI

/// A location chooser. Selection and source effects remain with the caller.
struct WikiLibraryCollection: View {
  @Environment(\.colorScheme) private var scheme
  let current: FolioLibraryChoice?
  let local: [FolioLibraryChoice]
  let cloud: [FolioLibraryChoice]
  var archived: [FolioLibraryChoice] = []
  let supportsCloud: Bool
  let gatheringCloud: Bool
  let cloudProblem: String?
  let open: (FolioLibraryIdentity) -> Void
  let manage: () -> Void
  let create: () -> Void
  let importWorkspace: () -> Void
  let openFolder: (() -> Void)?
  let refreshCloud: () -> Void
  let archive: (FolioLibraryIdentity) -> Void
  let restore: (FolioLibraryIdentity) -> Void

  private var visibleChoices: [FolioLibraryChoice] { (current.map { [$0] } ?? []) + local + cloud }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        locationSections(visibleChoices, restoring: false)
        if visibleChoices.isEmpty && archived.isEmpty && !gatheringCloud && cloudProblem == nil {
          ContentUnavailableView {
            Label("자료함이 없습니다", systemImage: "books.vertical")
          } actions: {
            Button("새 자료함", action: create).buttonStyle(.borderedProminent)
          }
        }
        if supportsCloud && gatheringCloud {
          ProgressView("iCloud 자료함 찾는 중…").font(.callout)
        }
        if supportsCloud && cloudProblem != nil {
          VStack(alignment: .leading, spacing: 8) {
            Text("iCloud 자료함을 확인할 수 없습니다.").font(.callout)
            Button("다시 확인", action: refreshCloud)
          }
        }
        if let current {
          Button(action: manage) {
            FolioActionLabel(title: "자료함 설정", icon: "slider.horizontal.3")
          }
          .buttonStyle(.plain)
          .foregroundStyle(FolioTheme.text(scheme))
          .accessibilityValue(current.name)
        }
        if !archived.isEmpty {
          DisclosureGroup("숨긴 자료함") {
            locationSections(archived, restoring: true)
              .padding(.top, 12)
          }
        }
      }
      .padding(20)
    }
    .accessibilityIdentifier("library-scroll")
    .background(FolioTheme.paper(scheme))
    .tint(FolioTheme.accent(scheme))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu("자료함 추가", systemImage: "plus") {
          Button("새 자료함", systemImage: "plus", action: create)
            .accessibilityIdentifier("library-create")
          Button("자료함 가져오기…", systemImage: "square.and.arrow.down", action: importWorkspace)
            .accessibilityIdentifier("library-import")
          if let openFolder {
            Button("원문 폴더 열기…", systemImage: "folder", action: openFolder)
              .accessibilityIdentifier("library-open-folder")
          }
        }
        .labelStyle(.iconOnly)
        .help("자료함 추가")
        .accessibilityIdentifier("library-add")
      }
    }
  }

  private func locationSections(_ choices: [FolioLibraryChoice], restoring: Bool) -> some View {
    ForEach(FolioLibraryChoice.Storage.allCases, id: \.self) { storage in
      let group = choices.filter { $0.storage == storage }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      if !group.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          Text(storage.title)
            .font(.caption.weight(.medium))
            .foregroundStyle(FolioTheme.muted(scheme))
            .accessibilityAddTraits(.isHeader)
          ForEach(group) { choice in
            let isCurrent = !restoring && current?.id == choice.id
            let row = WikiLibraryChoiceRow(choice: choice, isCurrent: isCurrent) { open(choice.id) }
            if isCurrent {
              row
            } else if restoring {
              row.contextMenu { Button("목록에 다시 표시", systemImage: "eye") { restore(choice.id) } }
                .accessibilityAction(named: "목록에 다시 표시") { restore(choice.id) }
            } else {
              row.contextMenu { Button("목록에서 숨기기", systemImage: "eye.slash") { archive(choice.id) } }
                .accessibilityAction(named: "목록에서 숨기기") { archive(choice.id) }
            }
          }
        }
        .accessibilityElement(children: .contain)
      }
    }
  }
}

#Preview("자료함 선택") {
  NavigationStack {
    WikiLibraryCollection(
      current: .init(id: .cloud(nil, UUID()), name: "에이전트와 기술"),
      local: [.init(id: .local(UUID()), name: "읽고 쓰는 문서")], cloud: [],
      supportsCloud: true, gatheringCloud: false, cloudProblem: nil,
      open: { _ in }, manage: {}, create: {}, importWorkspace: {}, openFolder: nil,
      refreshCloud: {}, archive: { _ in }, restore: { _ in })
      .navigationTitle("자료함")
  }.frame(width: 460, height: 480)
}
