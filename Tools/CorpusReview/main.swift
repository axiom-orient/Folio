import Foundation
import FolioKnowledge
import FolioKnowledgeApple

/// A bounded, opt-in review of the real imported corpus; no models or external requests.
@main struct CorpusReview {
  struct Manifest: Decodable {
    struct Entry: Decodable { let originalPath: String; let importedPath: String; let sourceSHA256: String; let importedSHA256: String }
    let sourceRoot: String
    let originalMarkdownCount: Int
    let entries: [Entry]
  }
  struct Query: Encodable {
    let query: String; let hitCount: Int; let paths: [String]; let evidenceReadable: Bool
  }
  struct Report: Encodable {
    let date: String; let workspaceID: String; let workspaceRoot: String
    let documents: Int; let sections: Int; let validRelations: Int; let unresolvedRelations: Int; let invalidRelations: Int
    let parentRelations: Int; let researchDocuments: Int; let coverageComplete: Bool; let diagnostics: [WikiDiagnostic]
    let originalsUnchanged: Bool; let importedHashesMatch: Bool; let queries: [Query]
    let prepareHadNoEffect: Bool; let editCommittedAndRestored: Bool; let markdownExportExact: Bool
    let sourceArchiveCreated: Bool; let managedImportRoot: String?
  }
  static func main() async throws {
    let args=Array(CommandLine.arguments.dropFirst())
    guard args.count == 4 || args.count == 5 else {
      throw WikiError.invalidSource("Usage: FolioCorpusReview WORKSPACE MANIFEST STATE REPORT [--import-managed]")
    }
    let importManaged = args.count == 5
    guard !importManaged || args[4] == "--import-managed" else {
      throw WikiError.invalidSource("Unknown option.")
    }
    let root=URL(fileURLWithPath: args[0], isDirectory: true)
    let manifest=try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    let stateDirectory=URL(fileURLWithPath: args[2], isDirectory: true)
    let workspace=try WikiWorkspace(root: root, localStateDirectory: stateDirectory)
    let report: Report
    do {
      report=try await review(workspace: workspace, root: root, manifest: manifest,
        stateDirectory: stateDirectory, importManaged: importManaged)
      let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
      try encoder.encode(report).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    } catch {
      await workspace.close()
      throw error
    }
    await workspace.close()
    print("Corpus usage PASS: \(report.documents) documents / \(report.validRelations) valid relations / \(report.queries.count) searches. Report: \(args[3])")
  }

  private static func review(workspace: WikiWorkspace, root: URL, manifest: Manifest,
    stateDirectory: URL, importManaged: Bool
  ) async throws -> Report {
    let snapshot=try await workspace.refresh()
    guard snapshot.documents.count >= manifest.originalMarkdownCount else { throw WikiError.invalidSource("Some imported Markdown was not indexed.") }
    let originalsUnchanged=try manifest.entries.allSatisfy {
      try SourceDigest.sha256(Data(contentsOf: URL(fileURLWithPath: manifest.sourceRoot).appendingPathComponent($0.originalPath))) == $0.sourceSHA256
    }
    let importedHashesMatch=try manifest.entries.allSatisfy {
      try SourceDigest.sha256(Data(contentsOf: root.appendingPathComponent($0.importedPath))) == $0.importedSHA256
    }
    guard originalsUnchanged, importedHashesMatch, snapshot.diagnostics.isEmpty else { throw WikiError.invalidSource("Import integrity or parser diagnostics need review.") }
    var queries: [Query]=[]
    for query in ["SQLite", "Swift", "단방향", "SKOS", "원문"] {
      let result=try await workspace.projection.search(query, limit: 5)
      var readable=true
      for hit in result.hits {
        let text=try await workspace.read(hit.reference)
        readable = readable && !text.isEmpty
      }
      guard !result.hits.isEmpty, readable else { throw WikiError.invalidSource("No readable evidence for query: \(query)") }
      queries.append(Query(query: query, hitCount: result.hits.count, paths: result.hits.map(\.reference.relativePath), evidenceReadable: readable))
    }
    guard let document=snapshot.documents.first(where: { $0.relativePath == "notes/projectvault/README.md" }) else { throw WikiError.unavailable("Imported root document missing.") }
    let edit=try await CorpusEditCheck.run(workspace: workspace, document: document, stateDirectory: stateDirectory)
    let exported=try await workspace.exportMarkdown(relativePath: document.relativePath, expectedRevision: edit.restoreReceipt.sourceRevision)
    let markdownExportExact=try Data(contentsOf: exported) == edit.original
    let archive=try await workspace.exportSourceArchive()
    let sourceArchiveCreated=FileManager.default.fileExists(atPath: archive.path)
    guard edit.editCommittedAndRestored, markdownExportExact, sourceArchiveCreated else { throw WikiError.unavailable("Edit or sharing check did not complete.") }
    var managedRoot: String?=nil
    if importManaged {
      if case .localManaged(let id)=try WikiWorkspaceAccess.importLocal(from: root) {
        managedRoot=try WikiWorkspaceAccess.localRoot(workspaceID: id, create: false).path
      }
    }
    return Report(date: "2026-10-10", workspaceID: snapshot.workspace.id.uuidString.lowercased(), workspaceRoot: root.path,
      documents: snapshot.documents.count, sections: snapshot.documents.flatMap(\.sections).count,
      validRelations: snapshot.relations.filter { $0.status == .valid }.count,
      unresolvedRelations: snapshot.relations.filter { $0.status == .unresolved }.count,
      invalidRelations: snapshot.relations.filter { $0.status == .invalid }.count,
      parentRelations: snapshot.relations.filter { $0.predicate == "part_of" && $0.status == .valid }.count,
      researchDocuments: snapshot.documents.filter { $0.type == "research" }.count,
      coverageComplete: snapshot.coverageComplete, diagnostics: snapshot.diagnostics,
      originalsUnchanged: originalsUnchanged, importedHashesMatch: importedHashesMatch, queries: queries,
      prepareHadNoEffect: edit.prepareHadNoEffect, editCommittedAndRestored: edit.editCommittedAndRestored,
      markdownExportExact: markdownExportExact, sourceArchiveCreated: sourceArchiveCreated, managedImportRoot: managedRoot)
  }
}
