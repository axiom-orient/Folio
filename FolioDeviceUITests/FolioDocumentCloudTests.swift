import CryptoKit
import XCTest

/// Physical-device checks use only a dedicated real iCloud library and native controls.
/// The Mac creates the library and baseline; no product reset or source injection is used.
@MainActor
final class FolioDocumentCloudTests: XCTestCase {
  private let library = CloudLibraryTarget(name: "Folio iCloud 검증 20261022-A",
    containerIdentifier: "iCloud.com.axient.Folio", workspaceID: UUID(uuidString: "0aad1085-a55f-4571-bf32-d96df65cc2a8")!)
  private let baselineTitle = "Mac 기준 문서"
  private let baselineMarker = "MAC_BASE_20261022"
  private let phoneMarker = "PHONE_COMMIT_20261022"

  func testSelectDedicatedCloudLibrary() throws {
    continueAfterFailure = false
    let app = try launchDedicatedLibrary()
    capture(app, "phone-dedicated-library-selection-only")
  }

  func testCloudReadAndPhoneCommit() throws {
    continueAfterFailure = false
    let app = try launchDedicatedLibrary()
    defer { capture(app, "phone-cloud-final-state") }
    capture(app, "phone-cloud-launch")
    openDocument(baselineTitle, in: app)
    visible(baselineMarker, in: app, timeout: 90)
    capture(app, "phone-cloud-mac-baseline-read")

    home(app)
    let title = "iPhone 저장 검증 20261022-" + String(UUID().uuidString.prefix(8))
    print("FOLIO_QA_PHONE_DOCUMENT \(title)")
    openAdvancedDocumentCreation(in: app)
    let titleField = app.textFields["제목"].firstMatch
    require(titleField, in: app, stage: "new-document-title")
    titleField.tap()
    titleField.typeText(title)
    tap("만들기", in: app)
    let editor = app.textViews.firstMatch
    require(editor, in: app, stage: "new-document-editor")
    let original = try XCTUnwrap(editor.value as? String)
    editor.typeText("\n\n" + phoneMarker + "\n")
    let draft = try XCTUnwrap(editor.value as? String)
    XCTAssertTrue(draft.hasPrefix(original), "Typing must preserve the generated document identity and heading.")
    XCTAssertTrue(draft.contains(phoneMarker))
    visible("저장하지 않은 편집", in: app)
    capture(app, "phone-cloud-unsaved-document")
    tap("저장", in: app)
    visible(phoneMarker, in: app)
    require(app.buttons["편집"].firstMatch, in: app, stage: "saved-reader")
    XCTAssertFalse(app.textViews.firstMatch.exists, "The explicit save must return to the saved reader.")
    capture(app, "phone-cloud-explicit-commit")
    print("FOLIO_QA_PHONE_COMMIT \(title) \(phoneMarker)")

    tap("문서 옵션", in: app)
    tap("문서 정보", in: app)
    capture(app, "phone-cloud-committed-document-information")
    tap("닫기", in: app)
  }

