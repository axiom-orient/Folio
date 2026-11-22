import XCTest
import CryptoKit

/// Native checks use existing research documents; cleanup stays within its exact owned-library whitelist.
/// Research trash and restore are separate phases so the Mac can observe each actual cloud effect.
@MainActor
final class FolioContentMaintenance: XCTestCase {
  private enum Research {
    static let library = "AI agent"
    static let target = CloudLibraryTarget(name: library, containerIdentifier: "iCloud.com.axient.Folio",
      workspaceID: UUID(uuidString: "8231965d-1c28-4d16-bfef-e2b381304cb9")!)
    static let title = "에이전트의 성공과 안전을 무엇으로 확인할까"
    static let path = "notes/agent-evaluation-and-safety.md"
    static let filename = "agent-evaluation-and-safety.md"
    static let id = "165b1955-4a01-48c7-826c-e1e6ee176773"
    static let otherTitles = ["AI agent는 무엇이고 언제 쓰는가", "AI 에이전트의 실행 경계: 도구, 승인, 중단과 재개"]
    static let titles = otherTitles + [title]
    static let section = "## 문서 변경을 평가할 때의 복구 기준"
    static let paragraphA = "도구가 문서를 바꾸는 평가에서는 원문을 읽은 시점의 버전과 저장 후 실제 내용을 함께 기록한다. 문서가 이미 바뀌어 있었다면 검증 중 새로 저장한 결과와 구분한다. 이는 이 문서의 평가 설계 제안이다."
    static let paragraphB = "다른 작업자가 같은 원문을 바꿨다면 도구는 예전 내용을 그대로 덮어쓰지 말고, 제안한 편집을 보존한 채 새 원문을 검토하도록 해야 한다. 복구를 통과했다고 판단하려면 두 변경이 모두 남았는지 원문으로 확인한다."
    static let paragraphC = "삭제 도구의 평가에서는 목록에서 사라졌다는 사실과 복원 가능한 원문이 남았다는 사실을 따로 확인한다. 복원 뒤에는 제목뿐 아니라 문서 식별자와 내용이 삭제 전과 같은지도 대조한다."
    // Captured from the actual Mac editor and the actual iPhone source-info
    // pane before the failed, unsaved insertion. These admit only that repair.
    // Actual UITextView value observed in v4 includes the source's terminal LF;
    // the Mac AX text serialization omitted that final LF.
    static let baselineBodySHA256 = "599871aa874811398f16a6d97617b686a8b9968de920ad4891659ae2d5fc6664"
    static let baselineSourceSHA256 = "9094ee2c07a6a9b4a71442ad957c5f6d6b733167884e757aca096d7960c37d74"
    // Expected bytes for this scenario, derived from the retained A source and
    // the two exact additions. These are admission checks, not run evidence.
    static let sourceA = "58705aa23702bd4b08b184f480d7e6ffc4357d44cececbda28934440ba79b12e"
    static let bodyA = "356429927f7a9f00be40a5c333215c83507d42be7e2167e829f8bf5e2eb950fc"
    static let bodyB = "6ddc8879d7e56984ed593875852e9d1af8d6e1a45a18cb9cc5aa238b238b4ff5"
    static let sourceC = "560c9c0988bcbb20ab7c1a9218bd69ebfab91527a1cb9378d360d57a1ccaf4fa"
    static let mergedSource = "d786d9ce6ea11947bd41eca65091bb2e58ff08e66e6240893d6e344875eec75c"
    static let mergedBody = "ca338a7ea9cde9aa08149c41fe3a6bf1dfc6b5b2a1401bca7dfb226717b7cb8f"
  }

  private struct OwnedLibrary: Equatable {
    let name: String
    let storage: String
    let accessibilityIdentifier: String?
  }

  private let ownedLibraries: [OwnedLibrary] = [
    .init(name: "Folio iCloud 검증 20261022-A", storage: "iCloud",
      accessibilityIdentifier: CloudLibraryTarget(name: "Folio iCloud 검증 20261022-A",
        containerIdentifier: "iCloud.com.axient.Folio", workspaceID: UUID(uuidString: "0aad1085-a55f-4571-bf32-d96df65cc2a8")!).accessibilityIdentifier),
    .init(name: "Folio iCloud 검증 20261022-A", storage: "이 기기", accessibilityIdentifier: nil),
    .init(name: "Folio 실기기 검증 20261013", storage: "iCloud", accessibilityIdentifier: nil),
    .init(name: "Folio 실기기 검증 20261013", storage: "이 기기", accessibilityIdentifier: nil),
    .init(name: "Folio 수신 검증 iPhone 20261013", storage: "이 기기", accessibilityIdentifier: nil),
    .init(name: "File transfer demo", storage: "이 기기", accessibilityIdentifier: nil),
  ]

  func testCleanupOwnedVerificationDocuments() throws {
    continueAfterFailure = false
    let identities = ownedLibraries.compactMap(\.accessibilityIdentifier)
    guard identities.count == ownedLibraries.count, Set(identities).count == ownedLibraries.count else {
      throw XCTSkip("Cleanup is unavailable: every library needs a separately verified unique location identity before any library or document is changed.")
    }
    let app = XCUIApplication(bundleIdentifier: "com.axient.Folio")
    app.launch()
    defer { capture(app, "maintenance-final-state") }
    var emptied: [OwnedLibrary] = []
    for library in ownedLibraries {
      try openLibraryPicker(in: app)
      try hideEmptiedLibraries(emptied, in: app)
      try expandHiddenLibraries(in: app)
      let choice = try ownedLibraryChoice(library, in: app)
      guard findOnscreen(choice, in: app, maximumSwipes: 12, libraryPickerOnly: true) else {
        capture(app, "maintenance-owned-library-not-found-" + library.name + "-" + library.storage)
        print("FOLIO_MAINTENANCE_NOT_FOUND \(library.name) [\(library.storage)]")
        try tap("닫기", in: app)
        continue
      }
      guard ownedLibraries.contains(library) else { throw blocked("Library is outside the exact maintenance whitelist.", in: app) }
      guard matchesOwnedLibrary(choice, library: library, in: app) else { throw blocked("The cleanup library identity does not match.", in: app) }
      try selectLibrary(choice, name: library.name, in: app)
      try requireSelectedOwnedLibrary(library, in: app)
      let removed = try trashOwnedDocuments(library: library, in: app)
      emptied.append(library)
      print("FOLIO_MAINTENANCE_EMPTY \(library.name) [\(library.storage)] trashed=\(removed)")
    }
    try openLibraryPicker(in: app)
    let retainedResearch = app.buttons.matching(identifier: Research.target.accessibilityIdentifier).firstMatch
    if findOnscreen(retainedResearch, in: app, maximumSwipes: 12, libraryPickerOnly: true) {
      guard app.buttons.matching(identifier: Research.target.accessibilityIdentifier).count == 1,
        retainedResearch.label == Research.library,
        (retainedResearch.value as? String)?.contains("iCloud") == true else {
        throw blocked("The retained research library identity does not match.", in: app)
      }
      try selectLibrary(retainedResearch, name: Research.library, in: app)
      try requireSelectedCloudLibrary(Research.target, in: app)
      print("FOLIO_MAINTENANCE_RETAINED_LIBRARY_SELECTED AI agent [iCloud]")
      try openLibraryPicker(in: app)
    } else {
      print("FOLIO_MAINTENANCE_RETAINED_LIBRARY_UNAVAILABLE AI agent [iCloud]")
    }
    try hideEmptiedLibraries(emptied, in: app)
    capture(app, "maintenance-empty-verification-libraries-hidden-where-available")
    try tap("닫기", in: app)
  }

