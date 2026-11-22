import CryptoKit
import XCTest

/// Two human-coordinated native phases on one existing research document.
/// The Mac commits C during WAIT_MAC, then trashes the verified merged source
/// before the second case. No new document or library is created.
@MainActor
final class FolioCrossDeviceLifecycleTests: XCTestCase {
  private enum Research {
    static let library = "AI agent"
    static let target = CloudLibraryTarget(name: library, containerIdentifier: "iCloud.com.axient.Folio",
      workspaceID: UUID(uuidString: "8231965d-1c28-4d16-bfef-e2b381304cb9")!)
    static let title = "에이전트의 성공과 안전을 무엇으로 확인할까"
    static let path = "notes/agent-evaluation-and-safety.md"
    static let filename = "agent-evaluation-and-safety.md"
    static let otherTitles = ["AI agent는 무엇이고 언제 쓰는가", "AI 에이전트의 실행 경계: 도구, 승인, 중단과 재개"]
    static let titles = otherTitles + [title]
    static let sourceA = "58705aa23702bd4b08b184f480d7e6ffc4357d44cececbda28934440ba79b12e"
    static let observedSourceC = "7076bc3bbab7ce13c73a0581200cab8969319891f636533b89ee5f6e051fd0f9"
    static let bodyA = "356429927f7a9f00be40a5c333215c83507d42be7e2167e829f8bf5e2eb950fc"
    static let observedPrivateBodyB = "0a42e1cf3fb1bc82e150e44864391b169cb5c3f7228e4f0cd5102e3dc94bcb9f"
    // Historical A+B+C remains valid for read-only checks. The new automatic
    // merge appends the phone's B after the received Mac C.
    static let historicalMergedSource = "0939f5456a0c1c68e128d65e21d839aa570d01542f2f472c65577969a5614fb5"
    static let historicalMergedBody = "a0e3a1ea7f52f89e76060d9717c9a1249f6cb3ed7db99af32d92eafb5f72060c"
    static let automaticMergedSource = "b43ddf000e4070b1a37d01bad4b6b97c387231ec8256dccfca9d88c16cefa683"
    static let automaticMergedBody = "889d8d759bfb61f73fd3085742d74c3f78a38bd3f3b82bf9279f77107b563fc5"
    static let sentenceB = "동시 편집 평가는 오래된 버전의 저장을 거부하고 편집 초안을 보존하는지 확인한다."
    static let sentenceC = "삭제·복원 평가는 복원한 문서의 식별자와 내용이 삭제 전과 같은지 확인한다."
    static let additionB = "\n" + sentenceB + "\n"
    static let additionC = "\n" + sentenceC + "\n"
  }

  func testConcurrentEditRejectsStaleSaveAndRecoversBothChanges() throws {
    continueAfterFailure = false
    let app = try launchResearch(expectedTitles: Research.titles)
    try openResearch(app)
    guard try sourceRevision(app, stage: "initial-clean-A") == Research.sourceA else {
      throw blocked("The original saved A revision changed before this phase; no input was sent.", in: app)
    }
    let editor = try beginCleanEdit(app)
    let body = try editorText(editor, in: app)
    guard digest(body) == Research.bodyA, body.count == 4847,
      !body.contains(Research.sentenceB), !body.contains(Research.sentenceC) else {
      throw blocked("This phase requires exactly the observed clean A body, without existing B or C.", in: app)
    }
    try appendAtNativeEnd(Research.additionB, to: editor, expected: body, stage: "phone-B", in: app)
    let phoneDraft = body + Research.additionB
    print("FOLIO_LIFECYCLE_WAIT_MAC sourceRevision=\(Research.sourceA) phoneBodySHA256=\(digest(phoneDraft))")
    print("FOLIO_LIFECYCLE_MAC_APPEND 빈 줄 뒤 다음 문단과 마지막 줄바꿈만 추가하고 저장: \(Research.sentenceC). 예상 source SHA-256: \(Research.observedSourceC). 이후 다른 편집을 중지하세요.")

    let stale = app.staticTexts["새 변경을 받았습니다. 저장할 때 함께 확인합니다."].firstMatch
    try require(stale, timeout: 180, in: app)
    guard same(try editorText(editor, in: app), phoneDraft),
      digest(phoneDraft) == Research.observedPrivateBodyB else {
      throw blocked("Receiving the Mac source changed the exact private phone draft.", in: app)
    }
    try commitObservedIndependentChanges(app, editor: editor)
  }

