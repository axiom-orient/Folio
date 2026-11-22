import Foundation
import FolioKnowledge
import Testing
@testable import FolioUI

@Suite struct FolioDocumentMergeTests {
  @Test func disjointChangesRetainEveryEditAcrossMultipleHunks() throws {
    let base = mergeSource("one\ntwo\nthree\nfour\nfive\nsix\n")
    let edited = mergeSource("one\nphone two\nthree\nfour\nfive\nphone six\n")
    let received = mergeSource("one\ntwo\nthree\nmac four\nfive\nsix\n")
    let plan = try #require(FolioDocumentMerge.plan(base: base, edited: edited, received: received))
    #expect(plan.conflicts.isEmpty)
    #expect(plan.automaticallyMergedSource == mergeSource("one\nphone two\nthree\nmac four\nfive\nphone six\n"))
  }

  @Test func identicalChangesMergeOnceWithoutLosingAdjacentIndependentChanges() throws {
    let base = mergeSource("north\nmiddle\nsouth\n")
    let edited = mergeSource("phone north\nshared middle\nsouth\n")
    let received = mergeSource("north\nshared middle\nmac south\n")
    let plan = try #require(FolioDocumentMerge.plan(base: base, edited: edited, received: received))
    #expect(plan.conflicts.isEmpty)
    #expect(plan.automaticallyMergedSource == mergeSource("phone north\nshared middle\nmac south\n"))
    let same = try #require(FolioDocumentMerge.plan(base: base, edited: edited, received: edited))
    #expect(same.automaticallyMergedSource == edited)
  }

  @Test func independentCompleteParagraphAppendsKeepReceivedThenEditedContent() throws {
    let base = mergeSource("# 에이전트 평가\n\n평가는 원문을 확인한다.\n")
    let phone = "\n다른 사람이 바꾼 내용과 내 편집을 함께 확인한다.\n"
    let mac = "\n삭제 후에는 복원한 내용도 대조한다.\n"
    let plan = try #require(FolioDocumentMerge.plan(base: base, edited: base + phone, received: base + mac))
    #expect(plan.conflicts.isEmpty)
    #expect(plan.automaticallyMergedSource == base + mac + phone)
    let duplicate = try #require(FolioDocumentMerge.plan(base: base, edited: base + phone, received: base + phone))
    #expect(duplicate.automaticallyMergedSource == base + phone)
  }

