import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import Testing

struct DocumentSearchTests {
  @Test func paginationReturnsEveryFTSSectionBeyondFiveHundredWithoutDuplicates() async throws {
    try await withDocumentSearchFixture { fixture in
      let count = 627
      let body = (0..<count).map { "# Section \($0)\nPaginationNeedle source \($0)\n\n" }.joined()
      try fixture.write("---\nid: many-sections\n---\n" + body, path: "notes/many.md")
      let snapshot = try await fixture.workspace.refresh()
      let document = try #require(snapshot.documents.first { $0.id == "many-sections" })
      #expect(document.sections.count == count)
      let service = fixture.localService()

      let firstPass = try await documentSearchPages(service, query: "PaginationNeedle", pageSize: 73)
      let secondPass = try await documentSearchPages(service, query: "PaginationNeedle", pageSize: 73)
      let hits = firstPass.flatMap(\.hits)
      #expect(firstPass.count == 9)
      #expect(firstPass.allSatisfy { $0.totalCount == count && $0.coverageComplete && $0.semanticState == "local" })
      #expect(Set(firstPass.map(\.sourceRevision)).count == 1)
      #expect(firstPass.last?.nextCursor == nil)
      #expect(hits.count == count)
      #expect(Set(hits.map(\.id)).count == count)
      #expect(Set(hits.map(\.id)) == Set(document.sections.map(\.id)))
      #expect(hits.map(\.fusedRank) == Array(1...count))
      #expect(secondPass.flatMap(\.hits).map(\.id) == hits.map(\.id))
      #expect(hits.allSatisfy { $0.provenance.contains(.fts) && $0.reference.sourceRevision == document.revision })
      let projectionPage = try await fixture.workspace.projection.searchPage("PaginationNeedle", pageSize: 73)
      #expect(projectionPage.hits.map(\.id) == firstPass.first?.hits.map(\.id))
      #expect(projectionPage.totalCount == count)
      for hit in [try #require(hits.first), try #require(hits.last)] {
        #expect(try await fixture.workspace.read(hit.reference).contains("PaginationNeedle"))
      }
    }
  }

  @Test func batchedEvidencePreservesRequestOrderAndDuplicatesAndRejectsAnyInvalidMember() async throws {
    try await withDocumentSearchFixture { fixture in
      try fixture.write(searchSectionNote(id: "batch-a", count: 2, token: "FirstDocumentNeedle"), path: "notes/a.md")
      let secondSource = searchSectionNote(id: "batch-b", count: 2, token: "SecondDocumentNeedle")
      try fixture.write(secondSource, path: "notes/b.md")
      let snapshot = try await fixture.workspace.refresh()
      let first = try #require(snapshot.documents.first { $0.id == "batch-a" })
      let second = try #require(snapshot.documents.first { $0.id == "batch-b" })
      try #require(first.sections.count == 2 && second.sections.count == 2)
      let a0 = WikiEvidenceReference(workspaceID: snapshot.workspace.id, document: first, section: first.sections[0])
      let a1 = WikiEvidenceReference(workspaceID: snapshot.workspace.id, document: first, section: first.sections[1])
      let b0 = WikiEvidenceReference(workspaceID: snapshot.workspace.id, document: second, section: second.sections[0])
      let excerpts = try await fixture.workspace.read([b0, a1, b0, a0])
      #expect(excerpts == [second.sections[0].sourceText, first.sections[1].sourceText,
        second.sections[0].sourceText, first.sections[0].sourceText])

