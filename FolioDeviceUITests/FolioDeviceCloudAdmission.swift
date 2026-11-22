import XCTest

/// The expected location must be configured independently of the displayed name.
struct CloudLibraryTarget {
  let name: String
  let containerIdentifier: String?
  let workspaceID: UUID

  var accessibilityIdentifier: String {
    let container = containerIdentifier.map { "container." + Data($0.utf8).base64EncodedString() } ?? "default"
    return "folio-library.cloud." + container + "." + workspaceID.uuidString.lowercased()
  }
}

/// Select only an observed iCloud choice in the active picker. Opening a hidden
/// choice does not restore it to the visible library catalog.
@MainActor
func selectCloudLibrary(_ target: CloudLibraryTarget, in app: XCUIApplication) throws {
  let navigation = try openCloudLibraryPicker(in: app)
  let choice = try findCloudLibrary(target, in: app, navigation: navigation, timeout: 180)
  guard app.state == .runningForeground, navigation.buttons["닫기"].firstMatch.isHittable,
    cloudLibraryChoices(target, in: app).count == 1, matchesCloudLibrary(choice, target: target),
    choice.isEnabled, choice.isHittable else {
    throw CloudAdmissionError.unconfirmed
  }
  choice.tap()
  guard navigation.waitForNonExistence(timeout: 90), app.state == .runningForeground else {
    throw CloudAdmissionError.unconfirmed
  }
  let picker = app.buttons["library-picker"].firstMatch
  if !picker.waitForExistence(timeout: 5) {
    // Opening a library may restore its last reader. Never leave an editor or
    // an unfamiliar screen on behalf of a test.
    let editor = app.textViews["document-editor"].firstMatch
    let reader = app.buttons["document-edit"].firstMatch
    let back = app.navigationBars.buttons.element(boundBy: 0)
    guard !editor.exists, reader.exists, reader.isHittable,
      back.exists, back.isHittable else { throw CloudAdmissionError.unconfirmed }
    back.tap()
  }
  guard picker.waitForExistence(timeout: 90), picker.isHittable,
    picker.value as? String == target.name else { throw CloudAdmissionError.unconfirmed }
}

/// The picker must report the selected cloud location, not merely the same name.
@MainActor
func requireSelectedCloudLibrary(_ target: CloudLibraryTarget, in app: XCUIApplication) throws {
  let navigation = try openCloudLibraryPicker(in: app)
  let choice = try findCloudLibrary(target, in: app, navigation: navigation, timeout: 30)
  let choices = cloudLibraryChoices(target, in: app)
  let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == YES"), object: choice)
  let close = navigation.buttons["닫기"].firstMatch
  guard XCTWaiter.wait(for: [selected], timeout: 30) == .completed,
    app.state == .runningForeground, choices.count == 1, matchesCloudLibrary(choice, target: target), choice.isSelected,
    close.isHittable else { throw CloudAdmissionError.unconfirmed }
  close.tap()
  guard navigation.waitForNonExistence(timeout: 30) else { throw CloudAdmissionError.unconfirmed }
}

@MainActor
private func openCloudLibraryPicker(in app: XCUIApplication) throws -> XCUIElement {
  guard app.state == .runningForeground else { throw CloudAdmissionError.unconfirmed }
  let picker = app.buttons["library-picker"].firstMatch
  guard picker.waitForExistence(timeout: 30), picker.isHittable else { throw CloudAdmissionError.unconfirmed }
  picker.tap()
  let navigation = app.navigationBars["자료함"].firstMatch
  let close = navigation.buttons["닫기"].firstMatch
  let scroll = app.scrollViews["library-scroll"].firstMatch
  guard close.waitForExistence(timeout: 30), close.isHittable,
    scroll.waitForExistence(timeout: 30) else { throw CloudAdmissionError.unconfirmed }
  return navigation
}

@MainActor
private func cloudLibraryChoices(_ target: CloudLibraryTarget, in app: XCUIApplication) -> XCUIElementQuery {
  app.buttons.matching(identifier: target.accessibilityIdentifier)
}

@MainActor
private func matchesCloudLibrary(_ choice: XCUIElement, target: CloudLibraryTarget) -> Bool {
  choice.identifier == target.accessibilityIdentifier && choice.label == target.name
    && (choice.value as? String)?.contains("iCloud") == true
}

@MainActor
private func findCloudLibrary(_ target: CloudLibraryTarget, in app: XCUIApplication,
  navigation: XCUIElement, timeout: TimeInterval
) throws -> XCUIElement {
  let close = navigation.buttons["닫기"].firstMatch
  let scroll = app.scrollViews["library-scroll"].firstMatch
  let choices = cloudLibraryChoices(target, in: app)
  let hidden = app.buttons["숨긴 자료함"].firstMatch
  let deadline = Date().addingTimeInterval(timeout)
  var expandedHidden = false
  var swipes = 0

  while Date() < deadline {
    guard app.state == .runningForeground, close.exists, close.isHittable,
      scroll.exists, scroll.isHittable else { throw CloudAdmissionError.unconfirmed }
    guard choices.count <= 1 else { throw CloudAdmissionError.unconfirmed }
    if choices.count == 1, matchesCloudLibrary(choices.firstMatch, target: target),
      isSafeLibraryTarget(choices.firstMatch, scroll: scroll, navigation: navigation, app: app) {
      return choices.firstMatch
    }
    if !expandedHidden, isSafeLibraryTarget(hidden, scroll: scroll, navigation: navigation, app: app) {
      hidden.tap()
      expandedHidden = true
      continue
    }

    let viewport = scroll.frame.intersection(app.frame)
    let top = max(viewport.minY, navigation.frame.maxY) + 12
    let bottom = viewport.maxY - 24
    guard viewport.width > 40, bottom - top > 100 else { throw CloudAdmissionError.unconfirmed }
    // The drag starts and ends inside the picker scroll view. Never fall back
    // to an underlying document list if the sheet disappears.
    let x = viewport.midX - app.frame.minX
    let targetAbove = choices.firstMatch.exists && choices.firstMatch.frame.midY < top
    let down = targetAbove || (swipes / 8).isMultiple(of: 2) == false
    let startY = down ? top + (bottom - top) * 0.4 : top + (bottom - top) * 0.7
    let endY = down ? top + (bottom - top) * 0.7 : top + (bottom - top) * 0.4
    let origin = app.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: x, dy: startY - app.frame.minY))
      .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: x, dy: endY - app.frame.minY)))
    swipes += 1
  }
  throw CloudAdmissionError.unconfirmed
}

@MainActor
private func isSafeLibraryTarget(_ element: XCUIElement, scroll: XCUIElement,
  navigation: XCUIElement, app: XCUIApplication
) -> Bool {
  guard element.exists, element.isHittable, !element.frame.isEmpty else { return false }
  let frame = element.frame
  let viewport = scroll.frame.intersection(app.frame)
  return frame.midX > viewport.minX + 8 && frame.midX < viewport.maxX - 8
    && frame.midY > max(viewport.minY, navigation.frame.maxY) + 4
    && frame.midY < viewport.maxY - 24
}

private enum CloudAdmissionError: Error { case unconfirmed }