  @Test func choosingAnOverlappingLineKeepsBothSidesOtherChangesAndRequiresEveryChoice() throws {
    let base = mergeSource("before\nsame\nneighbor\nafter\n")
    let edited = mergeSource("before\nphone choice\nphone neighbor\nafter\n")
    let received = mergeSource("before\nmac choice\nneighbor\nmac outside\n")
    let plan = try #require(FolioDocumentMerge.plan(base: base, edited: edited, received: received))
    #expect(plan.automaticallyMergedSource == nil)
    let conflict = try #require(plan.conflicts.first)
    #expect(plan.conflicts.count == 1)
    #expect(conflict.base == "same\n")
    #expect(conflict.edited == "phone choice\n")
    #expect(conflict.received == "mac choice\n")
    #expect(!conflict.edited.contains("id:"))
    #expect(plan.resolvedSource(choices: [:]) == nil)
    #expect(plan.resolvedSource(choices: [conflict.id: .edited, 999: .received]) == nil)
    #expect(plan.resolvedSource(choices: [conflict.id: .edited])
      == mergeSource("before\nphone choice\nphone neighbor\nmac outside\n"))
    #expect(plan.resolvedSource(choices: [conflict.id: .received])
      == mergeSource("before\nmac choice\nphone neighbor\nmac outside\n"))
  }

  @Test func ambiguousAppendsAndDeletionAgainstModificationRequireContentChoices() throws {
    let bodies = [
      (base: "A", edited: "AB", received: "AC"),
      (base: "A\n", edited: "A\nB\n", received: "A\nC\n"),
      (base: "```swift\nlet a = 1\n", edited: "```swift\nlet a = 1\nlet b = 2\n", received: "```swift\nlet a = 1\nlet c = 3\n"),
      (base: "A\n", edited: "A\n\nB\n", received: "A\n\nB more\n"),
      (base: "A\n", edited: "A\n\np\n\nq\n", received: "A\n\nq\n\nr\n"),
      (base: "before\nremove or change\nafter\n", edited: "before\nafter\n", received: "before\nchanged\nafter\n"),
    ]
    for body in bodies {
      let plan = try #require(FolioDocumentMerge.plan(base: mergeSource(body.base),
        edited: mergeSource(body.edited), received: mergeSource(body.received)))
      #expect(plan.automaticallyMergedSource == nil)
      #expect(!plan.conflicts.isEmpty)
      #expect(plan.resolvedSource(choices: Dictionary(uniqueKeysWithValues:
        plan.conflicts.map { ($0.id, FolioDocumentMerge.Choice.received) })) != nil)
    }
  }

  @Test func metadataRemainsByteExactAndAmbiguousOrChangedIdentityFailsClosed() throws {
    let header = "\u{feff}---\r\nid: merge-note\r\ntags: [한글] # 유지\r\n---\r\n"
    let receivedHeader = header.replacingOccurrences(of: "[한글]", with: "[한글, AI]")
    let base = header + "첫 문장\r\n둘째 문장\r\n"
    let edited = header + "바꾼 첫 문장\r\n둘째 문장\r\n"
    let received = receivedHeader + "첫 문장\r\n받은 둘째 문장\r\n"
    let plan = try #require(FolioDocumentMerge.plan(base: base, edited: edited, received: received))
    let merged = try #require(plan.automaticallyMergedSource)
    #expect(merged.utf8.elementsEqual((receivedHeader + "바꾼 첫 문장\r\n받은 둘째 문장\r\n").utf8))
    let locallyChangedHeader = header.replacingOccurrences(of: "[한글]", with: "[local]")
    #expect(FolioDocumentMerge.plan(base: base, edited: locallyChangedHeader + "첫 문장\r\n둘째 문장\r\n", received: received) == nil)
    #expect(FolioDocumentMerge.plan(base: base, edited: edited,
      received: received.replacingOccurrences(of: "id: merge-note", with: "id: unrelated")) == nil)
    let damaged = "---\nid: [\n---\n문장\n"
    #expect(FolioDocumentMerge.plan(base: damaged, edited: damaged + "A\n", received: damaged + "B\n") == nil)

    let normalizedBase = mergeSource("\u{00e9}\nunchanged\n")
    let normalizedEdit = mergeSource("e\u{0301}\nunchanged\n")
    let normalizedRemote = mergeSource("\u{00e9}\nremote\n")
    let exact = try #require(FolioDocumentMerge.plan(base: normalizedBase, edited: normalizedEdit, received: normalizedRemote)?.automaticallyMergedSource)
    #expect(exact.utf8.elementsEqual(mergeSource("e\u{0301}\nremote\n").utf8))
    let oversized = String(repeating: "x", count: 256 * 1024 + 1)
    #expect(FolioDocumentMerge.plan(base: oversized, edited: oversized, received: oversized) == nil)
    let tooManyLines = String(repeating: "line\n", count: 4097)
    #expect(FolioDocumentMerge.plan(base: tooManyLines, edited: tooManyLines, received: tooManyLines) == nil)
  }

  @Test @MainActor func atomicRebaseRejectsNewTypingIncludingCanonicalUnicodeEqualityThenCheckpointsTheMergedBaseline() throws {
    let fixture = try mergeDraftFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let store = FolioDraftStore()
    defer { store.cancelPendingWrite() }
    try store.bind(fixture.repository)
    let original = mergeSource("Base\n")
    store.load(.init(path: "notes/merge.md", text: original, original: original, revision: SourceDigest.sha256(original)), id: "merge-note")
    store.edit(mergeSource("\u{00e9}\n"), id: "merge-note")
    let captured = try #require(store.drafts["merge-note"])
    store.edit(mergeSource("e\u{0301}\n"), id: "merge-note")
    let received = original + "\nReceived\n"
    let merged = received + "\nEdited\n"
    let rejected = try store.rebase(id: "merge-note", expected: captured, receivedSource: received, mergedSource: merged)
    #expect(!rejected)
    #expect(store.drafts["merge-note"]?.text.utf8.elementsEqual(mergeSource("e\u{0301}\n").utf8) == true)
    let current = try #require(store.drafts["merge-note"])
    let rebased = try store.rebase(id: "merge-note", expected: current, receivedSource: received, mergedSource: merged)
    #expect(rebased)
    let persisted = try #require(fixture.repository.load()["merge-note"])
    #expect(persisted.text == merged)
    #expect(persisted.original == received)
    #expect(persisted.revision == SourceDigest.sha256(received))
    store.completeSave(id: "merge-note", path: current.path, submittedText: merged, revision: SourceDigest.sha256(merged))
    #expect(store.drafts["merge-note"] == nil)
  }

  @Test @MainActor func failedCheckpointRollsBackOnlyTheRebasedDraftAndPreservesLastRecoveryFile() throws {
    let fixture = try mergeDraftFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let store = FolioDraftStore()
    defer { store.cancelPendingWrite() }
    try store.bind(fixture.repository)
    let original = mergeSource("Base\n")
    store.load(.init(path: "notes/merge.md", text: original, original: original, revision: SourceDigest.sha256(original)), id: "merge-note")
    store.edit(original + "\nPrivate edit\n", id: "merge-note")
    try store.checkpoint()
    let before = try Data(contentsOf: fixture.repository.url)
    let expected = try #require(store.drafts["merge-note"])
    store.load(.init(path: "notes/other.md", text: "Other", original: "Other", revision: SourceDigest.sha256("Other")), id: "other")
    store.edit(String(repeating: "x", count: FolioDraftRepository.maximumBytes + 1), id: "other")
    #expect(throws: WikiError.self) {
      try store.rebase(id: "merge-note", expected: expected, receivedSource: original + "\nReceived\n",
        mergedSource: original + "\nReceived\nPrivate edit\n")
    }
    #expect(store.drafts["merge-note"] == expected)
    #expect(store.drafts["other"]?.isDirty == true)
    #expect(try Data(contentsOf: fixture.repository.url) == before)
    let invalidBaseline = FolioDraft(path: expected.path, text: expected.text, original: expected.original, revision: "incorrect")
    store.load(invalidBaseline, id: "invalid")
    let rejected = try store.rebase(id: "invalid", expected: invalidBaseline, receivedSource: original, mergedSource: original)
    #expect(!rejected)
  }
}

private func mergeSource(_ body: String) -> String { "---\nid: merge-note\ntags: [ai-agent]\n---\n" + body }

private func mergeDraftFixture() throws -> (base: URL, repository: FolioDraftRepository) {
  let base = FileManager.default.temporaryDirectory.appending(path: "FolioMerge-" + UUID().uuidString, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  return (base, FolioDraftRepository(url: base.appending(path: "drafts.json")))
}
