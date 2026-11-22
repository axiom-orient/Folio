import Foundation
import FolioKnowledge

/// All parsing, resolution, and serialization finishes before any output is created.
struct VaultPlan {
  let workspace: [VaultOutputFile]
  let evidence: [VaultOutputFile]
  let result: VaultImportResult

  init(snapshot: VaultSnapshot, name: String, id: UUID, createdAt: Date) throws {
    let locations = snapshot.locations
    var links = VaultLinks(files: snapshot.files)
    guard Set(links.ids.values).count == links.ids.count else {
      throw VaultImportError.invalid("NFC 정규화 뒤 동일한 문서 ID가 되는 경로가 있습니다. 원본 경로를 구분한 뒤 가져오세요.")
    }
    var workspace: [VaultOutputFile] = []; var evidence: [VaultOutputFile] = []
    var entries: [VaultManifestEntry] = []; var types: Set<String> = ["research", "collection"]
    for file in snapshot.files {
      let importedPath = (file.isMarkdown ? VaultPaths.notesDirectory : VaultPaths.attachmentsDirectory) + "/" + file.relativePath
      let imported: Data
      let conversions: [VaultConversion]
      let parent: VaultParentRelation?
      if file.isMarkdown {
        let markdown = try VaultMarkdown(file: file, links: &links)
        imported = markdown.data; conversions = markdown.conversions; parent = markdown.parent
        guard imported.count <= VaultSnapshot.maximumMarkdownBytes else {
          throw VaultImportError.invalid("변환한 Markdown이 Folio 문서 제한 256 KiB를 넘었습니다.")
        }
        do { _ = try WikiMarkdownParser.document(relativePath: importedPath, bytes: imported) }
        catch { throw VaultImportError.invalid("변환한 Markdown을 Folio 문서로 읽을 수 없습니다. 원본 YAML 메타데이터와 문서 내용을 확인하세요.") }
        types.insert(markdown.type)
      } else { imported = file.data; conversions = []; parent = nil }
      workspace.append(VaultOutputFile(relativePath: importedPath, data: imported))
      evidence.append(VaultOutputFile(relativePath: "originals/" + file.relativePath, data: file.data))
      entries.append(VaultManifestEntry(originalPath: file.relativePath, sourceSHA256: SourceDigest.sha256(file.data),
        importedPath: importedPath, importedSHA256: SourceDigest.sha256(imported), conversions: conversions, parentRelation: parent))
    }
    let typeNames = types.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    let workspaceID = id.uuidString.lowercased()
    let header = "---\nid: \(workspaceID)\nkind: workspace\nschema: 1\nname: " + (try VaultPaths.jsonString(name)) + "\n---\n"
    let workspaceData = Data(header.utf8)
    let ontologyData = try Self.ontology(types: typeNames)
    guard ontologyData.count <= 65_536 else { throw VaultImportError.invalid("생성한 ontology가 Folio 읽기 제한 64 KiB를 넘었습니다.") }
    do {
      _ = try WikiMarkdownParser.workspace(bytes: workspaceData)
      _ = try WikiOntology(bytes: ontologyData)
    } catch { throw VaultImportError.invalid("자료함 이름 또는 문서 유형을 Folio 메타데이터로 읽을 수 없습니다.") }
    workspace.append(VaultOutputFile(relativePath: "_workspace.md", data: workspaceData))
    workspace.append(VaultOutputFile(relativePath: "_ontology.md", data: ontologyData))
    let markdownCount = links.ids.count
    let manifest = VaultManifest(createdAt: createdAt.ISO8601Format(),
      workspaceID: workspaceID, sourceRoot: locations.source.path, workspaceRoot: locations.destination.path,
      originalMarkdownCount: markdownCount, copiedFiles: snapshot.files.count, types: typeNames,
      entries: entries, unresolvedWikiLinks: links.issues)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    evidence.append(VaultOutputFile(relativePath: "import-manifest.json", data: try encoder.encode(manifest) + Data([0x0A])))
    self.workspace = workspace; self.evidence = evidence
    result = VaultImportResult(workspaceID: id, workspace: locations.destination,
      manifest: locations.evidence.appendingPathComponent("import-manifest.json"), markdown: markdownCount,
      files: snapshot.files.count, convertedWikiLinks: entries.flatMap(\.conversions).filter { $0.kind == nil }.count,
      parentRelations: entries.filter { $0.parentRelation != nil }.count, unresolved: links.issues.count)
  }

  private static func ontology(types: [String]) throws -> Data {
    let quoted = try types.map(VaultPaths.jsonString)
    let allowed = "[" + quoted.joined(separator: ", ") + "]"
    var result = "---\nkind: ontology\ntypes:\n" + quoted.map { "  \($0): {}\n" }.joined()
    result += "relations:\n  part_of:\n    from: \(allowed)\n    to: \(allowed)\n"
    result += "  references:\n    from: \(allowed)\n    to: \(allowed)\n"
    result += "  informs:\n    from: [research]\n    to: \(allowed)\n"
    result += "  contains:\n    from: [collection]\n    to: \(allowed)\n---\n"
    result += "# 관계 규칙\n\npart_of는 원본 parent 선언, references는 작성된 링크입니다. informs와 contains는 추가 자료의 명시적 연결입니다. 관계로부터 새로운 사실을 추론하지 않습니다.\n"
    return Data(result.utf8)
  }
}
