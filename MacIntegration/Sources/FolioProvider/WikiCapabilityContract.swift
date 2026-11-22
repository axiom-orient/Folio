import Foundation
import SEMIControl
import FolioKnowledge

/// The public schema and runtime top-level input admission share one contract.
/// Domain value validation remains with each capability and the source owner.
struct WikiCapabilityContract: Sendable {
  let descriptor: AppCapabilityDescriptor
  private let inputKeys: Set<String>

  private init(_ id: String, _ summary: String, _ schema: String, mutation: Bool = false) {
    guard let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any],
      let properties = object["properties"] as? [String: Any] else {
      preconditionFailure("Invalid built-in wiki capability schema: \(id)")
    }
    inputKeys = Set(properties.keys)
    descriptor = AppCapabilityDescriptor(id: id, summary: summary, kind: mutation ? .mutation : .read,
      risk: mutation ? "medium" : "low", permissions: ["Selected wiki workspace"], schemaJSON: schema,
      failureSemantics: mutation ? "Lost execution responses may have applied source changes. Inspect the operation receipt." : "Changed/unavailable source is rejected; partial coverage is explicit.",
      recoverySemantics: "Read current source and receipts. Never replay an uncertain edit automatically.")
  }

  static func find(_ id: String) -> Self? { all.first { $0.descriptor.id == id } }

  func decode<T: Decodable>(_ json: String) throws -> T {
    guard json.utf8.count <= 65536 else { throw WikiError.invalidSource("Invalid/bounded wiki capability input.") }
    let data = Data(json.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys).isSubset(of: inputKeys) else { throw WikiError.invalidSource("Invalid/bounded wiki capability input.") }
    return try JSONDecoder().decode(T.self, from: data)
  }

  static let all: [Self] = [
    .init("wiki.search", "Find current source sections in this wiki; returns exact evidence references and explicit relations.",
      #"{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":512},"limit":{"type":"integer","minimum":1,"maximum":10}},"required":["query"],"additionalProperties":false}"#),
    .init("wiki.semantic_search", "Opt-in on-device Korean/English retrieval; no network. Returns scored exact references and explicit index budgets/partial coverage. Similarity is not truth or answerability.",
      #"{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":512},"limit":{"type":"integer","minimum":1,"maximum":20}},"required":["query"],"additionalProperties":false}"#),
    .init("wiki.suggest_relations", "Generate reviewable local multilingual relation proposals for a stable document and a caller-selected ontology predicate. Does not modify Markdown; similarity does not establish predicate semantics.",
      #"{"type":"object","properties":{"document_id":{"type":"string"},"predicate":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":10}},"required":["document_id","predicate"],"additionalProperties":false}"#),
    .init("wiki.relation_proposal", "Inspect a durable relation proposal and its current source/operation status after cancellation or a lost response. Does not replay changes.",
      #"{"type":"object","properties":{"proposal_id":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"required":["proposal_id"],"additionalProperties":false}"#),
    .init("wiki.accept_relation_proposal", "Prepare an exact relation proposal patch for separate SEMI approval. Rechecks source, target and ontology; uncertain outcomes must be inspected, never automatically replayed.",
      #"{"type":"object","properties":{"proposal_id":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"required":["proposal_id"],"additionalProperties":false}"#, mutation: true),
    .init("wiki.read", "Read an exact source section from a returned reference. Changed sources are rejected.",
      #"{"type":"object","properties":{"reference":{"type":"object"}},"required":["reference"],"additionalProperties":false}"#),
    .init("wiki.verify_evidence", "Verify up to 100 exact source references; reports current, changed, invalid or unavailable for each. This checks citations, not truth or question answerability. Reads are not an atomic snapshot.",
      #"{"type":"object","properties":{"references":{"type":"array","maxItems":100,"items":{"type":"object"}}},"required":["references"],"additionalProperties":false}"#),
    .init("wiki.source", "Read bounded original Markdown including frontmatter before preparing an edit. Requires the observed source revision.",
      #"{"type":"object","properties":{"path":{"type":"string","minLength":1,"maxLength":4096},"revision":{"type":"string","pattern":"^[0-9a-f]{64}$"},"start_line":{"type":"integer","minimum":1},"maximum_lines":{"type":"integer","minimum":1,"maximum":80}},"required":["path","revision"],"additionalProperties":false}"#),
    .init("wiki.relations", "Inspect explicit outgoing/incoming relations and their source revisions. Invalid/unresolved edges are labelled.",
      #"{"type":"object","properties":{"document_id":{"type":"string","minLength":1,"maxLength":512}},"required":["document_id"],"additionalProperties":false}"#),
    .init("wiki.status", "Inspect wiki identity, source diagnostics, document count and semantic-index state.",
      #"{"type":"object","properties":{},"additionalProperties":false}"#),
    .init("wiki.operation", "Inspect a durable operation receipt after an uncertain/lost response. It never reexecutes an edit.",
      #"{"type":"object","properties":{"operation_id":{"type":"string","format":"uuid"}},"required":["operation_id"],"additionalProperties":false}"#),
    .init("wiki.edit", "Prepare an exact Markdown patch or new note. No source changes until SEMI approves and executes the same plan.",
      #"{"type":"object","properties":{"path":{"type":"string","minLength":1,"maxLength":4096},"expected_revision":{"type":"string","pattern":"^[0-9a-f]{64}$"},"range":{"type":"object"},"replacement":{"type":"string","maxLength":50000}},"required":["path","replacement"],"additionalProperties":false}"#, mutation: true),
    .init("wiki.add_relation", "Prepare one explicitly requested typed relation, preserving unrelated source. Ontology and source revision are checked before approval.",
      #"{"type":"object","properties":{"path":{"type":"string","minLength":1,"maxLength":4096},"expected_revision":{"type":"string","pattern":"^[0-9a-f]{64}$"},"predicate":{"type":"string","minLength":1,"maxLength":512},"target_id":{"type":"string","minLength":1,"maxLength":512}},"required":["path","expected_revision","predicate","target_id"],"additionalProperties":false}"#, mutation: true),
  ]
}
