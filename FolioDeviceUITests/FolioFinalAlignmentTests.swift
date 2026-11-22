import CryptoKit
import XCTest

/// One native pass over existing content. The only mutation permitted here is
/// discarding the exact, previously captured incomplete private draft.
@MainActor
final class FolioFinalAlignmentTests: XCTestCase {
  private enum Research {
    static let library = "AI agent"
    static let target = CloudLibraryTarget(name: library, containerIdentifier: "iCloud.com.axient.Folio",
      workspaceID: UUID(uuidString: "8231965d-1c28-4d16-bfef-e2b381304cb9")!)
    static let libraries = ["에이전트와 기술", library, "ProjectVault"]
    static let title = "에이전트의 성공과 안전을 무엇으로 확인할까"
    static let titles = ["AI agent는 무엇이고 언제 쓰는가", "AI 에이전트의 실행 경계: 도구, 승인, 중단과 재개", title]
    static let path = "notes/agent-evaluation-and-safety.md"
    static let sourceRevision = "58705aa23702bd4b08b184f480d7e6ffc4357d44cececbda28934440ba79b12e"
    static let savedBodyDigest = "356429927f7a9f00be40a5c333215c83507d42be7e2167e829f8bf5e2eb950fc"
    static let partialDraftDigest = "bb6346e2a8354707b5c954ff3ec3a6fe04d5021cf3ca9ea8ac7396576fa05dd1"
    static let paragraph = "도구가 문서를 바꾸는 평가에서는 원문을 읽은 시점의 버전과 저장 후 실제 내용을 함께 기록한다. 문서가 이미 바뀌어 있었다면 검증 중 새로 저장한 결과와 구분한다. 이는 이 문서의 평가 설계 제안이다."
  }

