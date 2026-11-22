import FolioKnowledge
import Foundation

enum VaultPaths {
  static let notesDirectory = "notes/projectvault"
  static let attachmentsDirectory = "attachments/projectvault"

  static func stableID(_ path: String) -> String {
    "vault-" + SourceDigest.sha256(Data(path.precomposedStringWithCanonicalMapping.utf8)).prefix(24)
  }

  static func key(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive,
      locale: Locale(identifier: "en_US_POSIX"))
  }

  static func parent(_ path: String) -> String {
    let result = (path as NSString).deletingLastPathComponent
    return result == "." ? "" : result
  }

  static func normalize(_ path: String) -> String {
    let absolute = path.hasPrefix("/")
    var result: [String] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
      if component == "." { continue }
      if component == "..", let last = result.last, last != ".." { result.removeLast() }
      else if component != ".." || !absolute { result.append(component) }
    }
    return (absolute ? "/" : "") + (result.isEmpty ? (absolute ? "" : ".") : result.joined(separator: "/"))
  }

  static func joined(_ base: String, _ path: String) -> String {
    normalize(path.hasPrefix("/") ? path : [base, path].filter { !$0.isEmpty }.joined(separator: "/"))
  }

  static func relative(from directory: String, to path: String) -> String {
    let from = directory.split(separator: "/").map(String.init)
    let to = path.split(separator: "/").map(String.init)
    var shared = 0
    while shared < min(from.count, to.count), from[shared] == to[shared] { shared += 1 }
    let result = Array(repeating: "..", count: from.count - shared) + to.dropFirst(shared)
    return result.isEmpty ? "." : result.joined(separator: "/")
  }

  static func quote(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters:
      CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/.-_~")) ?? value
  }

  static func unquote(_ value: String) -> String {
    let bytes = Array(value.utf8)
    var result: [UInt8] = []; var index = 0
    while index < bytes.count {
      if bytes[index] == 37, index + 2 < bytes.count,
        let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
        result.append(high * 16 + low); index += 3
      } else { result.append(bytes[index]); index += 1 }
    }
    return String(decoding: result, as: UTF8.self)
  }

  static func jsonString(_ value: String) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  static func lines(_ text: String) -> [String] {
    var result: [String] = []; var line = ""
    for character in text {
      line.append(character)
      if character.isNewline { result.append(line); line = "" }
    }
    if !line.isEmpty { result.append(line) }
    return result
  }

  private static func hex(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
  }
}
