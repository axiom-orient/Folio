import Foundation
import Yams

extension WikiMarkdownParser {
  /// Saved quotations are useful documents, but must not become independent
  /// primary evidence merely because the original PDF was quoted into a note.
  public static func isDerivedKnowledgeNote(bytes: Data) throws -> Bool {
    let fields = try Frontmatter.read(SourceText(bytes)).fields
    return try isDerivedKnowledgeNote(fields["folio_knowledge_note"])
  }

  package static func knowledgeNoteProvenance(bytes: Data) throws -> Data? {
    let fields = try Frontmatter.read(SourceText(bytes)).fields
    guard try isDerivedKnowledgeNote(fields["folio_knowledge_note"]) else { return nil }
    guard let entry = fields["folio_knowledge_provenance"], entry.tag.rawValue == "tag:yaml.org,2002:str",
      let json = entry.scalar?.string else {
      throw WikiError.changedSource
    }
    return Data(json.utf8)
  }

  private static func isDerivedKnowledgeNote(_ marker: Node?) throws -> Bool {
    guard let marker else { return false }
    guard marker.tag.rawValue == "tag:yaml.org,2002:bool", let value = marker.scalar?.string,
      value == "true" || value == "false" else {
      throw WikiError.invalidSource("Invalid knowledge note marker.")
    }
    return value == "true"
  }
}