  func testExistingResearchFinalAlignment() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "com.axient.Folio")
    app.launch()
    try ready(app)
    try home(app)
    try openResearchLibrary(app)
    try requireEmptySearch(app)
    try chooseBrowse("모든 문서", identifier: "document-browse-all", in: app)
    try requireAllDocuments(app)
    try requireResearchTitles(app)

    for (choice, scope) in [("문서", "폴더: 문서"), ("ai-agent", "태그: ai-agent")] {
      try chooseBrowse(choice, in: app)
      let activeScope = app.staticTexts["document-list-scope"].firstMatch
      try require(activeScope, in: app)
      guard activeScope.label == scope else { throw blocked("The chosen existing folder or tag was not applied exactly.", in: app) }
      try requireResearchTitles(app)
      try press(app.buttons["document-filter-reset"].firstMatch, in: app)
      try requireAllDocuments(app)
    }

    let rows = homeList(app).cells.buttons.matching(NSPredicate(format: "label == %@", Research.title))
    try require(rows.firstMatch, in: app)
    guard rows.count == 1 else { throw blocked("The existing research document is ambiguous.", in: app) }
    try press(rows.firstMatch, in: app)
    let edit = app.buttons["document-edit"].firstMatch
    try require(edit, in: app)
    guard ["편집", "편집 이어쓰기"].contains(edit.label) else { throw blocked("The existing research source is not ready.", in: app) }
    let hasPrivateDraft = edit.label == "편집 이어쓰기"
    // The saved-source revision is verified independently from the private body.
    try requireSavedSource(app, stage: "before-draft-review")
    guard edit.label == (hasPrivateDraft ? "편집 이어쓰기" : "편집") else {
      throw blocked("The private draft changed while its saved source was being checked.", in: app)
    }
    try press(edit, in: app)
    let editor = app.textViews["document-editor"].firstMatch
    try require(editor, in: app)
    let title = app.staticTexts["editor-document-title"].firstMatch
    try require(title, in: app)
    guard title.label == Research.title, let body = editor.value as? String, !body.hasPrefix("---") else {
      throw blocked("The editor does not identify the exact existing research body.", in: app)
    }
    if hasPrivateDraft {
      guard digest(body) == Research.partialDraftDigest, body.count == 3093, body.utf8.count == 6204,
        app.buttons["document-save"].firstMatch.isEnabled else {
        throw blocked("This private draft is not the exact captured incomplete input; it was preserved.", in: app)
      }
      try press(app.buttons["문서 옵션"].firstMatch, in: app)
      try press(app.buttons["편집 취소"].firstMatch, in: app)
      let prompt = "편집을 취소할까요?"
      let containers = app.sheets.allElementsBoundByIndex + app.alerts.allElementsBoundByIndex
      let dialogs = containers.filter { $0.staticTexts[prompt].firstMatch.exists && $0.isHittable }
      guard dialogs.count == 1, let dialog = dialogs.first,
        dialog.staticTexts["저장하지 않은 변경을 취소합니다. 저장한 문서는 유지됩니다."].firstMatch.exists,
        editor.value as? String == body,
        !app.staticTexts["원문이 바뀌었습니다. 편집 내용은 보존했습니다."].firstMatch.exists,
        !app.staticTexts["새 변경을 받았습니다. 저장할 때 함께 확인합니다."].firstMatch.exists else {
        throw blocked("The exact private-draft discard confirmation is not safe; the draft was preserved.", in: app)
      }
      let discard = dialog.buttons.matching(NSPredicate(format: "label == %@", "편집 취소"))
      guard discard.count == 1 else { throw blocked("The private-draft confirmation is ambiguous.", in: app) }
      try press(discard.firstMatch, in: app)
      try gone(editor, in: app)
      try require(edit, in: app)
      guard edit.label == "편집" else { throw blocked("The reader did not return to the saved source after discarding the known draft.", in: app) }
      print("FOLIO_FINAL_KNOWN_PARTIAL_DRAFT_DISCARDED bodySHA256=\(Research.partialDraftDigest)")
      try press(edit, in: app)
      try require(editor, in: app)
    } else {
      guard digest(body) == Research.savedBodyDigest else {
        throw blocked("The clean editor differs from the actual saved A body; no input was sent.", in: app)
      }
      print("FOLIO_FINAL_NO_PRIVATE_DRAFT_TO_DISCARD")
    }

    guard let saved = editor.value as? String, digest(saved) == Research.savedBodyDigest,
      saved.count == 4847, saved.utf8.count == 9715, saved.contains(Research.paragraph),
      !app.buttons["document-save"].firstMatch.isEnabled else {
      throw blocked("The exact saved A body or clean editor state was not restored.", in: app)
    }
    try press(app.buttons["문서 옵션"].firstMatch, in: app)
    try press(app.buttons["미리 보기"].firstMatch, in: app)
    try gone(editor, in: app)
    try requireSavedSource(app, stage: "after-draft-review")
    let paragraph = app.staticTexts.matching(NSPredicate(format: "label == %@", Research.paragraph)).firstMatch
    try showReaderParagraph(paragraph, in: app)
    capture(app, "final-alignment-saved-research-A-reader")
    try home(app)
    try requireAllDocuments(app)
    try requireResearchTitles(app, requireClean: true)
    capture(app, "final-alignment-clean-three-document-list")
    print("FOLIO_FINAL_ALIGNMENT_VERIFIED sourceRevision=\(Research.sourceRevision) savedBodySHA256=\(Research.savedBodyDigest) sourceWrites=0")
  }

  private func openResearchLibrary(_ app: XCUIApplication) throws {
    let picker = app.buttons["library-picker"].firstMatch
    try require(picker, in: app)
    try ready(app)
    let frame = picker.frame
    guard picker.isHittable, picker.isEnabled, !frame.isEmpty, app.frame.contains(frame),
      frame.maxY < app.frame.midY else { throw blocked("The library picker has no safe observed activation frame.", in: app) }
    // This physical control previously reported an incorrect AX activation point.
    app.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
    try ready(app)
    let navigation = app.navigationBars["자료함"].firstMatch
    try require(navigation.buttons["닫기"].firstMatch, in: app)
    let scroll = app.scrollViews["library-scroll"].firstMatch
    try require(scroll, in: app)
    let choices = scroll.buttons.matching(NSPredicate(format: "value == %@", "iCloud"))
    let visible = choices.allElementsBoundByIndex.filter(\.isHittable)
    guard visible.count == 3, Set(visible.map(\.label)) == Set(Research.libraries),
      visible.filter(\.isSelected).count == 1,
      visible.allSatisfy({ app.frame.contains($0.frame) && !$0.frame.isEmpty }) else {
      throw blocked("The visible library grid does not contain exactly the three complete existing cloud-library names.", in: app)
    }
    capture(app, "final-alignment-three-full-library-names")
    let selected = choices.matching(identifier: Research.target.accessibilityIdentifier)
    guard selected.count == 1 else { throw blocked("The exact AI agent iCloud choice is ambiguous.", in: app) }
    try press(selected.firstMatch, in: app)
    try gone(navigation, in: app)
    try requireHome(app)
    try requireSelectedCloudLibrary(Research.target, in: app)
  }

  private func chooseBrowse(_ label: String, identifier: String? = nil, in app: XCUIApplication) throws {
    openDocumentFilters(in: app)
    let browse = app.descendants(matching: .any).matching(identifier: "document-browse-sheet").firstMatch
    try require(browse, in: app)
    let close = app.navigationBars["찾아보기"].buttons["닫기"].firstMatch
    try require(close, in: app)
    guard close.isHittable else { throw blocked("The folder/tag sheet has no reachable close action.", in: app) }
    let choice = identifier.map { browse.buttons[$0].firstMatch }
      ?? browse.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    for attempt in 0...6 {
      try ready(app)
      guard browse.isHittable, close.isHittable else { throw blocked("The folder/tag sheet lost focus.", in: app) }
      if choice.exists, choice.isHittable, choice.frame.midY > close.frame.maxY,
        choice.frame.maxY < app.frame.maxY - 32 {
        guard choice.label == label else { throw blocked("The existing folder/tag choice is not exact.", in: app) }
        try press(choice, in: app)
        try gone(browse, in: app)
        return
      }
      guard attempt < 6 else { break }
      browse.swipeUp(velocity: .slow)
    }
    throw blocked("The exact existing folder or tag is not visible: " + label, in: app)
  }

  private func requireSavedSource(_ app: XCUIApplication, stage: String) throws {
    try press(app.buttons["문서 옵션"].firstMatch, in: app)
    try press(app.buttons["문서 정보"].firstMatch, in: app)
    let navigation = app.navigationBars["문서 정보"].firstMatch
    try require(navigation, in: app)
    let forms = app.collectionViews.allElementsBoundByIndex.filter(\.isHittable)
    guard forms.count == 1, let form = forms.first else { throw blocked("The active document-information form is ambiguous.", in: app) }
    for exact in ["제목, " + Research.title, "파일, " + Research.path,
      "태그, AI 에이전트 · 평가 · 안전성 · 프롬프트 주입 · ai-agent"] {
      try require(form.staticTexts[exact].firstMatch, in: app)
    }
    guard !form.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "열었을 때의 문서 정보입니다.")).firstMatch.exists else {
      throw blocked("The source information became stale; no draft was discarded.", in: app)
    }
    try press(form.buttons["원문 버전"].firstMatch, in: app)
    let revisions = form.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9a-f]{64}$"))
    try require(revisions.firstMatch, in: app)
    guard revisions.count == 1, revisions.firstMatch.label == Research.sourceRevision else {
      throw blocked("The saved source differs from the actual phone/Mac A revision; all private edits were preserved.", in: app)
    }
    try ready(app)
    let observedRevision = revisions.firstMatch.label
    let hierarchy = form.debugDescription
    try ready(app)
    let evidence = XCTAttachment(string: hierarchy)
    evidence.name = "final-alignment-source-information-" + stage
    evidence.lifetime = .keepAlways; add(evidence)
    print("FOLIO_FINAL_SOURCE_VERIFIED stage=\(stage) sourceRevision=\(observedRevision)")
    try press(navigation.buttons["닫기"].firstMatch, in: app)
    try gone(navigation, in: app)
  }

  private func requireResearchTitles(_ app: XCUIApplication, requireClean: Bool = false) throws {
    let cells = homeList(app).cells.allElementsBoundByIndex.filter {
      !$0.staticTexts["document-list-scope"].firstMatch.exists && !$0.buttons["document-filters"].firstMatch.exists
    }
    let buttons = cells.map { $0.buttons.allElementsBoundByIndex }
    guard buttons.allSatisfy({ $0.count == 1 }), buttons.count == 3,
      Set(buttons.compactMap { $0.first?.label }) == Set(Research.titles) else {
      throw blocked("Expected only the three exact existing AI agent research documents.", in: app)
    }
    for row in buttons.compactMap(\.first) where (row.value as? String)?.contains("저장하지 않은 편집") == true {
      guard !requireClean, row.label == Research.title else { throw blocked("An unexpected private draft was preserved.", in: app) }
    }
    for state in ["보존한 초안", "이어서 편집", "확인이 필요한 자료", "원문 다운로드 중…", "문서를 받는 중…"] where app.staticTexts[state].firstMatch.exists {
      throw blocked("The source has an unresolved state: " + state, in: app)
    }
  }

  private func requireAllDocuments(_ app: XCUIApplication) throws {
    try requireHome(app)
    guard !app.staticTexts["document-list-scope"].firstMatch.exists,
      !app.staticTexts["document-list-scope"].firstMatch.exists,
      !app.buttons["document-filter-reset"].firstMatch.exists else {
      throw blocked("The list did not return to all documents without a redundant active scope.", in: app)
    }
  }

  private func requireEmptySearch(_ app: XCUIApplication) throws {
    revealDocumentSearch(in: app)
    let search = app.textFields["document-search"].firstMatch
    try require(search, in: app)
    guard search.value == nil || search.value as? String == "" || search.value as? String == search.placeholderValue else {
      throw blocked("An existing search would change the expected document set; it was preserved.", in: app)
    }
  }

  private func requireHome(_ app: XCUIApplication) throws {
    let picker = app.buttons["library-picker"].firstMatch
    try require(picker, in: app)
    guard picker.isHittable, picker.value as? String == Research.library else { throw blocked("The active library is not AI agent.", in: app) }
  }

  private func homeList(_ app: XCUIApplication) -> XCUIElement {
    app.collectionViews.allElementsBoundByIndex.last(where: \.isHittable) ?? app.collectionViews.firstMatch
  }

  private func home(_ app: XCUIApplication) throws {
    if app.buttons["library-picker"].firstMatch.isHittable { return }
    guard !app.textViews.allElementsBoundByIndex.contains(where: \.isHittable),
      app.buttons["document-edit"].firstMatch.isHittable else {
      throw blocked("An editor or unexpected modal is open; it was preserved without dismissal.", in: app)
    }
    try press(app.navigationBars.buttons["BackButton"].firstMatch, in: app)
    try require(app.buttons["library-picker"].firstMatch, in: app)
  }

  private func showReaderParagraph(_ paragraph: XCUIElement, in app: XCUIApplication) throws {
    for attempt in 0...10 {
      try ready(app)
      if paragraph.exists, paragraph.isHittable { return }
      guard attempt < 10, let reader = app.scrollViews.allElementsBoundByIndex.first(where: {
        $0.isHittable && $0.frame.height >= app.frame.height * 0.5
      }) else { break }
      reader.swipeUp(velocity: .slow)
    }
    throw blocked("The actual saved research paragraph is not readable.", in: app)
  }

  private func press(_ element: XCUIElement, in app: XCUIApplication) throws {
    try require(element, in: app)
    try ready(app)
    guard element.isEnabled, element.isHittable else { throw blocked("A required native action is unavailable: " + element.identifier, in: app) }
    element.tap()
    try ready(app)
  }

  private func ready(_ app: XCUIApplication) throws {
    guard app.state == .runningForeground else { throw blocked("Folio lost foreground; no action was retried.", in: app) }
    let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)
      .matching(identifier: "NotificationShortLookView").firstMatch
    if banner.exists {
      let expired = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: banner)
      guard XCTWaiter.wait(for: [expired], timeout: 15) == .completed else {
        throw blocked("A system banner still covers Folio; no notification was tapped or dismissed.", in: app)
      }
    }
    guard app.state == .runningForeground else { throw blocked("Folio lost foreground while waiting; no action was retried.", in: app) }
  }

  private func require(_ element: XCUIElement, in app: XCUIApplication) throws {
    guard element.waitForExistence(timeout: 15) else { throw blocked("Missing native UI: " + element.identifier, in: app) }
  }

  private func gone(_ element: XCUIElement, in app: XCUIApplication) throws {
    let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
    guard XCTWaiter.wait(for: [disappeared], timeout: 15) == .completed else {
      throw blocked("A native transition did not finish; it was not retried.", in: app)
    }
  }

  private func digest(_ body: String) -> String {
    SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private enum AlignmentError: Error { case blocked(String) }
  private func blocked(_ reason: String, in app: XCUIApplication) -> AlignmentError {
    capture(app, "final-alignment-blocked")
    print("FOLIO_FINAL_ALIGNMENT_BLOCKED \(reason)")
    return .blocked(reason)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    guard app.state == .runningForeground else {
      print("FOLIO_FINAL_CAPTURE_SKIPPED_BACKGROUND \(name)")
      return
    }
    let pixels = app.screenshot()
    guard app.state == .runningForeground else { return }
    let hierarchy = app.debugDescription
    guard app.state == .runningForeground else { return }
    let screenshot = XCTAttachment(screenshot: pixels)
    screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    let text = XCTAttachment(string: hierarchy)
    text.name = name + "-hierarchy"; text.lifetime = .keepAlways; add(text)
  }
}
