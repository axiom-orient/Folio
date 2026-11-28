import Foundation
import SEMIControl
import FolioKnowledge
import FolioKnowledgeApple

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

  /// The domain owns assertion fields. Keep its local references valid when
  /// embedding that schema in the existing mutation envelope.
  private static let assertionInputSchema: String = {
    guard var assertion = try? JSONSerialization.jsonObject(with: Data(WikiKnowledgeAssertion.inputSchemaJSON.utf8)) as? [String: Any],
      let definitions = assertion.removeValue(forKey: "$defs") as? [String: Any] else {
      preconditionFailure("Invalid built-in assertion schema.")
    }
    let schema: [String: Any] = [
      "type": "object", "additionalProperties": false,
      "properties": [
        "assertion": assertion,
        "path": ["type": "string", "minLength": 1, "maxLength": 4096],
        "expected_revision": ["type": "string", "pattern": "^[0-9a-f]{64}$"],
        "expected_concept_revisions": [
          "type": "object", "maxProperties": 64,
          "propertyNames": ["minLength": 1, "maxLength": 512],
          "additionalProperties": ["type": "string", "pattern": "^[0-9a-f]{64}$"],
          "description": "When saving reviewed knowledge, pass currentConceptRevisions from assertion_review to reject a Concept changed after review."
        ]
      ],
      "required": ["assertion"], "$defs": definitions
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) else {
      preconditionFailure("Cannot encode the built-in assertion capability schema.")
    }
    return String(decoding: data, as: UTF8.self)
  }()

  static let all: [Self] = [
    .init("wiki.search", "Find current source sections in this wiki; returns exact evidence references and explicit relations.",
      #"{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":512},"limit":{"type":"integer","minimum":1,"maximum":10}},"required":["query"],"additionalProperties":false}"#),
    .init("wiki.semantic_search", "Opt-in on-device Korean/English retrieval; no network. Returns scored exact references and explicit index budgets/partial coverage. Similarity is not truth or answerability.",
      #"{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":512},"limit":{"type":"integer","minimum":1,"maximum":20}},"required":["query"],"additionalProperties":false}"#),
    .init("wiki.knowledge_search", "Find current Markdown/PDF quotations in one request, with optional document scope and opt-in local meaning search. Returns exact quotations and concept resolution, not a generated answer or truth certification.",
      #"{"type":"object","properties":{"question":{"type":"string","minLength":1,"maxLength":8192},"document_id":{"type":"string","minLength":1,"maxLength":512},"use_semantic":{"type":"boolean"},"concept_id":{"type":"string","minLength":1,"maxLength":512}},"required":["question"],"additionalProperties":false}"#),
    .init("wiki.read_knowledge_evidence", "Recheck one returned Markdown/PDF evidence object against its current admitted original. Preserves the exact source location and OCR provenance; does not modify source.",
      #"{"type":"object","properties":{"evidence":{"type":"object"}},"required":["evidence"],"additionalProperties":false}"#),
    .init("wiki.concept", "Read a concept directly by stable ID, including its reviewed labels and original evidence. Rechecks backing quotations; no model, graph traversal or generated answer is required.",
      #"{"type":"object","properties":{"concept_id":{"type":"string","minLength":1,"maxLength":512}},"required":["concept_id"],"additionalProperties":false}"#),
    .init("wiki.concept_operation", "Observe an existing concept save operation after a lost or uncertain response. Reports historical commit and current evidence separately; never replays the save.",
      #"{"type":"object","properties":{"operation_id":{"type":"string","format":"uuid"}},"required":["operation_id"],"additionalProperties":false}"#),
    .init("wiki.save_concept", "Prepare one source-backed concept and its reviewed labels/mentions for separate SEMI approval. Existing records require their current revision; no source changes until the same plan is approved and executed.",
      #"{"type":"object","properties":{"concept":{"type":"object"},"path":{"type":"string","minLength":1,"maxLength":4096},"expected_revision":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"required":["concept"],"additionalProperties":false}"#, mutation: true),
    .init("wiki.assertion", "Read one assertion directly by stable ID with its conditions, literal quantity/unit, edition and exact original evidence. Rechecks the original source; adoption is not truth certification.",
      #"{"type":"object","properties":{"assertion_id":{"type":"string","minLength":1,"maxLength":512}},"required":["assertion_id"],"additionalProperties":false}"#),
    .init("wiki.assertion_review", "Read one saved assertion explicitly for review when connected concepts have changed. Original quotations must still be valid. Reports concept changes without rebinding, approval or admitting stale knowledge as current.",
      #"{"type":"object","properties":{"assertion_id":{"type":"string","minLength":1,"maxLength":512}},"required":["assertion_id"],"additionalProperties":false}"#),
    .init("wiki.assertions", "List current assertions, optionally filtered by concept, owning document, literal case-sensitive unit, edition label or text. Whole records fit the bounded response; omitted records and partial coverage are explicit. No model or generated answer is required.",
      #"{"type":"object","properties":{"concept_id":{"type":"string","minLength":1,"maxLength":512},"document_id":{"type":"string","minLength":1,"maxLength":512},"unit":{"type":"string","minLength":1,"maxLength":1024},"edition":{"type":"string","minLength":1,"maxLength":1024},"query":{"type":"string","minLength":1,"maxLength":8192},"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#),
    .init("wiki.assertion_operation", "Observe an existing assertion save operation after a lost or uncertain response. Historical commit and current original-evidence state are separate; this never replays a source write.",
      #"{"type":"object","properties":{"operation_id":{"type":"string","format":"uuid"}},"required":["operation_id"],"additionalProperties":false}"#),
    .init("wiki.save_assertion", "Prepare one assertion with explicitly cited conditions, literal values/units and edition for separate SEMI approval. Existing records require their current revision; only the approved exact plan may execute.",
      assertionInputSchema, mutation: true),
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