  /// Resumes only the exact observed Mac C and private A+B. It never repeats
  /// input or dismisses an unexpected conflict/recovery screen.
  func testResumeObservedConcurrentReviewAndCommitExactMerge() throws {
    continueAfterFailure = false
    let app = try launchResearch(expectedTitles: Research.titles, allowObservedDraft: true)
    if !app.textViews["document-editor"].firstMatch.isHittable {
      try openResearch(app, allowObservedDraft: true)
      try press(app.buttons["document-edit"].firstMatch, in: app)
    }
    let editor = app.textViews["document-editor"].firstMatch
    try require(editor, in: app)
    try commitObservedIndependentChanges(app, editor: editor)
  }

  /// The reviewed C revision and the exact private B are rechecked before the
  /// one Save. A conflict choice is not guessed for this independent-append case.
  private func commitObservedIndependentChanges(_ app: XCUIApplication, editor: XCUIElement) throws {
    try ready(app)
    guard app.staticTexts["editor-document-title"].firstMatch.label == Research.title,
      digest(try editorText(editor, in: app)) == Research.observedPrivateBodyB else {
      throw blocked("The phone draft is not the exact observed A+B body; no save was sent.", in: app)
    }
    let observed = try sourceRevision(app, stage: "review-before-automatic-merge")
    guard observed == Research.observedSourceC else {
      throw blocked("The current source is not the exact observed Mac C revision; the private draft was preserved.", in: app)
    }
    try ready(app)
    guard app.staticTexts["editor-document-title"].firstMatch.label == Research.title,
      app.staticTexts["새 변경을 받았습니다. 저장할 때 함께 확인합니다."].firstMatch.exists,
      digest(try editorText(editor, in: app)) == Research.observedPrivateBodyB else {
      throw blocked("The source or exact phone draft changed after review; no save was sent.", in: app)
    }
    capture(app, "lifecycle-reviewed-Mac-C-and-private-B-before-save")
    try press(app.buttons["document-save"].firstMatch, in: app)
    let edit = app.buttons["document-edit"].firstMatch
    guard edit.waitForExistence(timeout: 30), edit.label == "편집" else {
      throw blocked("The independent changes did not finish as a clean automatic merge; any conflict or draft was left for review.", in: app)
    }
    let savedRevision = try sourceRevision(app, stage: "automatic-merged-A-C-B")
    guard savedRevision == Research.automaticMergedSource else {
      throw blocked("The committed source is not the exact expected A+C+B; no further write was sent.", in: app)
    }
    let savedEditor = try beginCleanEdit(app)
    let savedBody = try editorText(savedEditor, in: app)
    let additions = Research.additionC + Research.additionB
    guard digest(savedBody) == Research.automaticMergedBody, savedBody.hasSuffix(additions),
      digest(String(savedBody.dropLast(additions.count))) == Research.bodyA else {
      throw blocked("The saved body does not match the exact original A plus both independent changes.", in: app)
    }
    try preview(app)
    capture(app, "lifecycle-automatic-merge-preserves-both-device-changes")
    print("FOLIO_LIFECYCLE_AUTOMATIC_MERGE sourceRevision=\(savedRevision) bodySHA256=\(digest(savedBody))")
  }

