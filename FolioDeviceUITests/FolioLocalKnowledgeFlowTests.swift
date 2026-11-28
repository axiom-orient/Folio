import XCTest

/// A native regression over the designated local Simulator review library.
/// No source injection, cloud account, physical device or application test hook.
@MainActor
final class FolioLocalKnowledgeFlowTests: XCTestCase {
  func testEvidenceSaveDismissesSearchAndReopensOriginal() throws {
    #if !targetEnvironment(simulator)
    throw XCTSkip("This local review runs only on Simulator.")
    #endif
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "com.axient.Folio")
    app.launch()
    let picker = app.buttons["library-picker"].firstMatch
    if !picker.waitForExistence(timeout: 3), app.buttons["BackButton"].firstMatch.exists {
      app.buttons["BackButton"].firstMatch.tap()
    }
    XCTAssertTrue(picker.waitForExistence(timeout: 15))
    try XCTSkipUnless(picker.value as? String == "Ontology O2 Local Review",
      "Requires the designated local Simulator review library; existing user libraries are preserved.")
    let source = app.buttons.matching(NSPredicate(format: "label == %@", "측정 기록 O3")).firstMatch
    try XCTSkipUnless(source.waitForExistence(timeout: 5), "Requires the existing review source.")
    source.tap()
    app.buttons["문서 옵션"].firstMatch.tap()
    let ask = app.buttons["knowledge-document-open"].firstMatch
    XCTAssertTrue(ask.waitForExistence(timeout: 5))
    ask.tap()
    let input = app.textFields["knowledge-question"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText("42")
    XCTAssertEqual(input.value as? String, "42")
    app.buttons["knowledge-find"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["근거 1개"].firstMatch.waitForExistence(timeout: 20))
    let save = app.buttons["knowledge-save"].firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    save.tap()
    let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: input)
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 15), .completed,
      "Saving must leave the original search and show the created note without a blank query sheet.")
    XCTAssertTrue(app.staticTexts["근거 · 42"].firstMatch.waitForExistence(timeout: 10))
    let citation = app.links.matching(NSPredicate(format: "label CONTAINS %@", "측정 기록 O3")).firstMatch
    XCTAssertTrue(citation.waitForExistence(timeout: 5))
    citation.tap()
    let location = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "원문 · ")).firstMatch
    XCTAssertTrue(location.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["제2판"].firstMatch.exists)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "local-saved-citation-original"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
