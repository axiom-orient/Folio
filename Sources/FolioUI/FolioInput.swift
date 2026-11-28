import Foundation
import FolioKnowledge

enum FolioInput {
  static func name(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 512,
      !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return nil }
    return value
  }

  static func documentSource(id: String, title: String, body: String, additionalFrontmatter: String = "") -> String {
    "---\nid: \(id)\n" + additionalFrontmatter + "---\n\n" + WikiMarkdownEditor.literalHeading(title) + "\n\n" + body
  }

}