  func testPhoneMetadataSurvivesBackgroundAndResume() throws {
    continueAfterFailure = false
    let app = try launchDedicatedLibrary()
    defer { capture(app, "phone-metadata-final-state") }
    let title = try createSavedDocument(prefix: "iPhone 메타데이터 검증", marker: "PHONE_METADATA_BASE_20261022", in: app)
    let updatedTitle = title + " 변경"
    tap("문서 옵션", in: app)
    tap("제목·태그 편집…", in: app)
    let titleField = app.textFields["metadata-title"].firstMatch
    require(titleField, in: app, stage: "metadata-title")
    replaceText(titleField, with: updatedTitle, in: app)
    let tagField = app.textFields["metadata-new-tag"].firstMatch
    require(tagField, in: app, stage: "metadata-new-tag")
    tagField.tap(); tagField.typeText("기기검증")
    capture(app, "phone-metadata-before-background")
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 15))
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    require(titleField, in: app, stage: "metadata-form-after-resume")
    XCTAssertEqual(titleField.value as? String, updatedTitle)
    XCTAssertEqual(tagField.value as? String, "기기검증")
    capture(app, "phone-metadata-form-preserved-after-resume")
    tap("metadata-save", in: app)
    gone(titleField, in: app, stage: "metadata-save-dismissed")
    visible(updatedTitle, in: app)
    visible("PHONE_METADATA_BASE_20261022", in: app)
    tap("문서 옵션", in: app); tap("문서 정보", in: app)
    visible("기기검증", in: app)
    capture(app, "phone-metadata-saved-title-and-tag")
    print("FOLIO_QA_METADATA_COMMIT \(updatedTitle) 기기검증")
    tap("닫기", in: app)
  }

  func testPhoneFileRenameFolderMoveTrashAndRestore() throws {
    continueAfterFailure = false
    let app = try launchDedicatedLibrary()
    defer { capture(app, "phone-file-final-state") }
    let title = try createSavedDocument(prefix: "iPhone 파일 검증", marker: "PHONE_FILE_LIFECYCLE_20261022", in: app)
    let suffix = String(UUID().uuidString.prefix(8))
    let filename = "phone-file-" + suffix + ".md"
    let folder = "기기폴더-" + suffix

    tap("문서 옵션", in: app); tap("이름 변경…", in: app)
    let nameField = app.textFields["file-action-name"].firstMatch
    require(nameField, in: app, stage: "rename-name")
    replaceText(nameField, with: filename, in: app)
    tap("file-action-submit", in: app)
    gone(nameField, in: app, stage: "rename-completed")
    XCTAssertEqual(documentPath(in: app), "notes/" + filename)
    capture(app, "phone-file-renamed-reader")

    openFileManagement(in: app)
    tap("create-folder", in: app)
    let folderField = app.textFields["file-action-name"].firstMatch
    require(folderField, in: app, stage: "create-folder-name")
    folderField.tap(); folderField.typeText(folder)
    tap("file-action-submit", in: app)
    gone(folderField, in: app, stage: "folder-created")
    require(app.buttons.matching(NSPredicate(format: "label == %@", folder)).firstMatch,
      in: app, stage: "created-folder-row")
    capture(app, "phone-file-created-folder")
    tap("닫기", in: app)
    openDocument(title, in: app)
    tap("문서 옵션", in: app); tap("이동…", in: app)
    let destination = app.descendants(matching: .any).matching(identifier: "file-action-destination").firstMatch
    require(destination, in: app, stage: "move-destination-picker")
    destination.tap(); tap(folder, in: app)
    tap("file-action-submit", in: app)
    gone(destination, in: app, stage: "move-completed")
    let path = "notes/" + folder + "/" + filename
    XCTAssertEqual(documentPath(in: app), path)
    visible("PHONE_FILE_LIFECYCLE_20261022", in: app)
    capture(app, "phone-file-moved-reader")
    print("FOLIO_QA_PHONE_FILE_MOVED \(title) \(path)")

    tap("문서 옵션", in: app); tap("휴지통으로 이동…", in: app)
    tap("file-action-submit", in: app)
    openFileManagement(in: app); tap("toggle-trash", in: app)
    let displayedPath = String(path.dropFirst("notes/".count))
    let trashRow = app.cells.containing(.staticText, identifier: displayedPath).firstMatch
    scrollIntoView(trashRow, in: app, stage: "trashed-original-path")
    capture(app, "phone-file-soft-trash")
    print("FOLIO_QA_PHONE_FILE_TRASHED \(title) \(path)")
    let restore = trashRow.buttons["복원"].firstMatch
    require(restore, in: app, stage: "restore-this-document")
    restore.tap(); tap("file-action-submit", in: app)
    gone(app.buttons["file-action-submit"].firstMatch, in: app, stage: "restore-completed")
    gone(trashRow, in: app, stage: "restored-document-left-trash")
    capture(app, "phone-file-restored-from-trash")
    tap("닫기", in: app)
    openDocument(title, in: app)
    visible("PHONE_FILE_LIFECYCLE_20261022", in: app)
    XCTAssertEqual(documentPath(in: app), path)
    capture(app, "phone-file-restored-reader")
    print("FOLIO_QA_PHONE_FILE_RESTORED \(title) \(path)")
  }

  // Keep the documented selector; this phase now exercises the admitted
  // independent-append merge and refuses an unexpected conflict or source.
  func testConcurrentCloudEditRequiresExplicitRecovery() throws {
    continueAfterFailure = false
    let app = try launchDedicatedLibrary()
    defer { capture(app, "phone-concurrent-final-state") }
    let baseMarker = "PHONE_CONCURRENT_BASE_20261022"
    let draftMarker = "PHONE_CONCURRENT_DRAFT_20261022"
    let macMarker = "MAC_CONCURRENT_COMMIT_20261022"
    let title = try createSavedDocument(prefix: "iPhone 동시 편집 검증", marker: baseMarker, in: app)
    let path = documentPath(in: app)
    let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard path == "notes/" + id + ".md", let uuid = UUID(uuidString: id),
      id == uuid.uuidString.lowercased() else {
      throw ConcurrentCheckError.blocked("The new document path is not its expected stable UUID; no concurrent edit was started.")
    }
    let baselineRevision = try concurrentRevision(in: app, title: title, path: path, stage: "baseline")
    tap("편집", in: app)
    let editor = app.textViews["document-editor"].firstMatch
    require(editor, in: app, stage: "concurrent-editor")
    let original = try XCTUnwrap(editor.value as? String)
    let originalSource = "---\nid: " + id + "\n---\n" + original
    guard concurrentDigest(originalSource) == baselineRevision,
      original.contains(baseMarker), !original.contains(draftMarker), !original.contains(macMarker),
      original.utf8.last == 10, app.staticTexts["editor-document-title"].firstMatch.label == title else {
      throw ConcurrentCheckError.blocked("The captured baseline body, identity and complete source revision do not match.")
    }
    let localAddition = "\n" + draftMarker + "\n"
    let macAddition = "\n" + macMarker + "\n"
    let phoneDraft = original + localAddition
    let expectedMacRevision = concurrentDigest(originalSource + macAddition)
    replaceText(editor, with: phoneDraft, in: app)
    guard Data((editor.value as? String ?? "").utf8) == Data(phoneDraft.utf8) else {
      throw ConcurrentCheckError.blocked("The phone draft is not the exact admitted baseline plus its addition.")
    }
    capture(app, "phone-concurrent-draft-before-mac-change")
    print("FOLIO_QA_CONCURRENT_DRAFT \(title) \(path) baseSHA256=\(baselineRevision) expectedMacSHA256=\(expectedMacRevision) phoneBodySHA256=\(concurrentDigest(phoneDraft))")
    print("FOLIO_QA_CONCURRENT_MAC_APPEND Exactly append one blank line, \(macMarker), and a final newline to the captured source; do not change metadata or other content, and stop further edits.")
    visible("새 변경을 받았습니다. 저장할 때 함께 확인합니다.", in: app, timeout: 180)
    guard Data((editor.value as? String ?? "").utf8) == Data(phoneDraft.utf8) else {
      throw ConcurrentCheckError.blocked("The received change altered the preserved phone draft.")
    }
    // Inspect the captured source revision before the first Save: Save may
    // automatically commit, so a later confirmation is not an admission gate.
    tap("문서 옵션", in: app); tap("미리 보기", in: app)
    visible(baseMarker, in: app); visible(macMarker, in: app)
    let receivedRevision = try concurrentRevision(in: app, title: title, path: path, stage: "reviewed-mac")
    guard receivedRevision == expectedMacRevision else {
      throw ConcurrentCheckError.blocked("The received source is not exactly the baseline plus the requested Mac addition; the draft was preserved.")
    }
    tap("편집 이어쓰기", in: app)
    let resumed = app.textViews["document-editor"].firstMatch
    require(resumed, in: app, stage: "concurrent-preserved-draft")
    guard app.staticTexts["editor-document-title"].firstMatch.label == title,
      Data((resumed.value as? String ?? "").utf8) == Data(phoneDraft.utf8),
      app.staticTexts["새 변경을 받았습니다. 저장할 때 함께 확인합니다."].firstMatch.exists else {
      throw ConcurrentCheckError.blocked("The reviewed document or exact phone draft changed before Save.")
    }
    capture(app, "phone-concurrent-reviewed-source-and-draft")
    tap("저장", in: app)
    let savedReader = app.buttons["document-edit"].firstMatch
    require(savedReader, in: app, timeout: 90, stage: "concurrent-auto-merge-reader")
    guard savedReader.label == "편집", !app.buttons["document-merge-save"].firstMatch.exists else {
      throw ConcurrentCheckError.blocked("The independent append did not complete automatically; any unresolved draft remains for review.")
    }
    let expectedMergedSource = originalSource + macAddition + localAddition
    let savedRevision = try concurrentRevision(in: app, title: title, path: path, stage: "merged")
    guard savedRevision == concurrentDigest(expectedMergedSource) else {
      throw ConcurrentCheckError.blocked("The saved source revision does not equal the exact reviewed baseline, Mac addition and phone addition.")
    }
    tap("편집", in: app)
    let savedEditor = app.textViews["document-editor"].firstMatch
    require(savedEditor, in: app, stage: "concurrent-merged-body")
    guard Data((savedEditor.value as? String ?? "").utf8) == Data((original + macAddition + localAddition).utf8) else {
      throw ConcurrentCheckError.blocked("The saved body does not preserve both reviewed changes in their expected order.")
    }
    tap("문서 옵션", in: app); tap("미리 보기", in: app)
    capture(app, "phone-concurrent-both-device-edits-preserved")
    print("FOLIO_QA_CONCURRENT_MERGED \(title) \(path) sourceSHA256=\(savedRevision) bodySHA256=\(concurrentDigest(original + macAddition + localAddition))")
  }

  /// Review C, then wait for a distinct C2 before the first Save. The first
  /// attempt must leave C2 and the private draft intact; confirming C2 permits retry.
  func testReviewedCloudSourceChangingBeforeSavePreservesSourceAndDraft() throws {
    continueAfterFailure = false
    let app = try launchDedicatedLibrary()
    defer { capture(app, "phone-reviewed-source-race-final-state") }
    let baseMarker = "PHONE_REVIEW_RACE_BASE_20261022"
    let draftMarker = "PHONE_REVIEW_RACE_DRAFT_20261022"
    let macMarker = "MAC_REVIEW_RACE_C_20261022"
    let laterMarker = "MAC_REVIEW_RACE_C2_20261022"
    let title = try createSavedDocument(prefix: "iPhone 확인 후 변경 검증", marker: baseMarker, in: app)
    let path = documentPath(in: app)
    let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard path == "notes/" + id + ".md", let uuid = UUID(uuidString: id),
      id == uuid.uuidString.lowercased() else {
      throw ConcurrentCheckError.blocked("The target is not the newly created UUID document.")
    }
    let baselineRevision = try concurrentRevision(in: app, title: title, path: path, stage: "race-baseline")
    tap("편집", in: app)
    let editor = app.textViews["document-editor"].firstMatch
    require(editor, in: app, stage: "race-editor")
    let original = try XCTUnwrap(editor.value as? String)
    let source = "---\nid: " + id + "\n---\n" + original
    guard concurrentDigest(source) == baselineRevision, original.utf8.last == 10,
      original.contains(baseMarker), !original.contains(draftMarker),
      !original.contains(macMarker), !original.contains(laterMarker),
      app.staticTexts["editor-document-title"].firstMatch.label == title else {
      throw ConcurrentCheckError.blocked("The complete baseline, target or editor could not be confirmed.")
    }
    let phoneAddition = "\n" + draftMarker + "\n"
    let firstAddition = "\n" + macMarker + "\n"
    let secondAddition = "\n" + laterMarker + "\n"
    let draft = original + phoneAddition
    let firstRevision = concurrentDigest(source + firstAddition)
    let secondRevision = concurrentDigest(source + firstAddition + secondAddition)
    replaceText(editor, with: draft, in: app)
    guard Data((editor.value as? String ?? "").utf8) == Data(draft.utf8) else {
      throw ConcurrentCheckError.blocked("The private draft is not the exact admitted content.")
    }
    print("FOLIO_QA_REVIEW_RACE_WAIT_C \(title) \(path) baseSHA256=\(baselineRevision) expectedSHA256=\(firstRevision) draftSHA256=\(concurrentDigest(draft))")
    print("FOLIO_QA_REVIEW_RACE_APPEND_C Append one blank line, \(macMarker), and a final newline to the exact baseline; preserve all other bytes.")
    visible("새 변경을 받았습니다. 저장할 때 함께 확인합니다.", in: app, timeout: 180)
    tap("문서 옵션", in: app); tap("미리 보기", in: app)
    visible(macMarker, in: app)
    guard try concurrentRevision(in: app, title: title, path: path, stage: "race-reviewed-C") == firstRevision else {
      throw ConcurrentCheckError.blocked("The source reviewed as C is not the exact expected content.")
    }
    tap("편집 이어쓰기", in: app)
    let beforeSecondChange = app.textViews["document-editor"].firstMatch
    require(beforeSecondChange, in: app, stage: "race-preserved-draft-before-C2")
    guard app.staticTexts["editor-document-title"].firstMatch.label == title,
      Data((beforeSecondChange.value as? String ?? "").utf8) == Data(draft.utf8) else {
      throw ConcurrentCheckError.blocked("The exact reviewed target or private draft changed.")
    }
    capture(app, "phone-reviewed-exact-C-before-C2")
    print("FOLIO_QA_REVIEW_RACE_WAIT_C2 \(title) \(path) expectedSHA256=\(secondRevision)")
    print("FOLIO_QA_REVIEW_RACE_APPEND_C2 Append one blank line, \(laterMarker), and a final newline to C; preserve all other bytes and stop further edits.")
    // Reader text proves C2 reached the projection without confirming C2's
    // revision. Reopening document information here would replace the reviewed C.
    tap("문서 옵션", in: app); tap("미리 보기", in: app)
    visible(laterMarker, in: app, timeout: 180)
    tap("편집 이어쓰기", in: app)
    let resumed = app.textViews["document-editor"].firstMatch
    require(resumed, in: app, stage: "race-preserved-draft-after-C2")
    guard app.staticTexts["editor-document-title"].firstMatch.label == title,
      Data((resumed.value as? String ?? "").utf8) == Data(draft.utf8),
      app.staticTexts["새 변경을 받았습니다. 저장할 때 함께 확인합니다."].firstMatch.exists else {
      throw ConcurrentCheckError.blocked("The target or private draft changed after C2 arrived.")
    }
    tap("저장", in: app)
    visible("확인한 원문이 다시 바뀌어 저장하지 않았습니다. 편집 내용은 보존했습니다. 문서 정보에서 원문 버전을 다시 확인해 주세요.", in: app)
    guard Data((resumed.value as? String ?? "").utf8) == Data(draft.utf8),
      app.buttons["document-save"].firstMatch.isEnabled,
      !app.buttons["document-merge-save"].firstMatch.exists else {
      throw ConcurrentCheckError.blocked("The rejected save did not retain the exact private draft.")
    }
    // This also confirms C2 as the newly reviewed source for an explicit retry.
    let observedAfterReject = try concurrentRevision(in: app, title: title, path: path, stage: "race-C2-unchanged")
    guard observedAfterReject == secondRevision,
      Data((resumed.value as? String ?? "").utf8) == Data(draft.utf8) else {
      throw ConcurrentCheckError.blocked("C2 or the private draft changed during the rejected save.")
    }
    capture(app, "phone-C2-source-and-draft-preserved-after-rejection")
    tap("저장", in: app)
    let reader = app.buttons["document-edit"].firstMatch
    require(reader, in: app, timeout: 90, stage: "race-retry-saved-reader")
    guard reader.label == "편집", !app.buttons["document-merge-save"].firstMatch.exists else {
      throw ConcurrentCheckError.blocked("The explicitly re-reviewed independent changes did not complete automatically.")
    }
    let expected = source + firstAddition + secondAddition + phoneAddition
    let finalRevision = try concurrentRevision(in: app, title: title, path: path, stage: "race-retry-merged")
    guard finalRevision == concurrentDigest(expected) else {
      throw ConcurrentCheckError.blocked("The retry result differs from exact C2 plus the retained phone draft.")
    }
    tap("편집", in: app)
    let saved = app.textViews["document-editor"].firstMatch
    require(saved, in: app, stage: "race-retry-final-body")
    guard Data((saved.value as? String ?? "").utf8) == Data((original + firstAddition + secondAddition + phoneAddition).utf8) else {
      throw ConcurrentCheckError.blocked("The retry body does not match the exact reviewed source and draft.")
    }
    tap("문서 옵션", in: app); tap("미리 보기", in: app)
    capture(app, "phone-C2-review-and-retry-confirmed")
    print("FOLIO_QA_REVIEW_RACE_VERIFIED rejectedSourceSHA256=\(secondRevision) finalSourceSHA256=\(finalRevision)")
  }

  // A separate newly created document gives the conflicting line a known
  // baseline. Both versions are inspected before the explicit choice is saved.
  func testConcurrentCloudConflictingEditRequiresExplicitChoice() throws {
    continueAfterFailure = false
    let app = try launchDedicatedLibrary()
    defer { capture(app, "phone-conflict-final-state") }
    let baseMarker = "PHONE_CONFLICT_BASE_20261022"
    let draftMarker = "PHONE_CONFLICT_DRAFT_20261022"
    let macMarker = "MAC_CONFLICT_COMMIT_20261022"
    let title = try createSavedDocument(prefix: "iPhone 충돌 선택 검증", marker: baseMarker, in: app)
    let path = documentPath(in: app)
    let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard path == "notes/" + id + ".md", let uuid = UUID(uuidString: id), id == uuid.uuidString.lowercased() else {
      throw ConcurrentCheckError.blocked("The conflict document does not have its expected new UUID path.")
    }
    let baselineRevision = try concurrentRevision(in: app, title: title, path: path, stage: "conflict-baseline")
    tap("편집", in: app)
    let editor = app.textViews["document-editor"].firstMatch
    require(editor, in: app, stage: "conflict-editor")
    let baselineBody = try XCTUnwrap(editor.value as? String)
    let baselineSource = "---\nid: " + id + "\n---\n" + baselineBody
    guard concurrentDigest(baselineSource) == baselineRevision,
      baselineBody.components(separatedBy: baseMarker).count == 2,
      !baselineBody.contains(draftMarker), !baselineBody.contains(macMarker),
      app.staticTexts["editor-document-title"].firstMatch.label == title else {
      throw ConcurrentCheckError.blocked("The complete conflict baseline and target identity could not be verified.")
    }
    let localLine = baseMarker + " " + draftMarker + " " + macMarker
    let remoteLine = baseMarker + " " + macMarker
    let phoneBody = baselineBody.replacingOccurrences(of: baseMarker, with: localLine)
    let macSource = baselineSource.replacingOccurrences(of: baseMarker, with: remoteLine)
    let expectedMacRevision = concurrentDigest(macSource)
    replaceText(editor, with: phoneBody, in: app)
    guard Data((editor.value as? String ?? "").utf8) == Data(phoneBody.utf8) else {
      throw ConcurrentCheckError.blocked("The conflict draft differs from the exact admitted phone version.")
    }
    capture(app, "phone-conflict-draft-before-mac-change")
    print("FOLIO_QA_CONFLICT_WAIT_MAC \(title) \(path) baseSHA256=\(baselineRevision) expectedMacSHA256=\(expectedMacRevision) phoneBodySHA256=\(concurrentDigest(phoneBody))")
    print("FOLIO_QA_CONFLICT_MAC_REPLACE Replace only the single line \(baseMarker) with \(remoteLine); preserve all other source bytes and stop further edits.")
    visible("새 변경을 받았습니다. 저장할 때 함께 확인합니다.", in: app, timeout: 180)
    guard Data((editor.value as? String ?? "").utf8) == Data(phoneBody.utf8) else {
      throw ConcurrentCheckError.blocked("The received conflict altered the preserved phone draft.")
    }
    tap("문서 옵션", in: app); tap("미리 보기", in: app)
    visible(remoteLine, in: app)
    let reviewedRevision = try concurrentRevision(in: app, title: title, path: path, stage: "conflict-reviewed-mac")
    guard reviewedRevision == expectedMacRevision else {
      throw ConcurrentCheckError.blocked("The Mac source is not exactly the expected conflicting line and baseline.")
    }
    tap("편집 이어쓰기", in: app)
    let resumed = app.textViews["document-editor"].firstMatch
    require(resumed, in: app, stage: "conflict-preserved-draft")
    guard app.staticTexts["editor-document-title"].firstMatch.label == title,
      Data((resumed.value as? String ?? "").utf8) == Data(phoneBody.utf8),
      app.staticTexts["새 변경을 받았습니다. 저장할 때 함께 확인합니다."].firstMatch.exists else {
      throw ConcurrentCheckError.blocked("The conflict target or phone draft changed before Save.")
    }
    tap("저장", in: app)
    let mine = app.buttons.matching(identifier: "document-merge-edited-0")
    let received = app.buttons.matching(identifier: "document-merge-received-0")
    require(mine.firstMatch, in: app, stage: "conflict-edited-choice")
    require(received.firstMatch, in: app, stage: "conflict-received-choice")
    let trim = CharacterSet.whitespacesAndNewlines
    guard mine.count == 1, received.count == 1,
      !app.buttons["document-merge-edited-1"].firstMatch.exists,
      (mine.firstMatch.value as? String)?.trimmingCharacters(in: trim) == localLine,
      (received.firstMatch.value as? String)?.trimmingCharacters(in: trim) == remoteLine,
      app.staticTexts[title].firstMatch.exists else {
      throw ConcurrentCheckError.blocked("The conflict review is ambiguous or does not show the exact two admitted versions; no choice was saved.")
    }
    capture(app, "phone-conflict-reviewed-versions")
    mine.firstMatch.tap()
    let commit = app.buttons["document-merge-save"].firstMatch
    require(commit, in: app, stage: "conflict-explicit-save")
    guard commit.isEnabled, commit.isHittable else {
      throw ConcurrentCheckError.blocked("The reviewed conflict selection is not ready to save.")
    }
    commit.tap()
    gone(commit, in: app, stage: "conflict-review-dismissed")
    let reader = app.buttons["document-edit"].firstMatch
    require(reader, in: app, timeout: 90, stage: "conflict-saved-reader")
    guard reader.label == "편집" else { throw ConcurrentCheckError.blocked("The reviewed choice is still an unsaved draft.") }
    let expectedSource = baselineSource.replacingOccurrences(of: baseMarker, with: localLine)
    let savedRevision = try concurrentRevision(in: app, title: title, path: path, stage: "conflict-saved")
    guard savedRevision == concurrentDigest(expectedSource) else {
      throw ConcurrentCheckError.blocked("The saved source does not match the exact explicitly selected version.")
    }
    tap("편집", in: app)
    let savedEditor = app.textViews["document-editor"].firstMatch
    require(savedEditor, in: app, stage: "conflict-saved-body")
    guard Data((savedEditor.value as? String ?? "").utf8) == Data(phoneBody.utf8) else {
      throw ConcurrentCheckError.blocked("The saved body differs from the reviewed explicit choice.")
    }
    tap("문서 옵션", in: app); tap("미리 보기", in: app)
    capture(app, "phone-conflict-explicit-choice-saved")
    print("FOLIO_QA_CONFLICT_CHOICE \(title) \(path) sourceSHA256=\(savedRevision) bodySHA256=\(concurrentDigest(phoneBody))")
  }

  private enum ConcurrentCheckError: Error { case blocked(String) }

  private func concurrentDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func concurrentRevision(in app: XCUIApplication, title: String, path: String, stage: String) throws -> String {
    tap("문서 옵션", in: app); tap("문서 정보", in: app)
    let navigation = app.navigationBars["문서 정보"].firstMatch
    require(navigation, in: app, stage: stage + "-information")
    let forms = app.collectionViews.allElementsBoundByIndex.filter(\.isHittable)
    guard forms.count == 1, let form = forms.first,
      form.staticTexts["제목, " + title].firstMatch.exists,
      form.staticTexts["파일, " + path].firstMatch.exists,
      !form.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "열었을 때의 문서 정보입니다.")).firstMatch.exists else {
      throw ConcurrentCheckError.blocked("The current source identity or information form could not be verified: " + stage)
    }
    let version = form.buttons["원문 버전"].firstMatch
    require(version, in: app, stage: stage + "-version")
    version.tap()
    let revisions = form.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9a-f]{64}$"))
    require(revisions.firstMatch, in: app, stage: stage + "-revision")
    guard revisions.count == 1 else { throw ConcurrentCheckError.blocked("The source revision is ambiguous: " + stage) }
    let revision = revisions.firstMatch.label
    capture(app, "phone-concurrent-source-" + stage)
    tap("닫기", in: app)
    gone(navigation, in: app, stage: stage + "-information-dismissed")
    return revision
  }

  private func launchDedicatedLibrary() throws -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.axient.Folio")
    app.launch()
    guard !app.textViews["document-editor"].firstMatch.exists else {
      throw ConcurrentCheckError.blocked("An existing editor is open; its draft was not dismissed.")
    }
    home(app)
    try selectCloudLibrary(library, in: app)
    try requireSelectedCloudLibrary(library, in: app)
    capture(app, "dedicated-cloud-library-selected")
    return app
  }

  private func openFileManagement(in app: XCUIApplication) {
    home(app)
    tap("document-list-options", in: app)
    openDocumentManagement(in: app)
    require(app.buttons["toggle-trash"].firstMatch, in: app, stage: "file-browser-presented")
  }

  private func createSavedDocument(prefix: String, marker: String, in app: XCUIApplication) throws -> String {
    home(app)
    let title = prefix + " 20261022-" + String(UUID().uuidString.prefix(8))
    openAdvancedDocumentCreation(in: app)
    let field = app.textFields["제목"].firstMatch
    require(field, in: app, stage: "new-document-title")
    field.tap(); field.typeText(title)
    tap("만들기", in: app)
    let editor = app.textViews.firstMatch
    require(editor, in: app, stage: "new-document-editor")
    let original = try XCTUnwrap(editor.value as? String)
    editor.typeText("\n\n" + marker + "\n")
    XCTAssertTrue((editor.value as? String)?.hasPrefix(original) == true)
    tap("저장", in: app)
    visible(marker, in: app)
    require(app.buttons["편집"].firstMatch, in: app, stage: "saved-reader")
    capture(app, "phone-created-saved-document")
    print("FOLIO_QA_CREATED_DOCUMENT \(title) \(marker)")
    return title
  }

  private func documentPath(in app: XCUIApplication) -> String {
    tap("문서 옵션", in: app); tap("문서 정보", in: app)
    let navigation = app.navigationBars["문서 정보"].firstMatch
    require(navigation, in: app, stage: "document-path-information")
    let forms = app.collectionViews.allElementsBoundByIndex.filter(\.isHittable)
    guard forms.count == 1, let form = forms.first,
      !form.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "열었을 때의 문서 정보입니다.")).firstMatch.exists else {
      XCTFail("The source information form is ambiguous or stale."); return ""
    }
    let paths = form.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "파일, notes/", "notes/"))
    require(paths.firstMatch, in: app, stage: "actual-document-path")
    guard paths.count == 1 else { XCTFail("The source path is ambiguous."); return "" }
    let label = paths.firstMatch.label
    let value = label.hasPrefix("파일, ") ? String(label.dropFirst("파일, ".count)) : label
    capture(app, "phone-actual-document-information")
    tap("닫기", in: app)
    return value
  }

  private func replaceText(_ element: XCUIElement, with text: String, in app: XCUIApplication) {
    element.tap(); element.press(forDuration: 1.1)
    let selectPredicate = NSPredicate(format: "label IN %@", ["Select All", "전체 선택"])
    let menuItem = app.menuItems.matching(selectPredicate).firstMatch
    let button = app.buttons.matching(selectPredicate).firstMatch
    if menuItem.waitForExistence(timeout: 2) { menuItem.tap() }
    else {
      require(button, in: app, timeout: 5, stage: "native-select-all")
      button.tap()
    }
    element.typeText(text)
    XCTAssertEqual(element.value as? String, text)
  }

  private func gone(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 30, stage: String) {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    if result != .completed { capture(app, "phone-cloud-incomplete-" + stage) }
    XCTAssertEqual(result, .completed, "Expected native transition: \(stage)")
  }

  private func openDocument(_ title: String, in app: XCUIApplication) {
    if app.buttons["문서 옵션"].firstMatch.exists,
      app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists { return }
    home(app)
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    scrollIntoView(row, in: app, timeout: 90, stage: "document-" + title)
    XCTAssertTrue(row.isHittable, "The document row must be visible before opening it.")
    row.tap()
    require(app.buttons["문서 옵션"].firstMatch, in: app, stage: "document-options")
  }

  private func home(_ app: XCUIApplication) {
    if app.buttons["library-picker"].firstMatch.isHittable { return }
    let back = app.navigationBars.buttons.element(boundBy: 0)
    require(back, in: app, stage: "library-back-navigation")
    back.tap()
    require(app.buttons["library-picker"].firstMatch, in: app, stage: "library-home")
  }

  private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 30, stage: String) {
    let deadline = Date().addingTimeInterval(timeout)
    var attempts = 0
    while Date() < deadline {
      if element.exists, element.isHittable, safeCenter(element, in: app) { return }
      let screen = app.frame
      let scrollDown: Bool
      if element.exists, !element.frame.isEmpty {
        scrollDown = element.frame.midY < screen.midY
      } else { scrollDown = (attempts / 12).isMultiple(of: 2) == false }
      let surface = [app.collectionViews, app.tables, app.scrollViews]
        .compactMap { $0.allElementsBoundByIndex.last(where: { $0.isHittable }) }.first ?? app
      if scrollDown { surface.swipeDown(velocity: .slow) }
      else { surface.swipeUp(velocity: .slow) }
      attempts += 1
    }
    capture(app, "phone-cloud-offscreen-" + stage)
    XCTAssertTrue(element.exists, "Expected actual native UI: \(stage)")
    XCTAssertTrue(element.isHittable, "Expected a visible native target: \(stage)")
    XCTAssertTrue(safeCenter(element, in: app), "Expected an unobscured center: \(stage)")
  }

  private func safeCenter(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
    guard element.exists, !element.frame.isEmpty else { return false }
    let screen = app.frame
    let navigationBottom = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable)
      .map(\.frame.maxY).max() ?? screen.minY
    let bottom = screen.maxY - 24
    let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
    return center.x > screen.minX + 8 && center.x < screen.maxX - 8
      && center.y > navigationBottom + 4 && center.y < bottom
  }

  private func tap(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 30) {
    let button = app.buttons[label].firstMatch
    require(button, in: app, timeout: timeout, stage: "action-" + label)
    if !button.isEnabled || !button.isHittable { capture(app, "phone-cloud-unavailable-action-" + label) }
    XCTAssertTrue(button.isEnabled, "Expected enabled native action: \(label)")
    XCTAssertTrue(button.isHittable, "Expected visible native action: \(label)")
    button.tap()
  }

  private func visible(_ text: String, in app: XCUIApplication, timeout: TimeInterval = 30) {
    let result = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    require(result, in: app, timeout: timeout, stage: "rendered-" + text)
  }

  private func require(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 30, stage: String) {
    let appeared = element.waitForExistence(timeout: timeout)
    if !appeared { capture(app, "phone-cloud-missing-" + stage) }
    XCTAssertTrue(appeared, "Expected actual native UI: \(stage)")
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = name + "-hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }
}
