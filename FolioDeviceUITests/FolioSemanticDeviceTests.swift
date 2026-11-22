import XCTest

/// Runs on the physical phone, against a dedicated library published through
/// the Mac application's existing iCloud publication flow. Never resets data.
@MainActor
final class FolioSemanticDeviceTests: XCTestCase {
  private let library = CloudLibraryTarget(name: "한영 검색 검증 20261108", containerIdentifier: "iCloud.com.axient.Folio",
    workspaceID: UUID(uuidString: "1fdd4e23-bc72-4d0f-9cf4-9f675a202611")!)


  func testKoreanSearchAndUnrelatedQuery() throws {
    continueAfterFailure = false
    let app = try openLibrary()
    revealDocumentSearch(in: app)
    let search = app.textFields["document-search"].firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 30)); search.tap(); search.typeText("돈을 맡기고 이자를 받을 곳")
    tap("search-options", app)
    tap("semantic-search-open", app)
    let result = app.buttons["semantic-result-bank-ko"].firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 120), app.debugDescription)
    capture(app, "phone-korean-semantic-result")
    result.tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "은행은 고객이 맡긴 돈")).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
    capture(app, "phone-semantic-opens-current-source")
    openRelationReview(app)
    tap("이전 제안·작업 결과 확인", app)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "원문 반영 확인됨")).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
    capture(app, "phone-existing-receipt-after-model-upgrade")
    tap("닫기", app)
    tap("닫기", app)

    // Return through the normal navigation; the approval case checks relaunch.
    try home(app)
    revealDocumentSearch(in: app)
    let next = app.textFields["document-search"].firstMatch
    XCTAssertTrue(next.waitForExistence(timeout: 30)); replaceAll(next, with: "항성 내부 핵융합의 반응 속도", in: app)
    tap("search-options", app)
    tap("semantic-search-open", app)
    XCTAssertTrue(app.staticTexts["관련된 문서를 찾지 못했습니다."].waitForExistence(timeout: 120), app.debugDescription)
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "semantic-result-")).count, 0)
    capture(app, "phone-unrelated-query-rejected")
    replaceSemanticQuery("세면대에서 물이 한 방울씩 떨어질 때 부를 전문가", in: app)
    tap("semantic-search", app)
    XCTAssertTrue(app.buttons["semantic-result-repair-ko"].firstMatch.waitForExistence(timeout: 120), app.debugDescription)
    XCTAssertFalse(app.buttons["semantic-result-coffee-ko"].exists)
    capture(app, "phone-plumbing-reranked-without-coffee")
    replaceSemanticQuery("양자 컴퓨터 오류 보정 부호", in: app)
    tap("semantic-search", app)
    XCTAssertTrue(app.staticTexts["관련된 문서를 찾지 못했습니다."].waitForExistence(timeout: 120), app.debugDescription)
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "semantic-result-")).count, 0)
    capture(app, "phone-quantum-query-rejected")
    tap("닫기", app)
  }

  func testRelationReviewCancelApproveAndReopen() throws {
    continueAfterFailure = false
    let app = try openLibrary()
    try prepareKoreanRelationTarget(in: app)
    openDocument("밤의 휴식과 집중", in: app)
    openRelationReview(app)
    let prepare = app.buttons["검토"].firstMatch
    XCTAssertTrue(prepare.waitForExistence(timeout: 120), app.debugDescription); prepare.tap()
    XCTAssertTrue(app.buttons["semantic-approve"].firstMatch.waitForExistence(timeout: 30))
    capture(app, "phone-relation-approval")
    tap("semantic-exact-changes", app)
    capture(app, "phone-relation-exact-preview")
    tap("취소", app)
    XCTAssertFalse(app.staticTexts["연결을 저장했습니다."].exists)
    prepare.tap()
    XCTAssertTrue(app.buttons["semantic-approve"].firstMatch.waitForExistence(timeout: 30))
    tap("semantic-approve", app)
    XCTAssertTrue(app.staticTexts["연결을 저장했습니다."].waitForExistence(timeout: 90), app.debugDescription)
    capture(app, "phone-relation-approved")
    tap("이전 제안·작업 결과 확인", app)
    let accepted = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "원문 반영 확인됨")).firstMatch
    XCTAssertTrue(accepted.waitForExistence(timeout: 30), app.debugDescription)
    capture(app, "phone-operation-receipt-confirmed")
    tap("닫기", app)
    tap("닫기", app)
    app.terminate(); app.launch()
    try home(app)
    openDocument("밤의 휴식과 집중", in: app)
    openRelationReview(app); tap("이전 제안·작업 결과 확인", app)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "원문 반영 확인됨")).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
    capture(app, "phone-receipt-after-relaunch")
    tap("닫기", app)
  }

  func testReadWriteCreateAndDraftRecoveryInMinimalUI() throws {
    continueAfterFailure = false
    let app = try openLibrary()
    // This test owns only the new document created below.
    if app.textFields["document-search"].firstMatch.exists { tap("검색 닫기", app) }
    XCTAssertTrue(app.buttons["document-search-toggle"].exists)
    XCTAssertTrue(app.buttons["document-add"].exists)
    XCTAssertTrue(app.buttons["document-list-options"].exists)
    XCTAssertFalse(app.buttons["document-management"].exists)
    XCTAssertFalse(app.buttons["document-filters"].exists)
    capture(app, "phone-minimal-main")
    tap("document-add", app)
    tap("document-create", app)
    let editor = app.textViews["document-editor"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 30), app.debugDescription)
    let title = "읽고 쓰기 검증 " + String(UUID().uuidString.prefix(6))
    let text = "# " + title + "\n\n읽기와 쓰기가 바로 이어집니다. 한국어 입력을 보존합니다.\n"
    replaceAll(editor, with: text, in: app)
    XCTAssertEqual(editor.value as? String, text)
    capture(app, "phone-compose-one-action")
    app.terminate(); app.launch()
    let recovered = app.textViews["document-editor"].firstMatch
    if !recovered.waitForExistence(timeout: 20) {
      try home(app)
      openDocument("제목 없음", in: app)
      tap("document-edit", app)
    }
    XCTAssertTrue(recovered.waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertEqual(recovered.value as? String, text)
    capture(app, "phone-compose-draft-after-relaunch")
    tap("document-save", app)
    XCTAssertTrue(app.buttons["document-edit"].firstMatch.waitForExistence(timeout: 45), app.debugDescription)
    XCTAssertTrue(app.staticTexts[title].firstMatch.exists, app.debugDescription)
    capture(app, "phone-compose-saved-reader")
    // Source identity is available through Info, rather than on the reader.
    tap("문서 옵션", app); tap("문서 정보", app)
    capture(app, "phone-document-info-on-demand")
    tap("닫기", app)
  }

  private func openLibrary() throws -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.axient.Folio")
    app.launchEnvironment["FOLIO_SEMANTIC_MEMORY_TRACE"] = "1"
    app.launch(); try home(app)
    try selectCloudLibrary(library, in: app)
    try requireSelectedCloudLibrary(library, in: app)
    return app
  }
  private func prepareKoreanRelationTarget(in app: XCUIApplication) throws {
    // Edit only the known imported QA target. The normal editor preserves its
    // stable ID and type metadata; no raw-source or test-only product hook.
    let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Rest and attention")).firstMatch
    let prepared = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "수면과 다음 날의 집중")).firstMatch
    if prepared.exists && !target.exists {
      openDocument("수면과 다음 날의 집중", in: app)
      XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "충분한 수면은 다음 날의 주의력")).firstMatch.waitForExistence(timeout: 60), app.debugDescription)
      try home(app); return
    }
    openDocument("Rest and attention", in: app)
    tap("document-edit", app)
    let editor = app.textViews["document-editor"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 30), app.debugDescription)
    let original = try XCTUnwrap(editor.value as? String)
    XCTAssertTrue(original.contains("Getting sufficient sleep"), original)
    let replacement = "# 수면과 다음 날의 집중\n\n충분한 수면은 다음 날의 주의력과 집중력 회복에 도움이 된다. 규칙적인 취침 시간을 지키고 밤에 충분히 쉰다.\n"
    replaceAll(editor, with: replacement, in: app)
    XCTAssertEqual(editor.value as? String, replacement, "Only the admitted QA document body may be edited.")
    tap("저장", app)
    XCTAssertTrue(app.buttons["document-edit"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
    capture(app, "phone-prepared-korean-relation-target")
    try home(app)
  }
  private func home(_ app: XCUIApplication) throws {
    if app.buttons["library-picker"].firstMatch.waitForExistence(timeout: 10) { return }
    guard !app.textViews["document-editor"].exists, app.buttons["document-edit"].firstMatch.exists else {
      XCTFail("Preserve unfamiliar or editing screens: " + app.debugDescription); return
    }
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["library-picker"].firstMatch.waitForExistence(timeout: 30))
  }
  private func replaceSemanticQuery(_ text: String, in app: XCUIApplication) {
    let field = app.textFields["semantic-query"].firstMatch
    XCTAssertTrue(field.exists)
    replaceAll(field, with: text, in: app)
    XCTAssertEqual(field.value as? String, text)
  }
  private func openDocument(_ title: String, in app: XCUIApplication) {
    // Filter through the public search UI so a row at the screen's bottom
    // cannot receive a tap outside the visible collection viewport.
    revealDocumentSearch(in: app)
    let search = app.textFields["document-search"].firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 30), app.debugDescription)
    let value = search.value as? String ?? ""
    if value.isEmpty || value == search.placeholderValue { search.tap(); search.typeText(title) }
    else { replaceAll(search, with: title, in: app) }
    XCTAssertEqual(search.value as? String, title)
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 60), app.debugDescription)
    XCTAssertTrue(row.isHittable, app.debugDescription); row.tap()
    XCTAssertTrue(app.buttons["document-edit"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertTrue(app.buttons["document-edit"].firstMatch.isHittable, app.debugDescription)
  }
  private func replaceAll(_ element: XCUIElement, with text: String, in app: XCUIApplication) {
    element.tap()
    if element.elementType == .textField {
      element.typeKey("a", modifierFlags: .command); element.typeText(text); return
    }
    element.press(forDuration: 1.1)
    let predicate = NSPredicate(format: "label IN %@", ["Select All", "모두 선택", "전체 선택"])
    let menu = app.menuItems.matching(predicate).firstMatch
    let button = app.buttons.matching(predicate).firstMatch
    if menu.waitForExistence(timeout: 5) { menu.tap() }
    else { XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription); button.tap() }
    element.typeText(text)
  }
  private func openRelationReview(_ app: XCUIApplication) {
    tap("문서 옵션", app)
    tap("연결된 문서", app)
    tap("relation-suggestions", app)
  }
  private func tap(_ label: String, _ app: XCUIApplication) {
    let item = app.buttons[label].firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 30), label + "\n" + app.debugDescription)
    if item.exists { item.tap() }
  }
  private func capture(_ app: XCUIApplication, _ name: String) {
    let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-hierarchy"; tree.lifetime = .keepAlways; add(tree)
  }
}
