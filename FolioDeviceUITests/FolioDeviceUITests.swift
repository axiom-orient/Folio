import CryptoKit
import XCTest

/// Uses the same public research documents and native controls as a person.
/// No reset, synthetic receipt, source injection or product-only test hook.
final class FolioDeviceUITests: XCTestCase {
  private let researchTarget = CloudLibraryTarget(name: "에이전트와 기술", containerIdentifier: "iCloud.com.axient.Folio",
    workspaceID: UUID(uuidString: "c88bd7b3-a35e-4765-9e9e-b895e9f83606")!)
  private let readingLibrary = "에이전트 읽기 노트"
  private let executionNote = "도구 호출의 결과 확인"
  private let phoneObservation = "도구 호출의 응답과 실제 자료 저장 결과를 구분해서 확인한다."
  private let desktopObservation = "데스크톱에서는 원문을 다시 읽고 변경된 내용을 확인한다."
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor func testResearchScreensAndArchivedLibraries() throws {
    try skipUnidentifiedLibraryChanges("Archived-library targets need verified location identities before changing their visibility.")
    let app = launch()
    try chooseResearch(in: app)
    tap("자료함 선택", in: app)
    capture(app, "research-library-cards")
    for name in ["File transfer demo", "Folio 실기기 검증 20261013", "Folio 수신 검증 iPhone 20261013", "길게 쓴 한국어 자료함 이름도 읽기 편한 디자인 검증"] {
      for _ in 0..<3 {
        let choice = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        if !choice.exists { break }
        if !choice.isHittable { app.scrollViews.firstMatch.swipeUp() }
        choice.press(forDuration: 1.1)
        tap("목록에서 숨기기", in: app)
      }
    }
    capture(app, "research-catalog-with-preserved-archives")
    tap("닫기", in: app)
    openDocument("에이전트와 기술을 읽는 순서", in: app)
    visible("먼저 읽을 문서", in: app)
    capture(app, "research-reading-guide")
    tap("문서 옵션", in: app); tap("문서 정보", in: app)
    visible("notes/agent-reading-guide.md", in: app)
    capture(app, "research-document-information")
    tap("닫기", in: app)
    tap("문서 옵션", in: app); tap("연결된 문서", in: app)
    let evidence = app.buttons["MCP의 도구와 리소스 관계의 근거"].firstMatch
    XCTAssertTrue(evidence.waitForExistence(timeout: 15))
    evidence.tap(); visible("notes/agent-reading-guide.md", in: app)
    capture(app, "research-link-source-evidence")
    tap("닫기", in: app)
    let linked = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "MCP의 도구와 리소스")).firstMatch
    linked.tap(); visible("도구는 이름과 입력 schema", in: app)
    home(app)
    revealDocumentSearch(in: app)
    let search = app.textFields["document-search"].firstMatch
    if !search.exists { app.swipeDown() }
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap(); search.typeText("FTS5")
    openDocument("원문과 검색 인덱스의 역할", in: app)
    visible("FTS5는 SQLite의 전문 검색 모듈", in: app)
    capture(app, "research-search-opens-original-section")
    print("FOLIO_RESEARCH_SCREENS_VERIFIED")
  }

  @MainActor func testResearchDraftBackgroundRelaunchAndExplicitSave() throws {
    let app = launch(); try chooseResearch(in: app)
    createDocument(executionNote, in: app)
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 15))
    let original = try XCTUnwrap(editor.value as? String)
    editor.typeText(phoneObservation + "\n\n같은 자료를 다른 기기에서도 열어 실행 결과를 확인한다.\n")
    XCTAssertTrue((editor.value as? String)?.hasPrefix(original) == true)
    visible("저장하지 않은 편집", in: app)
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    app.terminate(); app.launch()
    openDocument(executionNote, in: app)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", phoneObservation)).firstMatch.exists)
    tap("편집 이어쓰기", in: app)
    XCTAssertTrue((app.textViews.firstMatch.value as? String)?.contains(phoneObservation) == true)
    capture(app, "research-draft-restored-after-background-and-relaunch")
    tap("저장", in: app); visible(phoneObservation, in: app)
    capture(app, "research-note-explicitly-saved")
    print("FOLIO_RESEARCH_PHONE_COMMIT")
  }

  @MainActor func testResearchPhoneToMacDelivery() throws {
    let app = launch(); try chooseResearch(in: app)
    openDocument("ReAct의 계획과 도구 실행", in: app)
    tap("문서 옵션", in: app); tap("기기로 보내기", in: app)
    let peer = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Mac")).firstMatch
    XCTAssertTrue(peer.waitForExistence(timeout: 45)); XCTAssertTrue(peer.isEnabled)
    capture(app, "research-document-and-real-destination")
    peer.tap(); print("FOLIO_RESEARCH_SENT_TO_MAC")
    visible("보냈습니다. 상대 기기에 저장되었습니다.", in: app, timeout: 180)
    capture(app, "research-phone-to-mac-confirmed-delivery")
  }

  @MainActor func testResearchMacToPhoneReceiveAndDuplicateGuard() throws {
    try skipUnidentifiedLibraryChanges("The receiving library needs a verified location identity before adding a document.")
    let app = launch(); try chooseResearch(in: app)
    print("FOLIO_RESEARCH_READY_TO_RECEIVE")
    tap("받기", in: app, timeout: 180)
    tap("document-list-options", in: app)
    tap("받은 파일", in: app)
    let received = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "에이전트와 기술을 읽는 순서"))
    XCTAssertTrue(received.firstMatch.waitForExistence(timeout: 90))
    XCTAssertEqual(received.count, 1, "Select only the expected, unambiguous received document.")
    received.firstMatch.tap()
    capture(app, "research-received-file-and-target")
    tap("문서 추가", in: app)
    visible("이미", in: app)
    XCTAssertTrue(app.buttons["문서 추가"].exists, "Failed duplicate admission must retain the received file and destination.")
    capture(app, "research-duplicate-source-rejected-with-original-retained")
    tap("다른 자료함 선택", in: app)
    chooseOrCreateReadingLibrary(in: app, pickerAlreadyOpen: true)
    tap("문서 추가", in: app)
    visible("에이전트와 기술을 읽는 순서", in: app)
    capture(app, "research-received-source-added-to-reading-library")
    print("FOLIO_RESEARCH_RECEIVED_AND_ADDED")
  }

  @MainActor func testResearchLiveCloudChangeAndReviewedMerge() throws {
    // This live-source scenario only admits one known base and one exact peer edit.
    let baseRevision = "5bafffc8f5ecf7392ccb4520eb0a6db35654f8ec17ef6d4f7a5815f8380fcf45"
    let baseBody = "67a25b6b69c0711c01384d85ac628f971c2b6976a015633c1cfcfdd47447d1f5"
    let peerRevision = "64bd4f597881d6c4c6b985858ff45e6743533368a0f20805874fb6f2c52bd309"
    let draftBody = "6420f202f7d825abeff241b166a65d2daa8f6d980d22c15596856cfee479455c"
    let mergedRevision = "5544b369cb797a4f2b7009156b256603cb06c4fc3644ca00693e3113b1f85eed"
    let title = "ReAct의 계획과 도구 실행"
    let app = launch(); try chooseResearch(in: app)
    openDocument(title, in: app)
    guard try researchSourceRevision(in: app) == baseRevision else {
      XCTFail("The source is not the exact known baseline; no edit was started."); return
    }
    guard app.buttons["편집"].firstMatch.exists else {
      XCTFail("An existing draft or unavailable editor was preserved."); return
    }
    tap("편집", in: app)
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 15))
    let original = try XCTUnwrap(editor.value as? String)
    guard digest(original) == baseBody else {
      XCTFail("The editor does not expose the exact baseline body; the source was not changed."); return
    }
    let pending = original + "\n" + phoneObservation + "\n"
    guard digest(pending) == draftBody else { XCTFail("Unexpected draft bytes."); return }
    replaceEditor(editor, with: pending, in: app)
    capture(app, "research-phone-draft-before-desktop-change")
    print("FOLIO_RESEARCH_DRAFT_READY: Mac에서 기준 원문의 '## 문서 작업에 적용할 판단' 앞에 빈 줄로 구분해 다음 문단을 삽입하고 저장: \(desktopObservation). 예상 source SHA-256: \(peerRevision). 이후 다른 편집을 중지하세요.")
    visible("새 변경을 받았습니다. 저장할 때 함께 확인합니다.", in: app, timeout: 180)
    guard try researchSourceRevision(in: app) == peerRevision else {
      XCTFail("The received source is not the expected Mac revision; nothing was committed."); return
    }
    let editors = app.textViews.matching(identifier: "document-editor")
    let saves = app.buttons.matching(identifier: "document-save")
    guard app.state == .runningForeground, editors.count == 1, editors.firstMatch.isHittable,
      app.staticTexts["editor-document-title"].firstMatch.label == title,
      let currentDraft = editors.firstMatch.value as? String, digest(currentDraft) == draftBody,
      app.staticTexts["새 변경을 받았습니다. 저장할 때 함께 확인합니다."].firstMatch.exists,
      saves.count == 1, saves.firstMatch.isEnabled, saves.firstMatch.isHittable else {
      XCTFail("The reviewed target, source indication or exact private draft changed; nothing was committed."); return
    }
    capture(app, "research-reviewed-source-revision-and-exact-draft")
    saves.firstMatch.tap()
    let edit = app.buttons["document-edit"].firstMatch
    guard edit.waitForExistence(timeout: 60), !app.buttons["document-merge-save"].firstMatch.exists else {
      capture(app, "research-unexpected-merge-choice")
      XCTFail("The independent changes did not complete automatically; no conflict choice was made."); return
    }
    guard try researchSourceRevision(in: app) == mergedRevision else {
      XCTFail("The resulting source does not match the expected complete merged bytes."); return
    }
    visible(desktopObservation, in: app); visible(phoneObservation, in: app)
    capture(app, "research-both-device-notes-preserved-after-automatic-merge")
    print("FOLIO_RESEARCH_MERGE_COMMITTED sourceSHA256=\(mergedRevision)")
  }

  @MainActor private func researchSourceRevision(in app: XCUIApplication) throws -> String {
    tap("문서 옵션", in: app); tap("문서 정보", in: app)
    let navigation = app.navigationBars["문서 정보"].firstMatch
    guard navigation.waitForExistence(timeout: 15) else { throw ResearchCheckError.unavailable }
    let forms = app.collectionViews.allElementsBoundByIndex.filter(\.isHittable)
    guard forms.count == 1, let form = forms.first,
      form.staticTexts["제목, ReAct의 계획과 도구 실행"].firstMatch.exists,
      form.staticTexts["파일, notes/react-reasoning-and-acting.md"].firstMatch.exists,
      !form.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "열었을 때의 문서 정보입니다.")).firstMatch.exists else {
      throw ResearchCheckError.unavailable
    }
    let disclosure = form.buttons["원문 버전"].firstMatch
    guard disclosure.waitForExistence(timeout: 15), disclosure.isHittable else { throw ResearchCheckError.unavailable }
    disclosure.tap()
    let revisions = form.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9a-f]{64}$"))
    guard revisions.firstMatch.waitForExistence(timeout: 15), revisions.count == 1 else { throw ResearchCheckError.unavailable }
    let revision = revisions.firstMatch.label
    let close = navigation.buttons["닫기"].firstMatch
    guard close.exists, close.isHittable else { throw ResearchCheckError.unavailable }
    close.tap()
    guard navigation.waitForNonExistence(timeout: 15) else { throw ResearchCheckError.unavailable }
    return revision
  }

  private enum ResearchCheckError: Error { case unavailable }
  private func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  @MainActor func testResearchLibraryManagementAndRules() throws {
    let app = launch(); try chooseResearch(in: app)
    tap("자료함 선택", in: app); tap("자료함 설정", in: app)
    tap("고급", in: app)
    visible("연결 규칙", in: app)
    capture(app, "research-library-management")
    tap("연결 규칙", in: app)
    visible("관계 규칙", in: app)
    capture(app, "research-relation-rules")
    tap("닫기", in: app)
    home(app); tap("document-list-options", in: app); tap("받은 파일", in: app)
    capture(app, "research-received-and-archived-originals")
    tap("닫기", in: app)
    print("FOLIO_RESEARCH_MANAGEMENT_VERIFIED")
  }

  @MainActor private func launch() -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.axient.Folio"); app.launch()
    XCTAssertTrue(app.buttons["자료함 선택"].waitForExistence(timeout: 25)); return app
  }
  @MainActor private func chooseResearch(in app: XCUIApplication) throws {
    try selectCloudLibrary(researchTarget, in: app)
    try requireSelectedCloudLibrary(researchTarget, in: app)
  }
  private func skipUnidentifiedLibraryChanges(_ reason: String) throws {
    throw XCTSkip(reason)
  }
  @MainActor private func chooseOrCreateReadingLibrary(in app: XCUIApplication, pickerAlreadyOpen: Bool = false) {
    if !pickerAlreadyOpen { tap("자료함 선택", in: app) }
    let choice = app.buttons.matching(NSPredicate(format: "label == %@", readingLibrary)).firstMatch
    if choice.exists { choice.tap(); return }
    tap("library-add", in: app); tap("새 자료함", in: app)
    let field = app.textFields["이름"]; XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + readingLibrary)
    tap("만들기", in: app)
  }
  @MainActor private func createDocument(_ title: String, in app: XCUIApplication) {
    openAdvancedDocumentCreation(in: app)
    let field = app.textFields["제목"]; XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(title)
    tap("만들기", in: app)
  }
  @MainActor private func openDocument(_ title: String, in app: XCUIApplication) {
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    if !row.exists { app.swipeUp() }
    XCTAssertTrue(row.waitForExistence(timeout: 45)); row.tap()
    XCTAssertTrue(app.buttons["문서 옵션"].waitForExistence(timeout: 15))
  }
  @MainActor private func replaceEditor(_ editor: XCUIElement, with text: String, in app: XCUIApplication) {
    editor.press(forDuration: 1.1)
    let select = app.menuItems["Select All"].firstMatch
    let button = app.buttons["Select All"].firstMatch
    if select.waitForExistence(timeout: 3) { select.tap() }
    else {
      if !button.waitForExistence(timeout: 3) { capture(app, "research-editor-selection-menu") }
      XCTAssertTrue(button.exists); button.tap()
    }
    editor.typeText(text)
    XCTAssertEqual(editor.value as? String, text)
  }
  @MainActor private func home(_ app: XCUIApplication) {
    if app.buttons["자료함 선택"].isHittable { return }
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["자료함 선택"].waitForExistence(timeout: 10))
  }
  @MainActor private func tap(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 25) {
    let button = app.buttons[label].firstMatch
    let appeared = button.waitForExistence(timeout: timeout)
    if !appeared { capture(app, "research-missing-action-" + label) }
    XCTAssertTrue(appeared, "Expected native action: \(label)"); XCTAssertTrue(button.isEnabled); button.tap()
  }
  @MainActor private func visible(_ text: String, in app: XCUIApplication, timeout: TimeInterval = 30) {
    let found = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: timeout)
    if !found { capture(app, "research-missing-result") }
    XCTAssertTrue(found, "Expected actual rendered result: \(text)")
  }
  @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-hierarchy"; tree.lifetime = .keepAlways; add(tree)
  }
}
