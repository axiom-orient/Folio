import Foundation
import FolioKnowledge

/// A source is bound to the admitted workspace, its owning note and original bytes.
public struct WikiKnowledgeSource: Codable, Hashable, Sendable, Identifiable {
  public enum Kind: String, Codable, Hashable, Sendable { case markdown, pdf }
  public let id: String
  public let scopeID: String
  public let title: String
  public let relativePath: String
  public let documentID: String
  public let documentPath: String
  public let documentRevision: String
  public let revision: String
  public let kind: Kind
  public var indexRevision: String {
    SourceDigest.sha256((try? JSONEncoder().encode([id, scopeID, title, relativePath,
      documentID, documentPath, documentRevision, revision, kind.rawValue])) ?? Data())
  }

  public init(id: String, scopeID: String, title: String, relativePath: String,
    documentID: String, documentPath: String, documentRevision: String, revision: String, kind: Kind
  ) {
    self.id = id; self.scopeID = scopeID; self.title = title; self.relativePath = relativePath
    self.documentID = documentID; self.documentPath = documentPath
    self.documentRevision = documentRevision; self.revision = revision; self.kind = kind
  }
}

public enum WikiKnowledgeLocation: Codable, Hashable, Sendable {
  /// Range is absolute in the original Markdown bytes, inside the referenced section.
  case markdown(reference: WikiEvidenceReference, range: WikiSourceRange)
  /// Range is in the verbatim PDFKit page text, not in the binary PDF file.
  case pdf(pageIndex: Int, label: String, range: WikiSourceRange, pageSHA256: String, bounds: [WikiPDFBounds])
}

/// Exact source quotation. This is not a generated answer or a factual truth score.
public struct WikiKnowledgeEvidence: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let text: String
  public let source: WikiKnowledgeSource
  public let location: WikiKnowledgeLocation

  public init(id: String, text: String, source: WikiKnowledgeSource, location: WikiKnowledgeLocation) {
    self.id = id; self.text = text; self.source = source; self.location = location
  }
  public var markdownReference: WikiEvidenceReference? {
    if case .markdown(let reference, _) = location { reference } else { nil }
  }
  public var displayLocation: String {
    switch location {
    case .markdown(_, let range): "\(range.startLine)–\(range.endLine)행"
    case .pdf(let index, let label, _, _, _): label == String(index + 1) ? "\(label)쪽" : "\(label)쪽 (PDF \(index + 1)쪽)"
    }
  }
}

public struct WikiKnowledgeCoverage: Codable, Hashable, Sendable {
  public let sourceCount: Int
  public let blockCount: Int
  public let unreadablePages: Int
  /// All admitted sources were processed. This does not certify search recall or factual truth.
  public let complete: Bool
  public let semanticComplete: Bool
  public let diagnostics: [String]
  public init(sourceCount: Int, blockCount: Int, unreadablePages: Int,
    complete: Bool, semanticComplete: Bool, diagnostics: [String] = []
  ) {
    self.sourceCount = sourceCount; self.blockCount = blockCount; self.unreadablePages = unreadablePages
    self.complete = complete; self.semanticComplete = semanticComplete; self.diagnostics = diagnostics
  }
}

public struct WikiKnowledgeAnswer: Codable, Sendable {
  public let question: String
  public let evidence: [WikiKnowledgeEvidence]
  public let coverage: WikiKnowledgeCoverage
  public let semanticUsed: Bool
  public let documentID: String?
  public let checkedAt: Date
  public var atomicSnapshot: Bool { false }
  public init(question: String, evidence: [WikiKnowledgeEvidence], coverage: WikiKnowledgeCoverage,
    semanticUsed: Bool, documentID: String? = nil) {
    self.question = question; self.evidence = evidence; self.coverage = coverage; self.semanticUsed = semanticUsed
    self.documentID = documentID
    checkedAt = Date()
  }
}

public struct WikiKnowledgePDFPreview: Sendable {
  public let data: Data
  public let pageIndex: Int
  public let label: String
  public let bounds: [WikiPDFBounds]
}

public struct WikiKnowledgeInventory: Sendable {
  public let sources: [WikiKnowledgeSource]
  public let diagnostics: [String]
  public let fingerprint: String
}

public struct WikiKnowledgeMaterial: Sendable {
  public let evidence: [WikiKnowledgeEvidence]
  public let unreadablePages: Int
}
