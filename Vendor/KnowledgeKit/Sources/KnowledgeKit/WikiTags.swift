import Foundation

/// Tags retain the first spelling and order; equality uses canonical Unicode case folding.
public enum WikiTags {
  public static func key(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
      .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
      .precomposedStringWithCanonicalMapping
  }

  public static func normalize(_ values: [String]) throws -> [String] {
    guard values.count <= 64 else { throw WikiError.invalidSource("Tags accept at most 64 entries.") }
    var seen = Set<String>(); var result: [String] = []
    for raw in values {
      let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
      guard !value.isEmpty, value.utf8.count <= 128,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
        throw WikiError.invalidSource("Each tag must be nonempty, single-line text of at most 128 UTF-8 bytes.")
      }
      if seen.insert(key(value)).inserted { result.append(value) }
    }
    return result
  }
}
