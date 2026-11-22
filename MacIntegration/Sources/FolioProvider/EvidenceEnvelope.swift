import Foundation
import FolioKnowledge

/// Wire projection for SEMI's existing source receipt UI; exact references are additive.
struct EvidenceEnvelope: Encodable {
  let schema = "semi.knowledge/1"
  let root: String
  let query: String?
  let sources: [EvidenceSource]
  let diagnostics: [WikiDiagnostic]
  let diagnosticsTruncated: Bool
  let documentsAvailable: Int
  let coverageComplete: Bool
  let resultsTruncated: Bool
  let atomicSnapshot = false
  let semanticState: String

  init(root: String, query: String, result: WikiSearchResult, snapshot: WikiSnapshot?) {
    self.root = root; self.query = query
    sources = result.hits.map { EvidenceSource(reference: $0.reference, title: $0.title,
      heading: $0.breadcrumb, excerpt: $0.snippet, snapshot: snapshot) }
    diagnostics = Array(result.diagnostics.prefix(8)); diagnosticsTruncated = result.diagnostics.count > 8
    documentsAvailable = snapshot?.documents.count ?? 0; coverageComplete = result.coverageComplete
    resultsTruncated = result.resultsTruncated; semanticState = result.semanticState
  }

  init(root: String, source: EvidenceSource) {
    self.root = root; query = nil; sources = [source]; diagnostics = []; diagnosticsTruncated = false
    documentsAvailable = 1; coverageComplete = false; resultsTruncated = source.excerptTruncated; semanticState = "exactRead"
  }
}

struct EvidenceSource: Encodable {
  let documentID: String; let relativePath: String; let title: String; let heading: [String]
  let sha256: String; let startLine: Int; let endLine: Int; let excerpt: String
  let excerptTruncated: Bool; let relations: [Relation]; let relationsTruncated: Bool
  let reference: WikiEvidenceReference
  let sourceURL: String?

  init(reference: WikiEvidenceReference, title: String, heading: [String], excerpt: String, snapshot: WikiSnapshot?) {
    self.reference = reference; documentID = reference.documentID; relativePath = reference.relativePath
    var link = URLComponents(); link.scheme = "folio"; link.host = "open"
    link.queryItems = [URLQueryItem(name: "workspace", value: reference.workspaceID.uuidString),
      URLQueryItem(name: "document", value: reference.documentID), URLQueryItem(name: "section", value: reference.sectionID),
      URLQueryItem(name: "revision", value: reference.sourceRevision)]
    sourceURL = link.url?.absoluteString
    self.title = title; self.heading = heading; sha256 = reference.sourceRevision
    startLine = reference.range.startLine; endLine = reference.range.endLine
    let bytes = Data(excerpt.utf8)
    var clipped = bytes.prefix(8192)
    while String(data: clipped, encoding: .utf8) == nil { clipped = clipped.dropLast() }
    self.excerpt = String(decoding: clipped, as: UTF8.self)
    excerptTruncated = bytes.count < reference.range.upperBound - reference.range.lowerBound || bytes.count > clipped.count
    let edges = snapshot?.relations(for: documentID) ?? []
    relations = edges.prefix(8).map { Relation($0, snapshot: snapshot) }; relationsTruncated = edges.count > 8
  }

  struct Relation: Encodable {
    let predicate: String; let sourceID: String; let sourceTitle: String; let sourcePath: String
    let sourceSHA256: String; let targetID: String; let targetTitle: String?; let targetPath: String?
    let targetSHA256: String?; let declarationLine: Int; let status: String
    init(_ relation: WikiRelation, snapshot: WikiSnapshot?) {
      let source = snapshot?.documents.first { $0.id == relation.sourceID }
      let target = snapshot?.documents.first { $0.id == relation.targetID }
      predicate = relation.predicate; sourceID = relation.sourceID; sourceTitle = source?.title ?? sourceID
      sourcePath = source?.relativePath ?? ""; sourceSHA256 = relation.sourceRevision; targetID = relation.targetID
      targetTitle = target?.title; targetPath = target?.relativePath; targetSHA256 = relation.targetRevision
      declarationLine = relation.range.startLine; status = relation.status.rawValue
    }
  }
}
