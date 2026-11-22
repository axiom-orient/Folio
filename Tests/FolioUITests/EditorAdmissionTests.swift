#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FolioUI

@Test @MainActor func nativeEditorRejectsInputImmediatelyWhenAdmissionCloses() {
  let admission = EditorAdmission()
  let editor = WikiRawEditor(text: .constant(""), documentID: "note", canEdit: { admission.isOpen })
  let coordinator = editor.makeCoordinator()
  let native = NSTextView()
  let range = NSRange(location: 0, length: 0)
  #expect(coordinator.textView(native, shouldChangeTextIn: range, replacementString: "A"))
  admission.isOpen = false
  #expect(!coordinator.textView(native, shouldChangeTextIn: range, replacementString: "B"))
}

@MainActor private final class EditorAdmission { var isOpen = true }
#endif