      let encoded = try JSONEncoder().encode(b0)
      let originalFields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      for field in ["workspaceID", "documentID", "sectionID", "sourceRevision", "range", "excerptSHA256"] {
        var fields = originalFields
        switch field {
        case "workspaceID": fields[field] = UUID().uuidString
        case "documentID", "sectionID": fields[field] = "unrelated-identity"
        case "range":
          var range = try #require(fields[field] as? [String: Any])
          range["lowerBound"] = b0.range.lowerBound + 1
          fields[field] = range
        default: fields[field] = String(repeating: "0", count: 64)
        }
        let invalid = try JSONDecoder().decode(WikiEvidenceReference.self, from: JSONSerialization.data(withJSONObject: fields))
        await #expect(throws: (any Error).self) { try await fixture.workspace.read([a0, invalid, a1]) }
      }

      // a.md sorts before b.md: a stale later path must fail the entire result.
      try fixture.write(secondSource + "Later external source edit\n", path: "notes/b.md")
      await #expect(throws: WikiError.changedSource) { try await fixture.workspace.read([a0, b0, a1]) }
      #expect(try await fixture.workspace.read(a0) == first.sections[0].sourceText)
      await fixture.workspace.close()
      await #expect(throws: (any Error).self) { try await fixture.workspace.read([a0, a1]) }
      await #expect(throws: (any Error).self) { try await fixture.workspace.read(a0) }
    }
  }

  @Test func combinedDocumentFiltersApplyBeforeRankingIsSlicedIntoPages() async throws {
    try await withDocumentSearchFixture { fixture in
      try fixture.write("---\nid: exact-decoy\naliases: [FilterNeedle]\ntags: [Ignored]\n---\n# Excluded exact match\nBody\n", path: "notes/decoy.md")
      try fixture.write(searchNote(id: "included-a", tags: ["Wanted"], type: "research", token: "FilterNeedle"), path: "notes/focus/a.md")
      try fixture.write(searchNote(id: "included-b", tags: ["Wanted"], type: "research", token: "FilterNeedle"), path: "notes/focus/deep/b.md")
      try fixture.write(searchNote(id: "sibling", tags: ["Wanted"], type: "research", token: "FilterNeedle"), path: "notes/focus-archive/sibling.md")
      try fixture.write(searchNote(id: "wrong-tag", tags: ["Ignored"], type: "research", token: "FilterNeedle"), path: "notes/focus/wrong-tag.md")
      try fixture.write(searchNote(id: "wrong-type", tags: ["Wanted"], type: "Research", token: "FilterNeedle"), path: "notes/focus/wrong-type.md")
      try fixture.write(searchNote(id: "untyped", tags: ["Wanted"], token: "FilterNeedle"), path: "notes/focus/untyped.md")
      let service = fixture.localService()
      let unfiltered = try await service.searchPage("FilterNeedle", pageSize: 1)
      #expect(unfiltered.hits.first?.reference.documentID == "exact-decoy")
      let filter = WikiDocumentFilter(folder: "notes/focus", tag: "wanted", documentType: .named("research"))
      let pages = try await documentSearchPages(service, query: "FilterNeedle", filter: filter, pageSize: 1)
      #expect(pages.count == 2)
      #expect(pages.allSatisfy { $0.totalCount == 2 && $0.hits.count == 1 })
      #expect(Set(pages.flatMap(\.hits).map(\.reference.documentID)) == ["included-a", "included-b"])
      #expect(pages.flatMap(\.hits).map(\.fusedRank) == [1, 2])
    }
  }

  @Test func folderFiltersUsePathComponentBoundariesAndIncludeNestedNotes() async throws {
    try await withDocumentSearchFixture { fixture in
      for (path, id) in [
        ("notes/work/a.md", "direct"), ("notes/work/nested/b.md", "nested"),
        ("notes/workshop/c.md", "sibling"), ("notes/work-other/d.md", "prefix"),
        ("notes/work.md", "same-basename")
      ] { try fixture.write(searchNote(id: id), path: path) }
      let service = fixture.localService()
      let filtered = try await service.searchPage("", filter: .init(folder: "notes/work"), pageSize: 100)
      #expect(Set(filtered.hits.map(\.reference.documentID)) == ["direct", "nested"])
      #expect(filtered.totalCount == 2)
      #expect(filtered.nextCursor == nil)
      let notes = try await service.searchPage("", filter: .init(folder: "notes"), pageSize: 100)
      #expect(notes.totalCount == 5)
      let empty = try await service.searchPage("", filter: .init(folder: "notes/missing"), pageSize: 100)
      #expect(empty.hits.isEmpty)
      #expect(empty.totalCount == 0)
      #expect(empty.nextCursor == nil)
    }
  }

  @Test func tagFiltersFoldUnicodeCaseWhileNamedTypesKeepTheirCase() async throws {
    try await withDocumentSearchFixture { fixture in
      try fixture.write(searchNote(id: "composed", tags: ["café", "Straße"], type: "Café"), path: "notes/composed.md")
      try fixture.write(searchNote(id: "decomposed", tags: ["CAFE\u{301}", "STRASSE"], type: "Other"), path: "notes/decomposed.md")
      try fixture.write(searchNote(id: "unaccented", tags: ["cafe"], type: "café"), path: "notes/unaccented.md")
      try fixture.write(searchNote(id: "untyped", tags: ["Other"]), path: "notes/untyped.md")
      let service = fixture.localService()
      let accent = try await service.searchPage("", filter: .init(tag: " CAFE\u{301} "), pageSize: 100)
      #expect(Set(accent.hits.map(\.reference.documentID)) == ["composed", "decomposed"])
      let folded = try await service.searchPage("", filter: .init(tag: "strasse"), pageSize: 100)
      #expect(Set(folded.hits.map(\.reference.documentID)) == ["composed", "decomposed"])
      let plain = try await service.searchPage("", filter: .init(tag: "CAFE"), pageSize: 100)
      #expect(plain.hits.map(\.reference.documentID) == ["unaccented"])
      let named = try await service.searchPage("", filter: .init(documentType: .named("Cafe\u{301}")), pageSize: 100)
      #expect(named.hits.map(\.reference.documentID) == ["composed"])
      let lowercaseType = try await service.searchPage("", filter: .init(documentType: .named("café")), pageSize: 100)
      #expect(lowercaseType.hits.map(\.reference.documentID) == ["unaccented"])
      let untyped = try await service.searchPage("", filter: .init(documentType: .untyped), pageSize: 100)
      #expect(untyped.hits.map(\.reference.documentID) == ["untyped"])
      #expect(try await service.searchPage("", pageSize: 100).totalCount == 4)
    }
  }

  @Test func cursorsRemainValidForUnchangedSourceAndRejectDifferentRequests() async throws {
    try await withDocumentSearchFixture { fixture in
      try fixture.write(searchSectionNote(id: "cursor-note", count: 5, token: "CursorNeedle"), path: "notes/cursor.md")
      let service = fixture.localService()
      let first = try await service.searchPage("CursorNeedle", pageSize: 2)
      let cursor = try #require(first.nextCursor)
      let decoded = try JSONDecoder().decode(WikiSearchCursor.self, from: JSONEncoder().encode(cursor))
      #expect(decoded == cursor)
      await expectInvalidDocumentSearchRequest {
        try await service.searchPage("OtherNeedle", cursor: decoded, pageSize: 2)
      }
      await expectInvalidDocumentSearchRequest {
        try await service.searchPage("CursorNeedle", filter: .init(folder: "notes/subfolder"), cursor: decoded, pageSize: 2)
      }
      await expectInvalidDocumentSearchRequest {
        try await service.searchPage("CursorNeedle", cursor: decoded, pageSize: 3)
      }
      let next = try await service.searchPage("CursorNeedle", cursor: decoded, pageSize: 2)
      #expect(next.totalCount == 5)
      #expect(next.sourceRevision == first.sourceRevision)
      #expect(next.hits.map(\.fusedRank) == [3, 4])
      #expect(Set(first.hits.map(\.id)).isDisjoint(with: next.hits.map(\.id)))
      #expect(next.nextCursor != nil)
      let normalizedQuery = try await service.searchPage(" cursorneedle ", cursor: decoded, pageSize: 2)
      #expect(normalizedQuery.hits.map(\.id) == next.hits.map(\.id))

      var damaged = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cursor)) as? [String: Any])
      let tokenKey = try #require(damaged.first { $0.value is String }?.key)
      damaged[tokenKey] = "not a valid continuation"
      let invalidCursor = try JSONDecoder().decode(WikiSearchCursor.self, from: JSONSerialization.data(withJSONObject: damaged))
      await expectInvalidDocumentSearchRequest {
        try await service.searchPage("CursorNeedle", cursor: invalidCursor, pageSize: 2)
      }
    }
  }

  @Test(arguments: ["zero-page", "oversized-page", "oversized-query"])
  func pagedSearchRejectsOutOfBoundsRequests(kind: String) async throws {
    try await withDocumentSearchFixture { fixture in
      try fixture.write(searchNote(id: "bounded"), path: "notes/bounded.md")
      let service = fixture.localService()
      await expectInvalidDocumentSearchRequest {
        switch kind {
        case "zero-page": try await service.searchPage("", pageSize: 0)
        case "oversized-page": try await service.searchPage("", pageSize: 101)
        default: try await service.searchPage(String(repeating: "q", count: 513), pageSize: 50)
        }
      }
    }
  }

  @Test(arguments: ["body", "tags", "new-document", "removed-document"])
  func aCursorCannotContinueAfterTheAuthoritativeSourceChanges(kind: String) async throws {
    try await withDocumentSearchFixture { fixture in
      let original = searchSectionNote(id: "changing", count: 5, token: "ChangingNeedle")
      try fixture.write(original, path: "notes/changing.md")
      try fixture.write(searchNote(id: "other", token: "ChangingNeedle"), path: "notes/other.md")
      let service = fixture.localService()
      let first = try await service.searchPage("ChangingNeedle", pageSize: 2)
      let cursor = try #require(first.nextCursor)
      switch kind {
      case "body": try fixture.write(original + "Later external body edit\n", path: "notes/changing.md")
      case "tags": try fixture.write(original.replacingOccurrences(of: "id: changing\n", with: "id: changing\ntags: [ExternalTag]\n"), path: "notes/changing.md")
      case "new-document": try fixture.write(searchNote(id: "new", token: "ChangingNeedle"), path: "notes/new.md")
      default: try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("notes/other.md"))
      }
      await #expect(throws: WikiError.changedSource) {
        try await service.searchPage("ChangingNeedle", cursor: cursor, pageSize: 2)
      }
      let fresh = try await service.searchPage("ChangingNeedle", pageSize: 2)
      #expect(fresh.sourceRevision != first.sourceRevision)
      #expect(fresh.coverageComplete)
    }
  }

  @Test func metadataEditsRemainSearchableThroughFiltersAfterReopeningTheWorkspace() async throws {
    try await withDocumentSearchFixture { fixture in
      let original = searchNote(id: "reopened", tags: ["Old"], type: "research", token: "PersistedSearchNeedle")
      try fixture.write(original, path: "notes/research/reopened.md")
      let snapshot = try await fixture.workspace.refresh()
      let document = try #require(snapshot.documents.first { $0.id == "reopened" })
      let edit = try await fixture.workspace.prepareMetadataEdit(relativePath: document.relativePath, expectedRevision: document.revision,
        title: "Updated Search Title", tags: ["Swift", "cafe\u{301}"], operationID: UUID())
      _ = try await fixture.workspace.execute(edit)
      await fixture.workspace.close()
      let reopened = try WikiWorkspace(root: fixture.root, localStateDirectory: fixture.state)
      do {
        let service = WikiSearchService(workspace: reopened, workspaceID: reopened.workspaceID)
        let page = try await service.searchPage("PersistedSearchNeedle",
          filter: .init(folder: "notes/research", tag: "CAFÉ", documentType: .named("research")), pageSize: 1)
        let hit = try #require(page.hits.first)
        #expect(page.totalCount == 1)
        #expect(page.nextCursor == nil)
        #expect(hit.reference.documentID == "reopened")
        #expect(hit.title == "Updated Search Title")
        #expect(try await reopened.read(hit.reference).contains("PersistedSearchNeedle"))
        #expect(try await service.searchPage("", filter: .init(tag: "Old"), pageSize: 100).hits.isEmpty)
        let exact = try await service.search("Updated Search Title", limit: 1, includeSystemSearch: false)
        #expect(exact.hits.first?.reference.documentID == "reopened")
        #expect(exact.hits.first?.provenance.contains(.exact) == true)
      } catch { await reopened.close(); throw error }
      await reopened.close()
    }
  }

  @Test func legacySEMISearchKeepsExactPriorityAndCurrentEvidenceWithSemanticCandidates() async throws {
    try await withDocumentSearchFixture { fixture in
      try fixture.write("---\nid: exact\naliases: [\"Café Plan\"]\n---\n# Exact current note\nOriginal exact content\n", path: "notes/exact.md")
      try fixture.write("---\nid: lexical\n---\n# Lexical current note\nCafe plan appears in this source.\n", path: "notes/lexical.md")
      try fixture.write("---\nid: semantic\n---\n# Semantic current note\nRelated source with different words.\n", path: "notes/semantic.md")
      let snapshot = try await fixture.workspace.refresh()
      let exact = try #require(snapshot.documents.first { $0.id == "exact" })
      let lexical = try #require(snapshot.documents.first { $0.id == "lexical" })
      let semantic = try #require(snapshot.documents.first { $0.id == "semantic" })
      let semanticID = try #require(semantic.sections.first?.id)
      let lexicalID = try #require(lexical.sections.first?.id)
      let service = WikiSearchService(workspace: fixture.workspace, workspaceID: fixture.workspace.workspaceID,
        semanticSearch: { _, _ in [semanticID, semanticID, lexicalID, "fabricated-section"] },
        semanticState: { "testProviderReady" })

      // This remains the signature used by wiki.search in the SEMI provider.
      let result = try await service.search("cafe plan", limit: 3)
      #expect(result.hits.first?.reference.documentID == exact.id)
      #expect(result.hits.first?.provenance.contains(.exact) == true)
      #expect(Set(result.hits.map(\.reference.documentID)) == ["exact", "lexical", "semantic"])
      #expect(result.hits.count == 3)
      #expect(Set(result.hits.map(\.id)).count == result.hits.count)
      #expect(result.hits.map(\.fusedRank) == [1, 2, 3])
      #expect(result.hits.first { $0.reference.documentID == "semantic" }?.provenance.contains(.semantic) == true)
      #expect(result.semanticState == "testProviderReady")
      #expect(result.coverageComplete)
      for hit in result.hits {
        let document = try #require(snapshot.documents.first { $0.id == hit.reference.documentID })
        #expect(hit.reference.sourceRevision == document.revision)
        #expect(try await fixture.workspace.read(hit.reference) == document.sections.first { $0.id == hit.id }?.sourceText)
      }
      let decoded = try JSONDecoder().decode(WikiSearchResult.self, from: JSONEncoder().encode(result))
      #expect(decoded.hits.map(\.id) == result.hits.map(\.id))
      #expect(decoded.semanticState == result.semanticState)

      let local = try await service.search("cafe plan", limit: 3, includeSystemSearch: false)
      #expect(local.hits.first?.reference.documentID == "exact")
      #expect(!local.hits.contains { $0.reference.documentID == "semantic" })
      #expect(local.semanticState == "local")
      #expect(local.hits.allSatisfy { !$0.provenance.contains(.semantic) && !$0.provenance.contains(.spotlight) })
      _ = try await service.search("cafe OR \"plan\" NEAR(*)", limit: 3, includeSystemSearch: false)
    }
  }

  @Test func legacySEMISearchStillReturnsLocalEvidenceWhenTheSelectedProviderFails() async throws {
    try await withDocumentSearchFixture { fixture in
      try fixture.write(searchNote(id: "local-fallback", token: "FallbackNeedle"), path: "notes/fallback.md")
      let service = WikiSearchService(workspace: fixture.workspace, workspaceID: fixture.workspace.workspaceID,
        semanticSearch: { _, _ in throw WikiError.unavailable("Fixture provider unavailable") })
      let result = try await service.search("FallbackNeedle", limit: 1)
      let hit = try #require(result.hits.first)
      #expect(hit.reference.documentID == "local-fallback")
      #expect(hit.provenance.contains(.fts))
      #expect(result.coverageComplete)
      #expect(result.semanticState.hasPrefix("degraded:"))
      #expect(try await fixture.workspace.read(hit.reference).contains("FallbackNeedle"))
    }
  }
}

