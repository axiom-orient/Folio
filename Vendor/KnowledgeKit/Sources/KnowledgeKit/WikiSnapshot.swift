import Foundation

public struct WikiSnapshot: Codable, Sendable {
  public let workspace: WikiWorkspaceIdentity
  public let documents: [WikiDocument]
  public let staleDocuments: [WikiDocument]
  public let ontology: WikiOntology?
  public let ontologyUnavailable: Bool
  public let relations: [WikiRelation]
  public let diagnostics: [WikiDiagnostic]
  public let coverageComplete: Bool
  public let revision: String

  public init(workspace: WikiWorkspaceIdentity, documents: [WikiDocument],
    staleDocuments: [WikiDocument] = [], ontology: WikiOntology? = nil,
    ontologyUnavailable: Bool = false, diagnostics: [WikiDiagnostic] = [], coverageComplete: Bool = true
  ) {
    self.workspace = workspace; self.ontology = ontology; self.ontologyUnavailable = ontologyUnavailable
    let duplicateIDs = Set(Dictionary(grouping: documents, by: \.id).filter { $0.value.count > 1 }.keys)
    let duplicatePaths = Set(Dictionary(grouping: documents, by: \.relativePath).filter { $0.value.count > 1 }.keys)
    self.documents = documents.filter { !duplicateIDs.contains($0.id) && !duplicatePaths.contains($0.relativePath) }
      .sorted { $0.relativePath < $1.relativePath }
    self.staleDocuments = staleDocuments.sorted { $0.relativePath < $1.relativePath }
    var problems = diagnostics
    for document in documents {
      if duplicateIDs.contains(document.id) {
        problems.append(WikiDiagnostic(path: document.relativePath, reason: "duplicate_document_id"))
      }
      if duplicatePaths.contains(document.relativePath) {
        problems.append(WikiDiagnostic(path: document.relativePath, reason: "duplicate_document_path"))
      }
      if let ontology, let type = document.type, !ontology.types.contains(type) {
        problems.append(WikiDiagnostic(path: document.relativePath, reason: "undefined_type:\(type)"))
      }
    }
    self.diagnostics = problems.sorted { ($0.path, $0.reason) < ($1.path, $1.reason) }
    self.coverageComplete = coverageComplete && problems.isEmpty && !ontologyUnavailable
    relations = Self.resolve(documents: self.documents, ontology: ontology, unavailable: ontologyUnavailable)
    // Canonical length framing avoids ambiguous separators in user-provided identifiers.
    let revisions = self.documents.map { [$0.id, $0.relativePath, $0.revision] }
    let encoded = (try? JSONEncoder().encode(revisions)) ?? Data()
    revision = SourceDigest.sha256(encoded + Data((ontology?.revision ?? (ontologyUnavailable ? "unavailable" : "absent")).utf8))
  }

  private static func resolve(documents: [WikiDocument], ontology: WikiOntology?, unavailable: Bool) -> [WikiRelation] {
    let byID = Dictionary(uniqueKeysWithValues: documents.compactMap { document in
      document.stableID.map { ($0, document) }
    })
    let byPath = Dictionary(uniqueKeysWithValues: documents.map { ($0.relativePath, $0) })
    var result: [WikiRelation] = []
    for document in documents {
      for declaration in document.declarations {
        var target: WikiDocument?; var targetID: String
        if declaration.origin == .markdownLink {
          guard let path = WikiPath.resolveLink(declaration.target, from: document.relativePath),
            ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
          else { continue }
          target = byPath[path]; targetID = target?.id ?? "path:\(path)"
        } else { target = byID[declaration.target]; targetID = target?.id ?? declaration.target.precomposedStringWithCanonicalMapping }
        var status: WikiRelation.Status = target == nil ? .unresolved : .valid
        var reason: String? = target == nil ? "missing_or_ambiguous_target" : nil
        if declaration.origin == .frontmatter, let target {
          if unavailable { status = .unresolved; reason = "ontology_unavailable" }
          else if let ontology {
            if let constraint = ontology.relations[declaration.predicate],
              let sourceType = document.type, let targetType = target.type,
              constraint.from.contains(sourceType), constraint.to.contains(targetType) {
              status = .valid
            } else { status = .invalid; reason = "ontology_constraint" }
          }
        }
        result.append(WikiRelation(sourceID: document.id, sourceRevision: document.revision,
          predicate: declaration.predicate, targetID: targetID, targetRevision: target?.revision,
          ontologyRevision: ontology?.revision, origin: declaration.origin, range: declaration.range,
          status: status, diagnostic: reason))
      }
    }
    return result.sorted {
      ($0.sourceID, $0.range.lowerBound, $0.predicate, $0.targetID) <
        ($1.sourceID, $1.range.lowerBound, $1.predicate, $1.targetID)
    }
  }

  public func relations(for documentID: String) -> [WikiRelation] {
    relations.filter { $0.sourceID == documentID || $0.targetID == documentID }
  }

  public func indexedItems() -> [WikiIndexItem] {
    documents.flatMap { document in document.sections.map { section in
      WikiIndexItem(workspaceID: workspace.id, documentID: document.id, sectionID: section.id,
        title: document.title, headingPath: section.headingPath, relativePath: document.relativePath,
        sourceRevision: document.revision, range: section.range, excerptSHA256: section.contentHash,
        searchText: section.searchText)
    } }
  }
}

public struct WikiIndexItem: Codable, Hashable, Sendable, Identifiable {
  public let workspaceID: UUID
  public let documentID: String
  public let sectionID: String
  public let title: String
  public let headingPath: [String]
  public let relativePath: String
  public let sourceRevision: String
  public let range: WikiSourceRange
  public let excerptSHA256: String
  public let searchText: String
  public var id: String { "\(workspaceID.uuidString.lowercased())/\(sectionID)" }
  public var desiredHash: String {
    // Source/location changes require a new donation even when section text is identical.
    SourceDigest.sha256("\(sourceRevision)\0\(relativePath)\0\(searchText)")
  }
}

public struct WikiIndexJob: Codable, Sendable {
  public enum Operation: String, Codable, Sendable { case upsert, delete }
  public let adapter: String
  public let storeID: String
  public let subjectID: String
  public let desiredHash: String
  public let generation: Int64
  public let operation: Operation
  public let item: WikiIndexItem?
  public let lastError: String?
}

public struct WikiScan: Sendable {
  public let workspace: WikiWorkspaceIdentity
  public let documents: [WikiDocument]
  public let observedPaths: Set<String>
  public let ontology: WikiOntology?
  public let ontologyUnavailable: Bool
  public let diagnostics: [WikiDiagnostic]
  public let enumerationComplete: Bool

  public init(workspace: WikiWorkspaceIdentity, documents: [WikiDocument], observedPaths: Set<String>,
    ontology: WikiOntology?, ontologyUnavailable: Bool, diagnostics: [WikiDiagnostic], enumerationComplete: Bool
  ) {
    self.workspace = workspace; self.documents = documents; self.observedPaths = observedPaths
    self.ontology = ontology; self.ontologyUnavailable = ontologyUnavailable
    self.diagnostics = diagnostics; self.enumerationComplete = enumerationComplete
  }
}

/// Monotonic only within one source owner's lifetime; it is not a source revision.
public struct WikiScanSequence: Sendable {
  public let ownerID: UUID
  public let generation: UInt64
  public init(ownerID: UUID, generation: UInt64) { self.ownerID = ownerID; self.generation = generation }
}