  func testObserveMacTrashAndRestoreExactResearchDocument() throws {
    continueAfterFailure = false
    let app = try launchResearch(expectedTitles: Research.otherTitles)
    guard !homeList(app).cells.buttons.matching(NSPredicate(format: "label == %@", Research.title)).firstMatch.exists else {
      throw blocked("The Mac-deleted target is still present on iPhone; no restore was attempted.", in: app)
    }
    print("FOLIO_LIFECYCLE_MAC_TRASH_OBSERVED remainingDocuments=2")
    try press(app.buttons["document-list-options"].firstMatch, in: app)
    openDocumentManagement(in: app)
    try require(app.navigationBars["문서 정리"].firstMatch, in: app)
    try press(app.buttons["file-browser-options"].firstMatch, in: app)
    let trash = app.buttons["toggle-trash"].firstMatch
    guard trash.label == "휴지통" else { throw blocked("The current-library file browser is not in its document-folder state.", in: app) }
    try press(trash, in: app)
    let navigation = app.navigationBars["휴지통"].firstMatch
    try require(navigation, in: app)
    let rows = app.cells.containing(.staticText, identifier: Research.filename)
    try require(rows.firstMatch, timeout: 60, in: app)
    guard rows.count == 1, !app.buttons["다시 확인"].firstMatch.exists else {
      throw blocked("The exact research trash record is missing, ambiguous or unavailable.", in: app)
    }
    let restore = rows.firstMatch.buttons["복원"].firstMatch
    try require(restore, in: app)
    guard restore.isEnabled, restore.isHittable else { throw blocked("The exact research trash payload is not ready for restore.", in: app) }
    capture(app, "lifecycle-Mac-deletion-received-as-one-recoverable-phone-trash-row")
    try press(restore, in: app)
    let confirmation = app.navigationBars["복원"].firstMatch
    try require(confirmation, in: app)
    let forms = app.collectionViews.allElementsBoundByIndex.filter(\.isHittable)
    guard forms.count == 1, let form = forms.first,
      form.staticTexts["대상, " + Research.filename].firstMatch.exists,
      form.staticTexts["원래 폴더로 복원합니다."].firstMatch.exists else {
      throw blocked("The normal restore confirmation does not identify this exact original path.", in: app)
    }
    let submit = confirmation.buttons["file-action-submit"].firstMatch
    guard submit.label == "복원" else { throw blocked("The selected action is not recoverable restoration.", in: app) }
    try press(submit, in: app)
    try gone(confirmation, in: app)
    try gone(rows.firstMatch, in: app)
    try press(navigation.buttons["닫기"].firstMatch, in: app)
    try gone(navigation, in: app)
    try requireTitles(Research.titles, in: app)
    try openResearch(app)
    let restoredRevision = try sourceRevision(app, stage: "restored-original-research")
    let editor = try beginCleanEdit(app)
    let restoredBody = try editorText(editor, in: app)
    try requireKnownMergedSource(revision: restoredRevision, body: restoredBody, in: app)
    try preview(app)
    capture(app, "lifecycle-restored-original-research-reader")
    print("FOLIO_LIFECYCLE_RESTORED sourceRevision=\(restoredRevision) bodySHA256=\(digest(restoredBody))")
  }

  /// One final read after the existing document was restored on Mac. This does
  /// not repeat conflict, deletion, restoration, or text input on the phone.
  func testReadRestoredResearchReceiptOnly() throws {
    continueAfterFailure = false
    let app = try launchResearch(expectedTitles: Research.titles)
    try openResearch(app)
    let revision = try sourceRevision(app, stage: "final-restored-read-only")
    guard [Research.historicalMergedSource, Research.automaticMergedSource].contains(revision) else {
      throw blocked("The restored source does not match a known exact merged revision; no write was sent.", in: app)
    }
    let editor = try beginCleanEdit(app)
    try requireKnownMergedSource(revision: revision, body: editorText(editor, in: app), in: app)
    try preview(app)
    capture(app, "simple-editing-restored-research-on-iphone")
    print("FOLIO_RESTORED_RECEIPT_VERIFIED sourceRevision=\(revision) sourceWrites=0")
  }

