import Foundation
import Yams

struct SkillManifest: Sendable {
  static let byteLimit = 256 * 1024
  let name: String
  let summary: String

  static func validName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 64 && name == name.lowercased() && !name.hasPrefix("-") && !name.hasSuffix("-")
      && !name.contains("--") && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
  }

  init(data: Data, directoryName: String?) throws {
    guard data.count <= Self.byteLimit, let text = String(data: data, encoding: .utf8) else {
      throw SkillError.invalid("SKILL.md는 256 KiB 이하의 UTF-8 문서여야 합니다.")
    }
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
      throw SkillError.invalid("SKILL.md의 YAML frontmatter가 필요합니다.")
    }
    guard let header = try Yams.load(yaml: lines[1..<end].joined(separator: "\n")) as? [String: Any],
      let name = header["name"] as? String, Self.validName(name), directoryName == nil || name == directoryName,
      let description = header["description"] as? String,
      !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      description.count <= 1024 else {
      throw SkillError.invalid("name은 폴더 이름과 같은 소문자·숫자·하이픈(64자 이하), description은 1–1,024자여야 합니다.")
    }
    self.name = name; summary = description
  }

  static func sourceName(_ data: Data) throws -> String {
    try Self(data: data, directoryName: nil).name
  }
}
