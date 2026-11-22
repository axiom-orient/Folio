import Foundation

/// The persisted shape remains compatible with existing recovery files.
struct FolioDraft: Codable, Sendable, Equatable {
  let path: String
  var text: String
  let original: String
  let revision: String
  var isDirty: Bool { text != original }

  /// Recovery admission distinguishes byte changes even for canonically equivalent Unicode spellings.
  func matchesBytes(of expected: Self) -> Bool {
    path.utf8.elementsEqual(expected.path.utf8) && text.utf8.elementsEqual(expected.text.utf8)
      && original.utf8.elementsEqual(expected.original.utf8) && revision.utf8.elementsEqual(expected.revision.utf8)
  }

  func afterSaving(path: String, submittedText: String, revision: String) -> Self? {
    guard text != submittedText else { return nil }
    return Self(path: path, text: text, original: submittedText, revision: revision)
  }
}
