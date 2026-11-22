import Foundation

public struct VaultImportRequest: Sendable {
  public let source: URL
  public let destination: URL
  public let evidence: URL
  public let name: String

  public init(source: URL, destination: URL, evidence: URL, name: String = "ProjectVault") {
    self.source = source; self.destination = destination; self.evidence = evidence; self.name = name
  }
}

public struct VaultImportResult: Codable, Sendable {
  public let workspaceID: UUID
  public let workspace: URL
  public let manifest: URL
  public let markdown: Int
  public let files: Int
  public let convertedWikiLinks: Int
  public let parentRelations: Int
  public let unresolved: Int
}

public enum VaultImportError: LocalizedError, Sendable {
  case invalid(String)
  case incompleteCommit(workspace: URL, evidence: URL)

  public var errorDescription: String? {
    switch self {
    case .invalid(let message): message
    case .incompleteCommit(let workspace, let evidence):
      "두 출력 폴더를 함께 확정하지 못했고 복구도 완료하지 못했습니다. 성공한 가져오기로 사용하지 마세요. 자료함: \(workspace.path), 증거: \(evidence.path)"
    }
  }
}

struct VaultConversion: Codable, Sendable {
  let from: String
  let target: String
  let kind: String?
}

struct VaultIssue: Codable, Sendable {
  let source: String
  let target: String
  let reason: String
}

struct VaultParentRelation: Codable, Sendable {
  let target: String
  let basis = "original parent field"
}

struct VaultManifestEntry: Codable, Sendable {
  let originalPath: String
  let sourceSHA256: String
  let importedPath: String
  let importedSHA256: String
  let conversions: [VaultConversion]
  let parentRelation: VaultParentRelation?
}

struct VaultManifest: Encodable, Sendable {
  let createdAt: String
  let workspaceID: String
  let sourceRoot: String
  let workspaceRoot: String
  let originalMarkdownCount: Int
  let copiedFiles: Int
  let types: [String]
  let entries: [VaultManifestEntry]
  let unresolvedWikiLinks: [VaultIssue]
}

struct VaultInputFile: Sendable {
  let relativePath: String
  let data: Data
  var isMarkdown: Bool { Self.isMarkdownExtension((relativePath as NSString).pathExtension) }

  static func isMarkdownExtension(_ pathExtension: String) -> Bool {
    ["md", "markdown"].contains(pathExtension.lowercased())
  }
}

struct VaultOutputFile: Sendable {
  let relativePath: String
  let data: Data
}
