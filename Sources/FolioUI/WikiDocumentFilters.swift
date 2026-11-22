import Foundation
import FolioKnowledge

/// Derived choices and labels; the window's filter remains the selection authority.
struct WikiDocumentFilterOptions {
  struct Tag: Identifiable {
    let key: String
    let label: String
    var id: String { key }
  }

  let folderChoices: [String]
  let tagChoices: [Tag]
  let typeChoices: [String]
  let summary: String
  let accessibilitySummary: String

  init(documents: [WikiDocument], folders: [String], filter: WikiDocumentFilter) {
    var paths = Set(folders)
    for document in documents {
      var components = document.relativePath.split(separator: "/").dropLast()
      while !components.isEmpty {
        paths.insert(components.joined(separator: "/"))
        components = components.dropLast()
      }
    }
    if let selected = filter.folder { paths.insert(selected) }
    folderChoices = paths.sorted()

    var labels: [String: String] = [:]
    for tag in documents.flatMap(\.tags) where labels[WikiTags.key(tag)] == nil { labels[WikiTags.key(tag)] = tag }
    if let selected = filter.tag { labels[WikiTags.key(selected)] = labels[WikiTags.key(selected)] ?? selected }
    tagChoices = labels.map { Tag(key: $0.key, label: $0.value) }.sorted { $0.key < $1.key }

    var types = Set(documents.compactMap(\.type))
    if case .named(let selected) = filter.documentType { types.insert(selected) }
    typeChoices = types.sorted()

    var names: [String] = []
    var descriptions: [String] = []
    if let folder = filter.folder {
      let name = WikiFileAction.folderLabel(folder)
      names.append(name); descriptions.append("폴더: \(name)")
    }
    if let tag = filter.tag {
      let name = labels[WikiTags.key(tag)] ?? tag
      names.append("#\(name)"); descriptions.append("태그: \(name)")
    }
    switch filter.documentType {
    case .all: break
    case .untyped:
      names.append("유형 없음"); descriptions.append("유형 없음")
    case .named(let type):
      let name = FolioTheme.typeName(type)
      names.append(name); descriptions.append("문서 유형: \(name)")
    }
    summary = names.isEmpty ? "모든 문서" : names.joined(separator: " · ")
    accessibilitySummary = descriptions.isEmpty ? "모든 문서" : descriptions.joined(separator: ", ")
  }
}