  private func requireKnownMergedSource(revision: String, body: String, in app: XCUIApplication) throws {
    let expectedBody: String
    let additions: String
    switch revision {
    case Research.historicalMergedSource:
      expectedBody = Research.historicalMergedBody
      additions = Research.additionB + Research.additionC
    case Research.automaticMergedSource:
      expectedBody = Research.automaticMergedBody
      additions = Research.additionC + Research.additionB
    default:
      throw blocked("The restored source revision is not a known exact merge.", in: app)
    }
    guard digest(body) == expectedBody, body.hasSuffix(additions),
      digest(String(body.dropLast(additions.count))) == Research.bodyA else {
      throw blocked("The restored body does not match its exact merged revision; no further write was sent.", in: app)
    }
  }

  private func launchResearch(expectedTitles: [String], allowObservedDraft: Bool = false) throws -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.axient.Folio")
    app.launch(); try ready(app)
    let editors = app.textViews.matching(identifier: "document-editor")
    if allowObservedDraft, editors.firstMatch.isHittable {
      guard editors.count == 1, app.staticTexts["editor-document-title"].firstMatch.label == Research.title,
        digest(try editorText(editors.firstMatch, in: app)) == Research.observedPrivateBodyB else {
        throw blocked("The open editor is not the exact resumable draft; no navigation was sent.", in: app)
      }
      // Preview preserves the draft and permits confirming its cloud location.
      try preview(app)
    }
    if !app.buttons["library-picker"].firstMatch.isHittable { try home(app) }
    let picker = app.buttons["library-picker"].firstMatch
    try require(picker, in: app)
    let frame = picker.frame
    guard picker.isHittable, !frame.isEmpty, app.frame.contains(frame), frame.maxY < app.frame.midY else {
      throw blocked("The library picker has no safe observed activation frame.", in: app)
    }
    try selectCloudLibrary(Research.target, in: app)
    try requireSelectedCloudLibrary(Research.target, in: app)
    revealDocumentSearch(in: app)
    let search = app.textFields["document-search"].firstMatch
    try require(search, in: app)
    guard search.value == nil || search.value as? String == "" || search.value as? String == search.placeholderValue else {
      throw blocked("An existing search was preserved rather than changed.", in: app)
    }
    openDocumentFilters(in: app)
    let browse = app.descendants(matching: .any).matching(identifier: "document-browse-sheet").firstMatch
    try require(browse, in: app)
    try press(browse.buttons["document-browse-all"].firstMatch, in: app); try gone(browse, in: app)
    guard picker.value as? String == Research.library,
      !app.staticTexts["document-list-scope"].firstMatch.exists else {
      throw blocked("The current research library and unfiltered scope are not exact.", in: app)
    }
    try requireTitles(expectedTitles, allowObservedDraft: allowObservedDraft, in: app)
    return app
  }

  private func openResearch(_ app: XCUIApplication, allowObservedDraft: Bool = false) throws {
    let rows = homeList(app).cells.buttons.matching(NSPredicate(format: "label == %@", Research.title))
    try require(rows.firstMatch, in: app)
    guard rows.count == 1 else { throw blocked("The exact research row is ambiguous.", in: app) }
    try press(rows.firstMatch, in: app)
    let edit = app.buttons["document-edit"].firstMatch
    try require(edit, in: app)
    guard edit.label == (allowObservedDraft ? "편집 이어쓰기" : "편집") else { throw blocked("An unexpected private draft was preserved.", in: app) }
  }

  private func beginCleanEdit(_ app: XCUIApplication) throws -> XCUIElement {
    try press(app.buttons["document-edit"].firstMatch, in: app)
    let editor = app.textViews["document-editor"].firstMatch
    try require(editor, in: app)
    guard app.staticTexts["editor-document-title"].firstMatch.label == Research.title,
      !app.buttons["document-save"].firstMatch.isEnabled,
      !(try editorText(editor, in: app)).hasPrefix("---") else {
      throw blocked("The clean native editor is not this exact research document.", in: app)
    }
    return editor
  }

  private func appendAtNativeEnd(_ addition: String, to editor: XCUIElement, expected: String,
    stage: String, in app: XCUIApplication
  ) throws {
    try ready(app)
    guard same(try editorText(editor, in: app), expected), addition.count < 100 else {
      throw blocked("The editor changed before the one short native append.", in: app)
    }
    try press(editor, in: app)
    editor.press(forDuration: 1.1); try ready(app)
    let predicate = NSPredicate(format: "label IN %@", ["Select All", "모두 선택"])
    let items = app.menuItems.matching(predicate)
    let buttons = app.buttons.matching(predicate)
    let selectAll: XCUIElement
    if items.firstMatch.waitForExistence(timeout: 2), items.count == 1, items.firstMatch.isHittable {
      selectAll = items.firstMatch
    } else if buttons.firstMatch.waitForExistence(timeout: 5), buttons.count == 1, buttons.firstMatch.isHittable {
      selectAll = buttons.firstMatch
    } else {
      throw blocked("The actual edit menu does not expose one Select All action; no movement fallback was sent.", in: app)
    }
    try press(selectAll, in: app)
    capture(app, "lifecycle-native-full-selection-" + stage)
    guard same(try editorText(editor, in: app), expected) else { throw blocked("Opening native selection changed the body.", in: app) }
    editor.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
    try ready(app)
    capture(app, "lifecycle-native-selection-collapsed-to-end-" + stage)
    guard same(try editorText(editor, in: app), expected) else { throw blocked("Collapsing native selection changed the body.", in: app) }
    editor.typeText(addition); try ready(app)
    let actual = try editorText(editor, in: app)
    attachText(actual, name: "lifecycle-native-short-append-result-" + stage, in: app)
    guard same(actual, expected + addition) else {
      throw blocked("The short input did not append at the true end; the private draft was kept without saving.", in: app)
    }
    print("FOLIO_LIFECYCLE_EXACT_APPEND stage=\(stage) bodySHA256=\(digest(actual)) characters=\(actual.count)")
  }

  private func sourceRevision(_ app: XCUIApplication, stage: String) throws -> String {
    try press(app.buttons["문서 옵션"].firstMatch, in: app)
    try press(app.buttons["문서 정보"].firstMatch, in: app)
    let navigation = app.navigationBars["문서 정보"].firstMatch
    try require(navigation, in: app)
    let forms = app.collectionViews.allElementsBoundByIndex.filter(\.isHittable)
    guard forms.count == 1, let form = forms.first else { throw blocked("The active source-information form is ambiguous.", in: app) }
    for label in ["제목, " + Research.title, "파일, " + Research.path,
      "태그, AI 에이전트 · 평가 · 안전성 · 프롬프트 주입 · ai-agent"] {
      try require(form.staticTexts[label].firstMatch, in: app)
    }
    guard !form.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "열었을 때의 문서 정보입니다.")).firstMatch.exists else {
      throw blocked("The displayed source information became stale.", in: app)
    }
    try press(form.buttons["원문 버전"].firstMatch, in: app)
    let revisions = form.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9a-f]{64}$"))
    try require(revisions.firstMatch, in: app)
    guard revisions.count == 1 else { throw blocked("The actual source revision is ambiguous.", in: app) }
    let revision = revisions.firstMatch.label
    attachText(form.debugDescription, name: "lifecycle-source-information-" + stage, in: app)
    print("FOLIO_LIFECYCLE_SOURCE stage=\(stage) sourceRevision=\(revision)")
    try press(navigation.buttons["닫기"].firstMatch, in: app); try gone(navigation, in: app)
    return revision
  }

  private func requireTitles(_ titles: [String], allowObservedDraft: Bool = false, in app: XCUIApplication) throws {
    for title in titles {
      try require(homeList(app).cells.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch, in: app)
    }
    let cells = homeList(app).cells.allElementsBoundByIndex.filter {
      !$0.staticTexts["document-list-scope"].firstMatch.exists && !$0.buttons["document-filters"].firstMatch.exists
    }
    let rows = cells.map { $0.buttons.allElementsBoundByIndex }
    guard rows.count == titles.count, rows.allSatisfy({ $0.count == 1 }),
      Set(rows.compactMap { $0.first?.label }) == Set(titles),
      rows.compactMap(\.first).allSatisfy({ ($0.value as? String)?.contains("저장하지 않은 편집") != true
        || (allowObservedDraft && $0.label == Research.title) }) else {
      throw blocked("The exact clean research-document set is not present; private edits were preserved.", in: app)
    }
  }

  private func preview(_ app: XCUIApplication) throws {
    try press(app.buttons["문서 옵션"].firstMatch, in: app)
    try press(app.buttons["미리 보기"].firstMatch, in: app)
    try gone(app.textViews["document-editor"].firstMatch, in: app)
  }

  private func homeList(_ app: XCUIApplication) -> XCUIElement {
    app.collectionViews.allElementsBoundByIndex.last(where: \.isHittable) ?? app.collectionViews.firstMatch
  }

  private func home(_ app: XCUIApplication) throws {
    guard !app.textViews.allElementsBoundByIndex.contains(where: \.isHittable),
      app.buttons["document-edit"].firstMatch.isHittable else { throw blocked("An editor or unexpected modal was preserved without dismissal.", in: app) }
    try press(app.navigationBars.buttons["BackButton"].firstMatch, in: app)
    try require(app.buttons["library-picker"].firstMatch, in: app)
  }

  private func editorText(_ editor: XCUIElement, in app: XCUIApplication) throws -> String {
    guard let value = editor.value as? String else { throw blocked("The native text value is unavailable.", in: app) }
    return value
  }

  private func same(_ first: String, _ second: String) -> Bool { Data(first.utf8) == Data(second.utf8) }
  private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

  private func ready(_ app: XCUIApplication) throws {
    guard app.state == .runningForeground else { throw blocked("Folio lost foreground; no input or write was retried.", in: app) }
    let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)
      .matching(identifier: "NotificationShortLookView").firstMatch
    if banner.exists { try gone(banner, in: app) }
    guard app.state == .runningForeground else { throw blocked("Folio lost foreground while waiting for a system banner.", in: app) }
  }

  private func press(_ element: XCUIElement, in app: XCUIApplication) throws {
    try require(element, in: app); try ready(app)
    guard element.isEnabled, element.isHittable else { throw blocked("A required native action is unavailable: " + element.identifier, in: app) }
    element.tap(); try ready(app)
  }

  private func require(_ element: XCUIElement, timeout: TimeInterval = 15, in app: XCUIApplication) throws {
    guard element.waitForExistence(timeout: timeout) else { throw blocked("Missing native UI: " + element.identifier, in: app) }
  }

  private func gone(_ element: XCUIElement, in app: XCUIApplication) throws {
    let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
    guard XCTWaiter.wait(for: [absent], timeout: 20) == .completed else { throw blocked("The native transition did not finish; it was not retried.", in: app) }
  }

  private enum LifecycleError: Error { case blocked(String) }
  private func blocked(_ reason: String, in app: XCUIApplication) -> LifecycleError {
    capture(app, "lifecycle-blocked")
    print("FOLIO_LIFECYCLE_BLOCKED \(reason)")
    return .blocked(reason)
  }

  private func attachText(_ value: String, name: String, in app: XCUIApplication) {
    guard app.state == .runningForeground else { return }
    let attachment = XCTAttachment(string: value)
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    guard app.state == .runningForeground else { print("FOLIO_LIFECYCLE_CAPTURE_SKIPPED_BACKGROUND \(name)"); return }
    let pixels = app.screenshot()
    guard app.state == .runningForeground else { return }
    let hierarchy = app.debugDescription
    guard app.state == .runningForeground else { return }
    let screenshot = XCTAttachment(screenshot: pixels)
    screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    attachText(hierarchy, name: name + "-hierarchy", in: app)
  }
}