  func testReadAIAgentResearch() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "com.axient.Folio")
    app.launch()
    defer { capture(app, "ai-agent-reader-final-state") }
    let libraryName = "AI agent"
    let overviewTitle = "AI agent는 무엇이고 언제 쓰는가"
    try home(app)
    try selectCloudLibrary(Research.target, in: app)
    try requireSelectedCloudLibrary(Research.target, in: app)
    openDocumentFilters(in: app)
    let browseClose = app.navigationBars["찾아보기"].buttons["닫기"].firstMatch
    try require(browseClose, in: app, stage: "native-browse-explicit-cancel")
    guard browseClose.isHittable else { throw blocked("The browse sheet has no reachable cancel action.", in: app) }
    capture(app, "ai-agent-direct-browse-with-visible-cancel")
    browseClose.tap()
    try gone(app.navigationBars["찾아보기"].firstMatch, in: app, stage: "browse-cancel-returns-to-current-library")
    try requireUnfilteredDocumentScope(in: app, libraryName: libraryName)
    let row = homeCollection(in: app).cells.buttons.matching(NSPredicate(format: "label == %@", overviewTitle)).firstMatch
    guard findOnscreen(row, in: app, maximumSwipes: 12) else { throw blocked("The AI agent overview document is not available.", in: app) }
    row.tap()
    try require(app.buttons["문서 옵션"].firstMatch, in: app, stage: "ai-agent-overview-reader")
    try require(app.staticTexts[overviewTitle].firstMatch, in: app, stage: "ai-agent-overview-title")
    let definition = "AI 에이전트는 목표를 받아 도구를 사용하고, 실행 결과를 관찰해 다음 행동을 고르는 시스템이다."
    let paragraph = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", definition)).firstMatch
    guard findOnscreen(paragraph, in: app, maximumSwipes: 12) else { throw blocked("The researched agent definition is not rendered in the reader.", in: app) }
    capture(app, "ai-agent-researched-definition-read-on-physical-phone")
    let comparison = ["주어진 문서 한 편 요약", "단일 모델 호출과 원문 대조", "추가 행동을 선택할 필요가 적음"]
    let lastCell = app.staticTexts[comparison[2]].firstMatch
    guard findOnscreen(lastCell, in: app, maximumSwipes: 12) else {
      throw blocked("The original comparison table is not readable on this iPhone.", in: app)
    }
    for value in comparison {
      let cell = app.staticTexts[value].firstMatch
      try require(cell, in: app, stage: "original-table-value-" + value)
      guard cell.isHittable, !cell.frame.isEmpty,
        cell.frame.minX >= app.frame.minX, cell.frame.maxX <= app.frame.maxX else {
        throw blocked("An original table value is clipped horizontally or outside the reading area: " + value, in: app)
      }
    }
    capture(app, "ai-agent-original-comparison-table-readable-without-horizontal-scroll")
    let heading = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "도구·MCP·스킬·메모리는 각각 무엇인가")).firstMatch
    guard findOnscreen(heading, in: app, maximumSwipes: 12) else { throw blocked("The researched tools/MCP/skills/memory section is not rendered.", in: app) }
    capture(app, "ai-agent-meaningful-overview-read-on-physical-phone")
    print("FOLIO_AI_AGENT_RESEARCH_READ \(overviewTitle)")
  }

  func testExistingAIAgentListSearchBodyAndMetadataSave() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "com.axient.Folio")
    app.launch()
    defer { capture(app, "ai-agent-existing-documents-flow-final-state") }
    let libraryName = "AI agent"
    let overview = "AI agent는 무엇이고 언제 쓰는가"
    let evaluation = "에이전트의 성공과 안전을 무엇으로 확인할까"
    let section = "도구·MCP·스킬·메모리는 각각 무엇인가"
    let titles = [overview, "AI 에이전트의 실행 경계: 도구, 승인, 중단과 재개", evaluation]
    try home(app)
    try selectCloudLibrary(Research.target, in: app)
    try requireSelectedCloudLibrary(Research.target, in: app)
    try resetDocumentFilters(in: app, libraryName: libraryName)
    try requireResearchTitles(titles, in: app)
    capture(app, "ai-agent-three-existing-documents-and-library-picker")
    openDocumentFilters(in: app)
    try selectBrowseChoice("문서", in: app)
    let folderScope = app.staticTexts["document-list-scope"].firstMatch
    try require(folderScope, in: app, stage: "actual-existing-notes-folder-scope")
    guard folderScope.label.contains("문서") else { throw blocked("The selected existing document folder is not reported by the list.", in: app) }
    let selectedFolderScope = folderScope.label
    try requireResearchTitles(titles, in: app)
    capture(app, "ai-agent-browse-existing-notes-folder-without-creating-folders")

    let search = documentSearchInput(in: app)
    try require(search, in: app, stage: "always-visible-native-search")
    guard search.isHittable else { throw blocked("Native search is not visible on the document list.", in: app) }
    search.tap(); search.typeText("MCP")
    try require(app.staticTexts["search-result-count"].firstMatch, in: app, stage: "actual-MCP-search-results")
    let hitPredicate = NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", overview, section)
    let hit = homeCollection(in: app).cells.buttons.matching(hitPredicate).firstMatch
    try require(hit, in: app, stage: "overview-MCP-section-search-hit")
    guard findOnscreen(hit, in: app, maximumSwipes: 8) else { throw blocked("The relevant MCP result could not be made visible.", in: app) }
    capture(app, "ai-agent-MCP-query-keyboard-and-meaningful-results")
    hit.tap()
    try require(app.buttons["문서 옵션"].firstMatch, in: app, stage: "searched-original-reader")
    let heading = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", section)).firstMatch
    guard findOnscreen(heading, in: app, maximumSwipes: 8) else { throw blocked("The searched source section is not rendered.", in: app) }
    let explanation = "MCP는 AI 애플리케이션을 외부 데이터·도구·워크플로에 연결하는 공개 프로토콜이다."
    let paragraph = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", explanation)).firstMatch
    guard findOnscreen(paragraph, in: app, maximumSwipes: 4) else { throw blocked("The actual MCP explanation is not rendered.", in: app) }
    capture(app, "ai-agent-search-opens-the-relevant-original-section")
    try home(app)
    guard search.value as? String == "MCP" else { throw blocked("Reader Back lost the original search query.", in: app) }
    try require(homeCollection(in: app).cells.buttons.matching(hitPredicate).firstMatch,
      in: app, stage: "same-MCP-results-after-back")
    capture(app, "ai-agent-reader-back-preserves-query-and-results")
    try clearNativeSearch(search, preservingScope: selectedFolderScope, expectedTitles: titles, in: app)
    try requireResearchTitles(titles, in: app)

    let evaluationRow = homeCollection(in: app).cells.buttons.matching(NSPredicate(format: "label == %@", evaluation)).firstMatch
    guard findOnscreen(evaluationRow, in: app, maximumSwipes: 8) else { throw blocked("The existing evaluation document is not visible.", in: app) }
    evaluationRow.tap()
    try require(app.buttons["document-edit"].firstMatch, in: app, stage: "existing-evaluation-reader")
    guard app.buttons["document-edit"].firstMatch.label == "편집" else { throw blocked("An existing evaluation draft needs review before this edit.", in: app) }
    try tap("document-edit", in: app)
    let editor = app.textViews["document-editor"].firstMatch
    try require(editor, in: app, stage: "native-body-editor")
    let editorTitle = app.staticTexts["editor-document-title"].firstMatch
    try require(editorTitle, in: app, stage: "native-editor-full-document-title")
    guard editorTitle.label == evaluation else {
      throw blocked("The editor must identify the existing evaluation document with its full title.", in: app)
    }
    let body = try XCTUnwrap(editor.value as? String)
    guard body.contains("에이전트 평가는 답변이 그럴듯한지"), !body.hasPrefix("---"),
      !body.contains("id: 165b1955-4a01-48c7-826c-e1e6ee176773") else {
      throw blocked("The default editor must show this document's research body with YAML metadata hidden.", in: app)
    }
    editor.tap()
    try require(app.keyboards.firstMatch, in: app, stage: "actual-body-editing-keyboard")
    capture(app, "ai-agent-existing-body-editor-and-native-keyboard")
    let followup = "실행 중 승인과 재시도를 어떻게 나눌지는 [도구·승인·중단과 재개](agent-design-and-operation.md)에서 이어 읽을 수 있다."
    if !body.contains(followup) {
      let addition = (body.utf8.last == 10 ? "\n" : "\n\n") + followup + "\n"
      try replaceLiveResearchText(body + addition, in: editor, expectedText: body, app: app)
      capture(app, "ai-agent-useful-followup-paragraph-before-explicit-save")
      try tap("document-save", in: app)
      try gone(editor, in: app, stage: "body-save-returned-to-reader")
      print("FOLIO_AI_AGENT_BODY_COMMIT \(evaluation)")
    } else {
      print("FOLIO_AI_AGENT_BODY_ALREADY_PRESENT \(evaluation)")
      let save = app.buttons["document-save"].firstMatch
      guard !save.isEnabled, editor.value as? String == body else { throw blocked("An unexpected body draft was preserved.", in: app) }
      let back = app.navigationBars.buttons.element(boundBy: 0)
      try require(back, in: app, stage: "unchanged-editor-native-back")
      back.tap()
      try requireCurrentLibrary(libraryName, in: app)
      let unchanged = homeCollection(in: app).cells.buttons.matching(NSPredicate(format: "label == %@", evaluation)).firstMatch
      guard findOnscreen(unchanged, in: app, maximumSwipes: 8) else { throw blocked("The unchanged evaluation document is not visible.", in: app) }
      unchanged.tap()
    }
    let savedFollowup = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "실행 중 승인과 재시도를 어떻게 나눌지는")).firstMatch
    guard findOnscreen(savedFollowup, in: app, maximumSwipes: 14) else { throw blocked("The saved followup paragraph is not visible in the original reader.", in: app) }
    capture(app, "ai-agent-useful-body-edit-saved-as-original")

    try tap("문서 옵션", in: app); try tap("제목·태그 편집…", in: app)
    let titleField = app.textFields["metadata-title"].firstMatch
    try require(titleField, in: app, stage: "evaluation-title-and-tags-form")
    guard titleField.value as? String == evaluation else { throw blocked("Metadata editing targeted a different document.", in: app) }
    let commonTag = app.buttons["ai-agent 태그 제거"].firstMatch
    if !commonTag.exists {
      let tagField = app.textFields["metadata-new-tag"].firstMatch
      guard findOnscreen(tagField, in: app, maximumSwipes: 6) else { throw blocked("The new-tag field is not visible.", in: app) }
      tagField.tap(); tagField.typeText("ai-agent")
      try require(app.keyboards.firstMatch, in: app, stage: "actual-metadata-editing-keyboard")
      capture(app, "ai-agent-common-tag-quality-fix-before-explicit-save")
      try tap("metadata-save", in: app)
      try gone(titleField, in: app, stage: "metadata-explicit-save-returned-to-reader")
      print("FOLIO_AI_AGENT_METADATA_COMMIT \(evaluation) ai-agent")
    } else {
      capture(app, "ai-agent-common-tag-already-present")
      print("FOLIO_AI_AGENT_METADATA_ALREADY_PRESENT \(evaluation) ai-agent")
      try tap("취소", in: app)
    }
    try tap("문서 옵션", in: app); try tap("문서 정보", in: app)
    let tags = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ai-agent")).firstMatch
    try require(tags, in: app, stage: "saved-common-research-tag")
    for originalTag in ["평가", "안전성", "프롬프트 주입"] {
      try require(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", originalTag)).firstMatch,
        in: app, stage: "preserved-tag-" + originalTag)
    }
    capture(app, "ai-agent-saved-metadata-preserves-the-existing-research-tags")
    try tap("닫기", in: app)
    try home(app)
    try requireResearchTitles(titles, in: app)
    openDocumentFilters(in: app)
    try selectBrowseChoice("ai-agent", in: app)
    let scope = app.staticTexts["document-list-scope"].firstMatch
    try require(scope, in: app, stage: "actual-selected-tag-scope")
    guard scope.label.contains("ai-agent") else { throw blocked("The list did not report the selected research tag.", in: app) }
    try requireResearchTitles(titles, in: app)
    capture(app, "ai-agent-all-three-existing-documents-share-the-research-tag")
    try tap("document-filter-reset", in: app)
    try requireUnfilteredDocumentScope(in: app, libraryName: libraryName)
    try requireResearchTitles(titles, in: app)
    capture(app, "ai-agent-list-after-search-body-and-metadata-save")
    print("FOLIO_AI_AGENT_EXISTING_FLOW_VERIFIED three-existing-documents")
  }

  func testExistingResearchCommitAndConcurrentRecovery() throws {
    continueAfterFailure = false
    let app = try launchLiveResearch(expectedTitles: Research.titles, allowPreservedDraft: true)
    defer { capture(app, "live-research-concurrent-final-state") }
    try openLiveResearch(in: app, allowPreservedDraft: true)
    let hasPreservedDraft = app.buttons["document-edit"].firstMatch.label == "편집 이어쓰기"
    let observedRevision = try liveResearchRevision(in: app, stage: "before-real-phone-edit")
    var editor = try beginLiveResearchEdit(in: app, allowPreservedDraft: true)
    var original = try XCTUnwrap(editor.value as? String)
    captureLiveResearchText(editor, name: "live-research-full-private-body-before-any-correction")
    captureLiveResearchText(editor, name: "live-research-observed-private-body-before-admission")
    guard !original.contains(Research.paragraphB), !original.contains(Research.paragraphC) else {
      throw blocked("Concurrent research additions already exist; no fresh conflict can be claimed.", in: app)
    }
    if hasPreservedDraft {
      let addition = "\n" + Research.section + "\n\n" + Research.paragraphA + "\n"
      let parts = original.components(separatedBy: addition)
      guard parts.count == 2, observedRevision == Research.baselineSourceSHA256 else {
        throw blocked("Only the single known unsaved research insertion against its unchanged saved source may be repaired.", in: app)
      }
      let baseline = parts.joined()
      let digest = liveResearchDigest(baseline)
      print("FOLIO_LIVE_PRIVATE_BASELINE_OBSERVED bodySHA256=\(digest) characters=\(baseline.count) utf8Bytes=\(baseline.utf8.count) terminalScalars=\(baseline.unicodeScalars.suffix(4).map(\.value)) sourceRevision=\(observedRevision)")
      guard digest == Research.baselineBodySHA256 else {
        throw blocked("Removing the one known insertion does not exactly restore the actual captured Mac baseline; the private draft was kept.", in: app)
      }
      capture(app, "live-research-private-insertion-matches-captured-baseline-before-repair")
      try replaceLiveResearchText(baseline, in: editor, expectedText: original, app: app)
      let clean = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: app.buttons["document-save"].firstMatch)
      guard XCTWaiter.wait(for: [clean], timeout: 10) == .completed else {
        throw blocked("The repaired private text still differs from its saved original; no source write was attempted.", in: app)
      }
      original = baseline
      capture(app, "live-research-private-insertion-repaired-without-source-write")
      print("FOLIO_LIVE_PRIVATE_DRAFT_REPAIRED bodySHA256=\(digest) sourceRevision=\(observedRevision)")
    }
    if !original.contains(Research.paragraphA) {
      guard observedRevision == Research.baselineSourceSHA256,
        liveResearchDigest(original) == Research.baselineBodySHA256 else {
        throw blocked("The source or native body is not the exact captured baseline; no source write was attempted.", in: app)
      }
      let addition = "\n" + Research.section + "\n\n" + Research.paragraphA + "\n"
      try appendLiveResearch(addition, to: editor, expectedBody: original, in: app)
      capture(app, "live-research-useful-new-phone-paragraph-before-save")
      try liveTap("document-save", in: app)
      try gone(editor, in: app, stage: "live-research-explicit-phone-save-reader")
      try requireLiveResearchReader(in: app)
      try requireLiveResearchParagraphs([Research.paragraphA], in: app)
      capture(app, "live-research-new-phone-save-confirmed-in-reader")
      print("FOLIO_LIVE_PHONE_SAVED_RESEARCH \(Research.path)")
    } else {
      guard observedRevision == Research.sourceA, liveResearchDigest(original) == Research.bodyA,
        original.contains(Research.section) else {
        throw blocked("The existing research addition is not the exact saved A source and body.", in: app)
      }
      try previewLiveResearch(in: app)
      print("FOLIO_LIVE_PHONE_SAVE_RESUMED_ALREADY_PRESENT \(Research.path)")
    }
    let baselineRevision = try liveResearchRevision(in: app, stage: "saved-phone-baseline")
    guard baselineRevision == Research.sourceA else {
      throw blocked("The saved baseline is not the exact expected A source.", in: app)
    }
    editor = try beginLiveResearchEdit(in: app)
    let baseline = try XCTUnwrap(editor.value as? String)
    guard liveResearchDigest(baseline) == Research.bodyA, baseline.contains(Research.paragraphA),
      !baseline.contains(Research.paragraphB), !baseline.contains(Research.paragraphC) else {
      throw blocked("The concurrent draft must start from the newly saved phone research only.", in: app)
    }
    let phoneAddition = "\n" + Research.paragraphB + "\n"
    try appendLiveResearch(phoneAddition, to: editor, expectedBody: baseline, in: app)
    let preservedBody = baseline + phoneAddition
    capture(app, "live-research-phone-private-draft-awaiting-mac-commit")
    print("FOLIO_LIVE_PHONE_DRAFT_READY \(Research.path) revision=\(baselineRevision) expectedMacRevision=\(Research.sourceC)")
    print("FOLIO_LIVE_MAC_APPEND 빈 줄 뒤 다음 문단과 마지막 줄바꿈만 추가하고 저장: \(Research.paragraphC). 이후 다른 편집을 중지하세요.")
    let stale = app.staticTexts["새 변경을 받았습니다. 저장할 때 함께 확인합니다."].firstMatch
    try require(stale, in: app, timeout: 180, stage: "live-mac-source-change-keeps-phone-draft")
    guard editor.value as? String == preservedBody else {
      throw blocked("Receiving the Mac source changed the private phone draft.", in: app)
    }
    capture(app, "live-research-mac-change-received-with-phone-draft-preserved")

    // Verify the exact remote source and its unchanged identity before Save can
    // automatically commit the merge. Preview leaves the private B draft intact.
    try previewLiveResearch(in: app, allowPreservedDraft: true)
    try requireLiveResearchParagraphs([Research.paragraphA, Research.paragraphC], in: app)
    guard try liveResearchRevision(in: app, stage: "reviewed-exact-mac-C") == Research.sourceC else {
      throw blocked("The current source is not the exact expected A+C; the phone draft was preserved.", in: app)
    }
    editor = try beginLiveResearchEdit(in: app, allowPreservedDraft: true)
    guard editor.value as? String == preservedBody,
      liveResearchDigest(preservedBody) == Research.bodyB else {
      throw blocked("The exact A+B private body was not retained before automatic merge.", in: app)
    }
    try liveInputReady(in: app)
    try liveTap("document-save", in: app)
    // This scenario admits independent appends only. A conflict choice or a
    // recovery form is not implicitly approved; stop with the draft intact.
    try gone(editor, in: app, stage: "live-independent-merge-saved-reader")
    try requireLiveResearchReader(in: app)
    try requireLiveResearchParagraphs([Research.paragraphA, Research.paragraphB, Research.paragraphC], in: app)
    let revision = try liveResearchRevision(in: app, stage: "automatically-merged-C-B")
    guard revision == Research.mergedSource else {
      throw blocked("The saved source does not match the exact expected A+C+B bytes.", in: app)
    }
    let mergedEditor = try beginLiveResearchEdit(in: app)
    guard let mergedBody = mergedEditor.value as? String, liveResearchDigest(mergedBody) == Research.mergedBody else {
      throw blocked("The saved body does not match the exact expected A+C+B bytes.", in: app)
    }
    try previewLiveResearch(in: app)
    capture(app, "live-research-both-device-edits-retained-in-saved-reader")
    print("FOLIO_LIVE_MERGED_REVISION \(revision)")
    print("FOLIO_LIVE_CONCURRENT_RECOVERED \(Research.path)")
  }

  func testExistingResearchTrash() throws {
    continueAfterFailure = false
    let app = try launchLiveResearch(expectedTitles: Research.titles)
    defer { capture(app, "live-research-trash-final-state") }
    try openLiveResearch(in: app)
    try requireLiveResearchParagraphs([Research.paragraphA, Research.paragraphB, Research.paragraphC], in: app)
    let revision = try liveResearchRevision(in: app, stage: "before-recoverable-research-trash")
    guard revision == Research.mergedSource else {
      throw blocked("The research source is not the exact verified A+C+B result; it was not moved to trash.", in: app)
    }
    print("FOLIO_LIVE_PRE_TRASH_REVISION \(revision)")
    try openLiveResearchTrash(in: app)
    guard liveResearchTrashRows(in: app).count == 0 else {
      throw blocked("A same-path trash record already exists; the research document was not deleted.", in: app)
    }
    try closeLiveResearchTrash(in: app)
    try openLiveResearch(in: app)
    guard try liveResearchRevision(in: app, stage: "trash-target-rechecked") == revision else {
      throw blocked("The research source changed before trash; it was kept.", in: app)
    }
    try refuseRecoveryOrDirtyDrafts(in: app)
    try liveTap("문서 옵션", in: app)
    try liveTap("휴지통으로 이동…", in: app)
    try require(app.navigationBars["휴지통으로 이동"].firstMatch, in: app, stage: "live-exact-research-trash-confirmation")
    try require(app.staticTexts[Research.filename].firstMatch, in: app, stage: "live-exact-research-trash-target")
    try require(app.staticTexts["휴지통에서 다시 복원할 수 있습니다."].firstMatch, in: app, stage: "live-research-recoverable-trash-only")
    capture(app, "live-research-exact-original-recoverable-trash-confirmation")
    try liveTap("file-action-submit", in: app)
    try gone(app.buttons["file-action-submit"].firstMatch, in: app, stage: "live-research-soft-trash-completed")
    try home(app)
    try requireCurrentLibrary(Research.library, in: app)
    try requireResearchTitles(Research.otherTitles, in: app)
    try gone(homeCollection(in: app).cells.buttons.matching(NSPredicate(format: "label == %@", Research.title)).firstMatch,
      in: app, stage: "live-only-target-research-left-list")
    capture(app, "live-research-soft-trash-leaves-other-two-documents")
    try openLiveResearchTrash(in: app)
    let row = try uniqueLiveResearchTrashRow(in: app)
    let restore = row.buttons["복원"].firstMatch
    try require(restore, in: app, stage: "live-trashed-original-has-recovery-action")
    guard restore.isEnabled else { throw blocked("The trashed research payload is not ready for recovery.", in: app) }
    capture(app, "live-research-original-present-in-recoverable-trash")
    print("FOLIO_LIVE_TRASHED \(Research.path) revision=\(revision)")
  }

  func testExistingResearchRestore() throws {
    continueAfterFailure = false
    let app = try launchLiveResearch(expectedTitles: Research.otherTitles)
    defer { capture(app, "live-research-restore-final-state") }
    try gone(homeCollection(in: app).cells.buttons.matching(NSPredicate(format: "label == %@", Research.title)).firstMatch,
      in: app, stage: "live-restore-target-is-absent-before-restore")
    try openLiveResearchTrash(in: app)
    let row = try uniqueLiveResearchTrashRow(in: app)
    let restore = row.buttons["복원"].firstMatch
    try livePress(restore, stage: "restore-only-the-existing-research-row", in: app)
    try require(app.navigationBars["복원"].firstMatch, in: app, stage: "live-research-restore-confirmation")
    try require(app.staticTexts[Research.filename].firstMatch, in: app, stage: "live-exact-research-restore-target")
    try require(app.staticTexts["원래 폴더로 복원합니다."].firstMatch, in: app, stage: "live-restore-original-path-policy")
    capture(app, "live-research-restore-exact-original-confirmation")
    try liveTap("file-action-submit", in: app)
    try gone(app.buttons["file-action-submit"].firstMatch, in: app, stage: "live-research-restore-committed")
    try gone(liveResearchTrashRows(in: app).firstMatch, in: app, stage: "live-restored-research-left-trash")
    capture(app, "live-research-restored-original-left-trash")
    try closeLiveResearchTrash(in: app)
    try requireResearchTitles(Research.titles, in: app)
    try openLiveResearch(in: app)
    try requireLiveResearchParagraphs([Research.paragraphA, Research.paragraphB, Research.paragraphC], in: app)
    let revision = try liveResearchRevision(in: app, stage: "restored-research-body-tags-path-and-version")
    guard revision == Research.mergedSource else {
      throw blocked("The restored source does not match the exact pre-trash A+C+B revision.", in: app)
    }
    capture(app, "live-research-restored-saved-reader-with-both-device-edits")
    print("FOLIO_LIVE_RESTORED_REVISION \(revision)")
    print("FOLIO_LIVE_RESTORED \(Research.path)")
  }

  private func launchLiveResearch(expectedTitles: [String], allowPreservedDraft: Bool = false) throws -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.axient.Folio")
    app.launch()
    try liveInputReady(in: app)
    try home(app)
    try liveInputReady(in: app)
    try selectCloudLibrary(Research.target, in: app)
    try requireSelectedCloudLibrary(Research.target, in: app)
    try resetDocumentFilters(in: app, libraryName: Research.library)
    try requireResearchTitles(expectedTitles, in: app)
    if allowPreservedDraft {
      let dirty = homeCollection(in: app).cells.buttons.allElementsBoundByIndex.filter {
        ($0.value as? String)?.contains("저장하지 않은 편집") == true
      }
      guard dirty.count <= 1, dirty.allSatisfy({ $0.label == Research.title }) else {
        throw blocked("A private draft outside the one exact research target was preserved without interaction.", in: app)
      }
      for label in ["보존한 초안", "이어서 편집", "확인이 필요한 자료", "첨부 연결 확인", "원문 다운로드 중…", "문서를 받는 중…"] {
        guard !app.staticTexts[label].firstMatch.exists else { throw blocked("Unresolved research source state: " + label, in: app) }
      }
    } else { try refuseRecoveryOrDirtyDrafts(in: app) }
    return app
  }

  private func openLiveResearch(in app: XCUIApplication, allowPreservedDraft: Bool = false) throws {
    try home(app)
    try requireCurrentLibrary(Research.library, in: app)
    let rows = homeCollection(in: app).cells.buttons.matching(NSPredicate(format: "label == %@", Research.title))
    try require(rows.firstMatch, in: app, stage: "live-existing-evaluation-document")
    guard rows.count == 1, findOnscreen(rows.firstMatch, in: app, maximumSwipes: 8) else {
      throw blocked("The existing evaluation document is ambiguous or not visible.", in: app)
    }
    try livePress(rows.firstMatch, stage: "open-exact-existing-research", in: app)
    try requireLiveResearchReader(in: app, allowPreservedDraft: allowPreservedDraft)
  }

  private func requireLiveResearchReader(in app: XCUIApplication, allowPreservedDraft: Bool = false) throws {
    let edit = app.buttons["document-edit"].firstMatch
    try require(edit, in: app, stage: "live-saved-research-reader")
    guard edit.label == "편집" || (allowPreservedDraft && edit.label == "편집 이어쓰기"),
      !app.textViews.allElementsBoundByIndex.contains(where: \.isHittable) else {
      throw blocked("Expected this research document's saved reader without an unsaved editor.", in: app)
    }
    try require(app.staticTexts[Research.title].firstMatch, in: app, stage: "live-full-research-title")
  }

  private func beginLiveResearchEdit(in app: XCUIApplication, allowPreservedDraft: Bool = false) throws -> XCUIElement {
    try requireLiveResearchReader(in: app, allowPreservedDraft: allowPreservedDraft)
    try liveTap("document-edit", in: app)
    let editor = app.textViews["document-editor"].firstMatch
    try require(editor, in: app, stage: "live-native-research-body-editor")
    let title = app.staticTexts["editor-document-title"].firstMatch
    try require(title, in: app, stage: "live-editor-full-target-title")
    guard title.label == Research.title, let body = editor.value as? String,
      body.contains("에이전트 평가는 답변이 그럴듯한지"), !body.hasPrefix("---"), !body.contains("id: " + Research.id) else {
      throw blocked("The native editor does not show the exact existing research body with metadata hidden.", in: app)
    }
    return editor
  }

  private func appendLiveResearch(_ addition: String, to editor: XCUIElement, expectedBody: String, in app: XCUIApplication) throws {
    try replaceLiveResearchText(expectedBody + addition, in: editor, expectedText: expectedBody, app: app)
  }

  private func replaceLiveResearchText(_ replacement: String, in editor: XCUIElement, expectedText: String,
    app: XCUIApplication
  ) throws {
    try liveInputReady(in: app)
    guard editor.value as? String == expectedText else { throw blocked("The native research editor changed before the reviewed replacement.", in: app) }
    captureLiveResearchText(editor, name: "live-native-editor-before-reviewed-replacement")
    editor.tap()
    try liveInputReady(in: app)
    editor.press(forDuration: 1.1)
    capture(app, "live-native-edit-menu-before-select-all")
    let predicate = NSPredicate(format: "label IN %@", ["Select All", "모두 선택"])
    let menuItems = app.menuItems.matching(predicate)
    let buttons = app.buttons.matching(predicate)
    let selection: XCUIElement
    if menuItems.firstMatch.waitForExistence(timeout: 2), menuItems.count == 1, menuItems.firstMatch.isHittable {
      selection = menuItems.firstMatch
    } else if buttons.firstMatch.waitForExistence(timeout: 5), buttons.count == 1, buttons.firstMatch.isHittable {
      selection = buttons.firstMatch
    } else {
      capture(app, "live-native-select-all-not-available-draft-preserved")
      throw blocked("The native edit menu did not expose one exact Select All action; no keyboard shortcut or fallback input was sent.", in: app)
    }
    try livePress(selection, stage: "native-visible-select-all", in: app)
    capture(app, "live-native-editor-after-select-all-before-typing")
    try liveInputReady(in: app)
    guard editor.value as? String == expectedText else { throw blocked("Opening native selection changed the research text; no replacement was sent.", in: app) }
    editor.typeText(replacement)
    captureLiveResearchText(editor, name: "live-native-editor-after-reviewed-replacement")
    guard editor.value as? String == replacement else {
      throw blocked("Native Select All did not produce the exact reviewed full research text; the private draft was kept without saving.", in: app)
    }
  }

  private func liveResearchDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func captureLiveResearchText(_ editor: XCUIElement, name: String) {
    guard let text = editor.value as? String else { return }
    let attachment = XCTAttachment(string: text)
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }

  private func previewLiveResearch(in app: XCUIApplication, allowPreservedDraft: Bool = false) throws {
    try liveTap("문서 옵션", in: app)
    try liveTap("미리 보기", in: app)
    try gone(app.textViews["document-editor"].firstMatch, in: app, stage: "live-research-preview-shows-saved-reader")
    try requireLiveResearchReader(in: app, allowPreservedDraft: allowPreservedDraft)
  }

  private func requireLiveResearchParagraphs(_ paragraphs: [String], in app: XCUIApplication) throws {
    for paragraph in paragraphs {
      let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", paragraph)).firstMatch
      guard findOnscreen(text, in: app, maximumSwipes: 16) else {
        throw blocked("A saved meaningful research paragraph is not readable: " + paragraph, in: app)
      }
    }
  }

  private func liveResearchRevision(in app: XCUIApplication, stage: String) throws -> String {
    try liveTap("문서 옵션", in: app)
    try liveTap("문서 정보", in: app)
    let navigation = app.navigationBars["문서 정보"].firstMatch
    try require(navigation, in: app, stage: "live-research-information")
    let visibleCollections = app.collectionViews.allElementsBoundByIndex.filter(\.isHittable)
    guard navigation.isHittable, visibleCollections.count == 1, let information = visibleCollections.first else {
      throw blocked("Exactly one active native document-information form is required.", in: app)
    }
    // Native LabeledContent combines each field name and payload into one AX
    // label. Require its exact observed value within the foreground form.
    try require(information.staticTexts["파일, " + Research.path].firstMatch,
      in: app, stage: "live-exact-existing-research-path")
    try require(information.staticTexts["제목, " + Research.title].firstMatch,
      in: app, stage: "live-information-full-title")
    let tags = information.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "태그, ", "ai-agent")).firstMatch
    try require(tags, in: app, stage: "live-research-original-tags")
    guard ["AI 에이전트", "평가", "안전성", "프롬프트 주입", "ai-agent"].allSatisfy(tags.label.contains),
      !information.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "열었을 때의 문서 정보입니다.")).firstMatch.exists else {
      throw blocked("The current research identity or original tags could not be verified.", in: app)
    }
    try livePress(information.buttons["원문 버전"].firstMatch, stage: "show-actual-research-source-version", in: app)
    let revisions = information.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9a-f]{64}$"))
    try require(revisions.firstMatch, in: app, stage: "live-actual-source-sha256")
    guard revisions.count == 1 else { throw blocked("The displayed source revision is ambiguous.", in: app) }
    let revision = revisions.firstMatch.label
    capture(app, "live-research-information-" + stage)
    try livePress(navigation.buttons["닫기"].firstMatch, stage: "close-exact-research-information", in: app)
    try gone(app.navigationBars["문서 정보"].firstMatch, in: app, stage: "live-research-information-dismissed")
    return revision
  }

  private func openLiveResearchTrash(in app: XCUIApplication) throws {
    try home(app)
    try requireCurrentLibrary(Research.library, in: app)
    try refuseRecoveryOrDirtyDrafts(in: app)
    try liveTap("document-list-options", in: app)
    openDocumentManagement(in: app)
    try require(app.navigationBars["문서 정리"].firstMatch, in: app, stage: "live-existing-library-folder-browser")
    try liveTap("file-browser-options", in: app)
    try require(app.buttons["toggle-trash"].firstMatch, in: app, stage: "live-existing-library-file-management")
    guard app.buttons["toggle-trash"].firstMatch.label == "휴지통" else { throw blocked("Expected the existing document-folder view before trash.", in: app) }
    try liveTap("toggle-trash", in: app)
    try require(app.navigationBars["휴지통"].firstMatch, in: app, stage: "live-current-library-trash")
    guard !app.buttons["다시 확인"].firstMatch.exists else { throw blocked("The trash catalog is unavailable.", in: app) }
  }

  private func liveResearchTrashRows(in app: XCUIApplication) -> XCUIElementQuery {
    app.cells.containing(.staticText, identifier: Research.filename)
  }

  private func uniqueLiveResearchTrashRow(in app: XCUIApplication) throws -> XCUIElement {
    let rows = liveResearchTrashRows(in: app)
    try require(rows.firstMatch, in: app, timeout: 90, stage: "live-existing-research-trash-record")
    guard rows.count == 1, findOnscreen(rows.firstMatch, in: app, maximumSwipes: 12) else {
      throw blocked("The research trash record is ambiguous or not visible.", in: app)
    }
    return rows.firstMatch
  }

  private func closeLiveResearchTrash(in app: XCUIApplication) throws {
    try livePress(app.navigationBars["휴지통"].buttons["닫기"].firstMatch, stage: "close-existing-library-trash", in: app)
    try gone(app.buttons["toggle-trash"].firstMatch, in: app, stage: "live-library-trash-dismissed")
    try requireCurrentLibrary(Research.library, in: app)
  }

  private func liveInputReady(in app: XCUIApplication) throws {
    guard app.state == .runningForeground else { throw blocked("Folio lost foreground focus; no native input or write was retried.", in: app) }
    let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)
      .matching(identifier: "NotificationShortLookView").firstMatch
    if banner.exists { try gone(banner, in: app, timeout: 20, stage: "os-notification-banner-expired-without-interaction") }
    guard app.state == .runningForeground else { throw blocked("Folio lost foreground while waiting for the notification to expire.", in: app) }
  }

  private func liveTap(_ identifier: String, in app: XCUIApplication) throws {
    try livePress(app.buttons[identifier].firstMatch, stage: identifier, in: app)
  }

  private func livePress(_ button: XCUIElement, stage: String, in app: XCUIApplication) throws {
    try require(button, in: app, stage: "live-action-" + stage)
    try liveInputReady(in: app)
    guard button.isEnabled, button.isHittable else { throw blocked("The exact live native action is unavailable: " + stage, in: app) }
    button.tap()
    guard app.state == .runningForeground else { throw blocked("Folio lost foreground during the action; it was not retried: " + stage, in: app) }
  }

  private func requireResearchTitles(_ titles: [String], in app: XCUIApplication) throws {
    for title in titles {
      let row = homeCollection(in: app).cells.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
      try require(row, in: app, stage: "existing-research-document-" + title)
    }
    // The physical hierarchy contains the scope/reset control as its own cell.
    // Exclude that exact identified header; every other cell must be a document.
    let documentCells = homeCollection(in: app).cells.allElementsBoundByIndex.filter {
      !$0.staticTexts["document-list-scope"].firstMatch.exists
        && !$0.buttons["document-filters"].firstMatch.exists
    }
    let rows = documentCells.map { $0.buttons.allElementsBoundByIndex }
    guard rows.allSatisfy({ $0.count == 1 }) else { throw blocked("An unrecognized non-header row appeared in the research list.", in: app) }
    let labels = rows.compactMap { $0.first?.label }
    guard labels.count == titles.count, Set(labels) == Set(titles) else { throw blocked("Expected only the exact existing research documents for this phase.", in: app) }
  }

  private func clearNativeSearch(_ field: XCUIElement, preservingScope expectedScope: String,
    expectedTitles: [String], in app: XCUIApplication
  ) throws {
    let explicitClear = app.buttons["document-search-clear"].firstMatch
    let clear = field.buttons.matching(NSPredicate(format: "label IN %@", ["Clear text", "텍스트 지우기", "지우기"])).firstMatch
    if explicitClear.exists, explicitClear.isEnabled, explicitClear.isHittable { explicitClear.tap() }
    else if clear.exists, clear.isHittable { clear.tap() }
    else {
      field.tap()
      field.typeKey("a", modifierFlags: .command)
      field.typeText(XCUIKeyboardKey.delete.rawValue)
    }
    let emptyValue = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == nil OR value == '' OR value == %@", field.placeholderValue ?? "문서 검색"),
      object: field)
    guard XCTWaiter.wait(for: [emptyValue], timeout: 10) == .completed else {
      throw blocked("Native search did not clear its query.", in: app)
    }
    // The physical TextField exposes no value when empty, together with this
    // placeholder. Require the actual unfiltered list as well as its blank input.
    if field.value == nil, field.placeholderValue != "문서 검색" {
      throw blocked("An unrecognized native input state cannot prove the query is empty.", in: app)
    }
    try gone(explicitClear, in: app, stage: "cleared-search-button-disappeared")
    try gone(app.staticTexts["search-result-count"].firstMatch, in: app, stage: "cleared-search-results-disappeared")
    let scope = app.staticTexts["document-list-scope"].firstMatch
    try require(scope, in: app, stage: "cleared-search-retains-scope")
    guard scope.label == expectedScope else { throw blocked("Clearing the query changed the selected document scope.", in: app) }
    try requireResearchTitles(expectedTitles, in: app)
    let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "취소"])).firstMatch
    if cancel.exists, cancel.isHittable { cancel.tap() }
    else if field.identifier == "document-search" {
      field.tap()
      field.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }
    capture(app, "ai-agent-native-search-cleared-without-changing-documents")
  }

  private func documentSearchInput(in app: XCUIApplication) -> XCUIElement {
    if !app.searchFields.firstMatch.exists { revealDocumentSearch(in: app) }
    let search = app.searchFields.firstMatch
    return search.exists ? search : app.textFields["document-search"].firstMatch
  }

  private func trashOwnedDocuments(library: OwnedLibrary, in app: XCUIApplication) throws -> Int {
    guard ownedLibraries.contains(library) else { throw blocked("Unrecognized cleanup library.", in: app) }
    try home(app)
    try requireSelectedOwnedLibrary(library, in: app)
    try requireCurrentLibrary(library.name, in: app)
    try resetDocumentFilters(in: app, libraryName: library.name)
    for removed in 0..<30 {
      try requireCurrentLibrary(library.name, in: app)
      try refuseRecoveryOrDirtyDrafts(in: app)
      if app.staticTexts["아직 문서가 없습니다"].firstMatch.exists {
        capture(app, "maintenance-confirmed-empty-" + library.name)
        return removed
      }
      let collection = homeCollection(in: app)
      try require(collection, in: app, stage: "owned-document-list")
      let controlLabels: Set<String> = ["새 문서 만들기", "필터 초기화", "검색 지우기", "검색 다시 시도", "검색 결과 더 보기"]
      let recoveryActions: Set<String> = ["초안 열기", "연결 복구", "원문 복구", "버전 비교", "원문 다운로드"]
      let candidates = collection.cells.allElementsBoundByIndex.compactMap { cell -> XCUIElement? in
        guard !cell.staticTexts["document-list-scope"].firstMatch.exists,
          !cell.buttons["document-filters"].firstMatch.exists else { return nil }
        let buttons = cell.buttons.allElementsBoundByIndex
        guard buttons.count == 1, let button = buttons.first, !button.label.isEmpty,
          !controlLabels.contains(button.label),
          !cell.staticTexts.allElementsBoundByIndex.contains(where: { recoveryActions.contains($0.label) }) else { return nil }
        return button
      }
      guard let candidate = candidates.first else { throw blocked("No recognized document row or confirmed empty state.", in: app) }
      let title = candidate.label
      let rows = collection.cells.buttons.matching(NSPredicate(format: "label == %@", title))
      guard rows.count == 1 else { throw blocked("Ambiguous document row: " + title, in: app) }
      let row = rows.firstMatch
      guard findOnscreen(row, in: app, maximumSwipes: 12) else { throw blocked("Document row could not be made visible: " + title, in: app) }
      capture(app, "maintenance-owned-document-before-open-" + title)
      row.tap()
      try require(app.buttons["문서 옵션"].firstMatch, in: app, stage: "owned-document-reader")
      try require(app.staticTexts[title].firstMatch, in: app, stage: "owned-document-exact-title")
      try refuseRecoveryOrDirtyDrafts(in: app)
      guard !app.textViews.firstMatch.exists, app.buttons["편집"].firstMatch.exists else {
        throw blocked("Expected a clean saved reader before recoverable trash.", in: app)
      }
      try tap("문서 옵션", in: app)
      try tap("휴지통으로 이동…", in: app)
      try require(app.navigationBars["휴지통으로 이동"].firstMatch, in: app, stage: "recoverable-trash-confirmation")
      try require(app.staticTexts["휴지통에서 다시 복원할 수 있습니다."].firstMatch, in: app, stage: "recoverable-trash-policy")
      capture(app, "maintenance-owned-document-trash-confirmation-" + title)
      try tap("file-action-submit", in: app)
      try gone(app.buttons["file-action-submit"].firstMatch, in: app, stage: "trash-operation-finished")
      try home(app)
      try requireCurrentLibrary(library.name, in: app)
      let previousRow = homeCollection(in: app).cells.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
      try gone(previousRow, in: app, stage: "trashed-document-left-list")
      capture(app, "maintenance-owned-document-trashed-" + title)
      print("FOLIO_MAINTENANCE_TRASHED \(library.name) [\(library.storage)] \(title)")
    }
    guard app.staticTexts["아직 문서가 없습니다"].firstMatch.exists else {
      throw blocked("The per-library limit of 30 documents was reached; no further mutations were attempted.", in: app)
    }
    return 30
  }

  private func refuseRecoveryOrDirtyDrafts(in app: XCUIApplication) throws {
    let recoveryLabels = ["보존한 초안", "이어서 편집", "편집 이어쓰기", "저장하지 않은 편집", "편집은 초안에 보존 · 저장한 원문을 읽는 중", "보존한 초안 열기"]
    if recoveryLabels.contains(where: { app.buttons[$0].firstMatch.exists || app.staticTexts[$0].firstMatch.exists }) {
      throw blocked("A preserved or unsaved draft needs an explicit decision; it was kept.", in: app)
    }
    let dirtyRow = homeCollection(in: app).cells.buttons.allElementsBoundByIndex.contains {
      ($0.value as? String)?.contains("저장하지 않은 편집") == true
    }
    if dirtyRow { throw blocked("An owned library contains an unsaved draft; it was kept.", in: app) }
    for label in ["확인이 필요한 자료", "첨부 연결 확인", "원문 다운로드 중…", "문서를 받는 중…", "검색 결과가 없습니다", "필터에 맞는 문서가 없습니다"] {
      if app.staticTexts[label].firstMatch.exists { throw blocked("Unresolved source/list state: " + label, in: app) }
    }
  }

  private func resetDocumentFilters(in app: XCUIApplication, libraryName: String) throws {
    let field = documentSearchInput(in: app)
    if field.exists, let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
      throw blocked("An active search would hide cleanup candidates; no documents were changed.", in: app)
    }
    openDocumentFilters(in: app)
    capture(app, "native-document-browse-choices-before-all-documents")
    try selectBrowseChoice("모든 문서", identifier: "document-browse-all", in: app)
    try requireUnfilteredDocumentScope(in: app, libraryName: libraryName)
  }

  private func requireUnfilteredDocumentScope(in app: XCUIApplication, libraryName: String) throws {
    try requireCurrentLibrary(libraryName, in: app)
    try gone(app.staticTexts["document-list-scope"].firstMatch, in: app, stage: "inactive-scope-not-repeated-on-home")
    try gone(app.buttons["document-filter-reset"].firstMatch, in: app, stage: "inactive-filter-reset-not-shown")
    guard app.buttons["library-picker"].firstMatch.isHittable else {
      throw blocked("The document list did not regain focus after checking filters.", in: app)
    }
  }

  private func selectBrowseChoice(_ label: String, identifier: String? = nil, in app: XCUIApplication) throws {
    let browse = app.descendants(matching: .any).matching(identifier: "document-browse-sheet").firstMatch
    try require(browse, in: app, stage: "direct-folder-and-tag-browse-list")
    let navigation = app.navigationBars["찾아보기"].firstMatch
    try require(navigation, in: app, stage: "direct-folder-and-tag-browse-navigation")
    let choice = identifier.map { browse.buttons[$0].firstMatch }
      ?? browse.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    for attempt in 0...12 {
      guard browse.exists, browse.isHittable, navigation.exists, navigation.isHittable else {
        throw blocked("The exact folder/tag picker lost focus before selection.", in: app)
      }
      if choice.exists, choice.isEnabled, choice.isHittable, safeCenter(choice, in: app) {
        guard choice.label == label else { throw blocked("The native browse choice does not have the exact requested label.", in: app) }
        capture(app, "direct-browse-existing-choice-" + label)
        choice.tap()
        try gone(browse, in: app, stage: "direct-browse-dismissed-after-" + label)
        return
      }
      guard attempt < 12 else { break }
      // Swipe only the identified foreground browse list, never the library
      // beneath it. A lazy offscreen tag may not exist until this list scrolls.
      let down = choice.exists && !choice.frame.isEmpty ? choice.frame.midY < browse.frame.midY : attempt >= 6
      if down { browse.swipeDown(velocity: .slow) } else { browse.swipeUp(velocity: .slow) }
    }
    throw blocked("The exact existing folder/tag choice is not reachable: " + label, in: app)
  }

  private func hideEmptiedLibraries(_ libraries: [OwnedLibrary], in app: XCUIApplication) throws {
    for library in libraries {
      let choice = try ownedLibraryChoice(library, in: app)
      guard findOnscreen(choice, in: app, maximumSwipes: 8, libraryPickerOnly: true) else { continue }
      guard matchesOwnedLibrary(choice, library: library, in: app) else { throw blocked("The empty library identity does not match.", in: app) }
      if choice.isSelected {
        print("FOLIO_MAINTENANCE_EMPTY_CURRENT_RETAINED \(library.name) [\(library.storage)]")
        continue
      }
      choice.press(forDuration: 1.1)
      let hide = app.buttons["목록에서 숨기기"].firstMatch
      if hide.waitForExistence(timeout: 3) {
        capture(app, "maintenance-hide-empty-library-" + library.name)
        hide.tap()
        print("FOLIO_MAINTENANCE_HIDDEN \(library.name) [\(library.storage)]")
      } else {
        capture(app, "maintenance-empty-library-hide-not-available-" + library.name)
        let restore = app.buttons["목록에 다시 표시"].firstMatch
        let settings = app.buttons["자료함 설정"].firstMatch
        if restore.exists { try dismissMenu(restore, in: app, navigationTitle: "자료함") }
        else if settings.exists { try dismissMenu(settings, in: app, navigationTitle: "자료함") }
        else if !app.navigationBars["자료함"].buttons["닫기"].firstMatch.isHittable {
          throw blocked("An unrecognized library context menu remains open.", in: app)
        }
      }
    }
  }

  private func ownedLibraryChoice(_ library: OwnedLibrary, in app: XCUIApplication) throws -> XCUIElement {
    guard let identifier = library.accessibilityIdentifier, !identifier.isEmpty else {
      throw blocked("The cleanup library has no independently verified identity.", in: app)
    }
    let choices = app.buttons.matching(identifier: identifier)
    guard choices.count <= 1 else { throw blocked("The cleanup library identity is ambiguous.", in: app) }
    return choices.firstMatch
  }

  private func matchesOwnedLibrary(_ choice: XCUIElement, library: OwnedLibrary, in app: XCUIApplication) -> Bool {
    guard let identifier = library.accessibilityIdentifier,
      app.buttons.matching(identifier: identifier).count == 1 else { return false }
    return choice.identifier == identifier && choice.label == library.name
      && (choice.value as? String)?.contains(library.storage) == true
  }

  private func requireSelectedOwnedLibrary(_ library: OwnedLibrary, in app: XCUIApplication) throws {
    try openLibraryPicker(in: app)
    let choice = try ownedLibraryChoice(library, in: app)
    guard findOnscreen(choice, in: app, maximumSwipes: 12, libraryPickerOnly: true),
      matchesOwnedLibrary(choice, library: library, in: app), choice.isSelected else {
      throw blocked("The current cleanup library identity was not confirmed.", in: app)
    }
    try tap("닫기", in: app)
    try requireCurrentLibrary(library.name, in: app)
  }

  private func openLibraryPicker(in app: XCUIApplication) throws {
    try foreground(app)
    try home(app)
    try tap("library-picker", in: app)
    try require(app.navigationBars["자료함"].buttons["닫기"].firstMatch, in: app, stage: "library-picker-presented")
    capture(app, "maintenance-library-picker-presented-before-selection")
  }

  private func expandHiddenLibraries(in app: XCUIApplication) throws {
    let close = app.navigationBars["자료함"].buttons["닫기"].firstMatch
    guard close.exists, close.isHittable else { throw blocked("The library picker is not active before checking hidden libraries.", in: app) }
    let disclosure = app.buttons["숨긴 자료함"].firstMatch
    guard disclosure.exists else {
      print("FOLIO_MAINTENANCE_NO_HIDDEN_LIBRARY_DISCLOSURE")
      return
    }
    guard findOnscreen(disclosure, in: app, maximumSwipes: 8, libraryPickerOnly: true) else {
      throw blocked("An existing hidden-library disclosure could not be reached within its picker.", in: app)
    }
    disclosure.tap()
  }

  private func selectLibrary(_ choice: XCUIElement, name: String, in app: XCUIApplication) throws {
    guard choice.label == name, choice.isHittable, safeCenter(choice, in: app) else { throw blocked("Library selection is not exact and visible.", in: app) }
    let close = app.navigationBars["자료함"].buttons["닫기"].firstMatch
    guard close.exists, close.isHittable else { throw blocked("The exact library choice is outside an active picker.", in: app) }
    capture(app, "maintenance-exact-library-choice-" + name)
    choice.tap()
    try gone(close, in: app, timeout: 90, stage: "library-picker-dismissed")
    try home(app)
    try requireCurrentLibrary(name, in: app)
  }

  private func requireCurrentLibrary(_ name: String, in app: XCUIApplication) throws {
    let picker = app.buttons["library-picker"].firstMatch
    try require(picker, in: app, timeout: 90, stage: "current-library-picker")
    if picker.isHittable, picker.value as? String == name { return }
    let title = app.navigationBars[name].firstMatch
    try require(title, in: app, timeout: 90, stage: "exact-current-library-" + name)
    guard title.isHittable, picker.isHittable else { throw blocked("The selected library is not the active native screen.", in: app) }
  }

  private func homeCollection(in app: XCUIApplication) -> XCUIElement {
    app.collectionViews.allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) ?? app.collectionViews.firstMatch
  }

  private func home(_ app: XCUIApplication) throws {
    if app.buttons["library-picker"].firstMatch.isHittable { return }
    guard !app.textViews.firstMatch.exists else { throw blocked("An editor is open; maintenance did not dismiss or discard it.", in: app) }
    let back = app.navigationBars.buttons.element(boundBy: 0)
    try require(back, in: app, stage: "native-library-back")
    back.tap()
    try require(app.buttons["library-picker"].firstMatch, in: app, stage: "native-library-home")
  }

  private func findOnscreen(_ element: XCUIElement, in app: XCUIApplication, maximumSwipes: Int,
    libraryPickerOnly: Bool = false
  ) -> Bool {
    for attempt in 0...maximumSwipes {
      let picker = app.navigationBars["자료함"].firstMatch
      if libraryPickerOnly {
        let close = picker.buttons["닫기"].firstMatch
        // A missing row/disclosure never licenses a swipe on an underlying list
        // or a sheet drag. The small picker must expose the exact target first.
        guard close.exists, close.isHittable, element.exists else { return false }
      }
      if element.exists, element.isHittable, safeCenter(element, in: app) { return true }
      guard attempt < maximumSwipes else { break }
      let surface: XCUIElement
      if libraryPickerOnly {
        let minimumY = picker.frame.minY - 24
        let pickerSurfaces = app.scrollViews.matching(identifier: "library-scroll").allElementsBoundByIndex
          + app.collectionViews.allElementsBoundByIndex
        guard let collection = pickerSurfaces.last(where: {
          $0.isHittable && $0.frame.minY >= minimumY && $0.frame.maxY <= app.frame.maxY + 1
        }) else { return false }
        surface = collection
      } else {
        if let list = [app.collectionViews, app.tables]
          .compactMap({ $0.allElementsBoundByIndex.last(where: { $0.isHittable }) }).first {
          surface = list
        } else {
          // Markdown tables own nested horizontal ScrollViews. A physical
          // reader trace showed swipes landing there and leaving the actual
          // paragraph below the viewport. Use the enclosing reading surface.
          guard let reader = app.scrollViews.allElementsBoundByIndex.first(where: {
            $0.isHittable && $0.frame.height >= app.frame.height * 0.5
          }) else { return false }
          surface = reader
        }
      }
      let down = element.exists && !element.frame.isEmpty ? element.frame.midY < surface.frame.midY : attempt >= maximumSwipes / 2
      if down { surface.swipeDown(velocity: .slow) } else { surface.swipeUp(velocity: .slow) }
    }
    return false
  }

  private func safeCenter(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
    guard element.exists, !element.frame.isEmpty else { return false }
    let navigationBottom = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map(\.frame.maxY).max() ?? app.frame.minY
    let frame = element.frame
    return frame.midX > app.frame.minX + 8 && frame.midX < app.frame.maxX - 8
      && frame.midY > navigationBottom + 4 && frame.midY < app.frame.maxY - 40
  }

  private func dismissMenu(_ visibleItem: XCUIElement, in app: XCUIApplication, navigationTitle: String) throws {
    guard visibleItem.exists else { throw blocked("The expected menu is not open.", in: app) }
    // The recorded failure showed a menu covering the navigation title. The
    // extreme left window margin is outside those native menu action frames.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5)).tap()
    try gone(visibleItem, in: app, timeout: 10, stage: "native-menu-dismissed")
    if navigationTitle == "자료함" {
      let close = app.navigationBars["자료함"].buttons["닫기"].firstMatch
      guard close.exists, close.isHittable else { throw blocked("The library picker did not regain focus.", in: app) }
    } else {
      try requireCurrentLibrary(navigationTitle, in: app)
      guard app.buttons["library-picker"].firstMatch.isHittable else { throw blocked("The owned library home did not regain focus.", in: app) }
    }
  }

  private func tap(_ identifier: String, in app: XCUIApplication) throws {
    if identifier == "library-picker" {
      try tapLibraryPicker(in: app)
      return
    }
    let button = app.buttons[identifier].firstMatch
    try require(button, in: app, stage: "action-" + identifier)
    guard button.isEnabled, button.isHittable else { throw blocked("Native action is unavailable: " + identifier, in: app) }
    button.tap()
  }

  private func foreground(_ app: XCUIApplication) throws {
    if app.state == .runningForeground { return }
    guard app.state != .notRunning else { throw blocked("Folio stopped before the native action; it was not relaunched.", in: app) }
    app.activate()
    guard app.wait(for: .runningForeground, timeout: 15) else {
      throw blocked("Folio did not regain foreground focus before the native action.", in: app)
    }
  }

  private func tapLibraryPicker(in app: XCUIApplication) throws {
    try foreground(app)
    let picker = app.buttons["library-picker"].firstMatch
    try require(picker, in: app, stage: "action-library-picker")
    guard picker.isEnabled, picker.isHittable,
      let currentLibrary = picker.value as? String, !currentLibrary.isEmpty else {
      throw blocked("The native library picker is not an identified, active library control.", in: app)
    }
    let frame = picker.frame
    let center = CGPoint(x: frame.midX, y: frame.midY)
    guard !frame.isEmpty, app.frame.contains(frame),
      frame.minY >= app.frame.minY, frame.maxY < app.frame.midY,
      app.textFields["document-search"].firstMatch.isHittable || app.staticTexts["Folio"].firstMatch.exists else {
      throw blocked("The library picker is outside the active library header.", in: app)
    }
    capture(app, "maintenance-library-picker-before-observed-center-tap")
    guard app.state == .runningForeground, picker.isHittable,
      picker.value as? String == currentLibrary, picker.frame == frame else {
      throw blocked("The current library or foreground changed before picker activation.", in: app)
    }
    // A physical-device trace showed an invalid AX activation point followed by
    // an automatic tap at a different control. Use only this observed frame.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
      .withOffset(CGVector(dx: center.x - app.frame.minX, dy: center.y - app.frame.minY)).tap()
    guard app.state == .runningForeground else {
      throw blocked("Folio lost foreground focus during picker activation; no retry was sent.", in: app)
    }
  }

  private func require(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 30, stage: String) throws {
    guard element.waitForExistence(timeout: timeout) else { throw blocked("Missing native UI: " + stage, in: app) }
  }

  private func gone(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 30, stage: String) throws {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
    guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else { throw blocked("Native transition did not finish: " + stage, in: app) }
  }

  private func blocked(_ reason: String, in app: XCUIApplication) -> MaintenanceError {
    capture(app, "maintenance-blocked")
    print("FOLIO_MAINTENANCE_BLOCKED \(reason)")
    return .blocked(reason)
  }

  private enum MaintenanceError: Error { case blocked(String) }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
  }
}
