import Foundation
import FolioKnowledge
import FolioKnowledgeApple

struct WikiFileAction: Identifiable {
  enum Kind {
    case createFolder(parent: String)
    case rename(path: String)
    case move(path: String)
    case trash(path: String)
    case restore(id: UUID, path: String)
    case purge(id: UUID, path: String)
  }
  let id = UUID()
  let kind: Kind
  let context: FolioDocumentContext
  var revision: String? = nil

  var path: String {
    switch kind {
    case .createFolder(let parent): parent
    case .rename(let path), .move(let path), .trash(let path), .restore(_, let path), .purge(_, let path): path
    }
  }
  var title: String {
    switch kind {
    case .createFolder: "새 폴더"
    case .rename: "이름 변경"
    case .move: "이동"
    case .trash: "휴지통으로 이동"
    case .restore: "복원"
    case .purge: "영구 삭제"
    }
  }
  var isDestructive: Bool {
    switch kind { case .trash, .purge: true; default: false }
  }
  var needsName: Bool {
    switch kind { case .createFolder, .rename: true; default: false }
  }
  var needsDestination: Bool { if case .move = kind { true } else { false } }
  static func folderLabel(_ path: String) -> String {
    path == "notes" ? "문서" : path.hasPrefix("notes/") ? String(path.dropFirst("notes/".count)) : path
  }

  func command(name: String, destination: String) throws -> WikiFileOperation {
    switch kind {
    case .createFolder(let parent): return .createFolder(path: parent + "/" + (try fileName(name)))
    case .rename(let path):
      return .move(path: path, to: (path as NSString).deletingLastPathComponent + "/" + (try fileName(name)))
    case .move(let path): return .move(path: path, to: destination + "/" + (path as NSString).lastPathComponent)
    case .trash(let path): return .trash(path: path)
    case .restore(let id, _): return .restore(id: id)
    case .purge(let id, _): return .purge(id: id)
    }
  }

  private func fileName(_ raw: String) throws -> String {
    guard let name = FolioInput.name(raw), !name.contains("/"), !name.contains("\\"),
      !name.hasPrefix("."), name.utf8.count <= 255 else {
      throw WikiError.invalidPath("이름은 숨김 항목·경로 구분자를 포함하지 않는 255바이트 이하의 한 줄이어야 합니다.")
    }
    return name
  }
}