private func withDocumentSearchFixture(_ operation: (DocumentSearchFixture) async throws -> Void) async throws {
  let fixture = try DocumentSearchFixture()
  do { try await operation(fixture) }
  catch { await fixture.workspace.close(); fixture.cleanup(); throw error }
  await fixture.workspace.close()
  fixture.cleanup()
}

private func documentSearchPages(_ service: WikiSearchService, query: String,
  filter: WikiDocumentFilter = .init(), pageSize: Int
) async throws -> [WikiSearchPage] {
  var pages: [WikiSearchPage] = []
  var cursor: WikiSearchCursor?
  repeat {
    let page = try await service.searchPage(query, filter: filter, cursor: cursor, pageSize: pageSize)
    pages.append(page)
    // A repeated or empty continuation must fail instead of hanging the suite.
    try #require(pages.count <= 20)
    if page.nextCursor != nil { try #require(!page.hits.isEmpty) }
    cursor = page.nextCursor
  } while cursor != nil
  return pages
}

private func expectInvalidDocumentSearchRequest(_ operation: () async throws -> WikiSearchPage) async {
  do {
    _ = try await operation()
    Issue.record("An invalid search request was accepted.")
  } catch {
    if case WikiError.invalidSource = error { return }
    Issue.record("Expected WikiError.invalidSource, received \(error).")
  }
}

private func searchNote(id: String, tags: [String] = [], type: String? = nil, token: String = "Browse body") -> String {
  let values = tags.map { "\"\($0)\"" }.joined(separator: ", ")
  let typeLine = type.map { "type: \($0)\n" } ?? ""
  return "---\nid: \(id)\ntags: [\(values)]\n\(typeLine)---\n# Note \(id)\n\(token)\n"
}

private func searchSectionNote(id: String, count: Int, token: String) -> String {
  "---\nid: \(id)\n---\n" + (0..<count).map { "# Section \($0)\n\(token) source \($0)\n\n" }.joined()
}

private struct DocumentSearchFixture: Sendable {
  let base: URL
  let state: URL
  let workspace: WikiWorkspace
  var root: URL { workspace.root }

  init() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioDocumentSearch-" + UUID().uuidString, isDirectory: true)
    let root = base.appendingPathComponent("Source", isDirectory: true)
    state = base.appendingPathComponent("DerivedState", isDirectory: true)
    try WikiWorkspace.create(at: root, name: "Isolated document search")
    workspace = try WikiWorkspace(root: root, localStateDirectory: state)
  }

  func write(_ text: String, path: String) throws {
    let destination = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: destination)
  }

  func localService() -> WikiSearchService {
    WikiSearchService(workspace: workspace, workspaceID: workspace.workspaceID)
  }

  func cleanup() { try? FileManager.default.removeItem(at: base) }
}
