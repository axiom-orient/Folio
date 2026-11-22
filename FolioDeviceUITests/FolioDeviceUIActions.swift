import XCTest

@MainActor func revealDocumentSearch(in app: XCUIApplication) {
  let field = app.textFields["document-search"].firstMatch
  if !field.exists {
    let button = app.buttons["document-search-toggle"].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
    if button.exists { button.tap() }
  }
  XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
}

@MainActor func openAdvancedDocumentCreation(in app: XCUIApplication) {
  let menu = app.buttons["document-list-options"].firstMatch
  XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
  if menu.exists { menu.tap() }
  let action = app.buttons["새 문서 옵션…"].firstMatch
  XCTAssertTrue(action.waitForExistence(timeout: 15), app.debugDescription)
  if action.exists { action.tap() }
}

@MainActor func openDocumentFilters(in app: XCUIApplication) {
  revealDocumentListAction("document-filters", in: app)
  app.buttons["document-filters"].firstMatch.tap()
}

@MainActor func openDocumentManagement(in app: XCUIApplication) {
  revealDocumentListAction("document-management", in: app)
  app.buttons["document-management"].firstMatch.tap()
}

@MainActor private func revealDocumentListAction(_ identifier: String, in app: XCUIApplication) {
  if !app.buttons[identifier].firstMatch.exists {
    let menu = app.buttons["document-list-options"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
    if menu.exists { menu.tap() }
  }
  XCTAssertTrue(app.buttons[identifier].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
}
