import Foundation
import SwiftUI

private extension NSRange {
  func clamped(toUTF16Length length: Int) -> NSRange {
    NSRange(location: min(location, length), length: min(self.length, max(0, length - location)))
  }
}

#if os(macOS)
import AppKit

/// AppKit owns selection, IME, undo, find and scrolling; the app owns only shared draft text.
struct WikiRawEditor: NSViewRepresentable {
  @Binding var text: String
  let documentID: String
  var startsAtEnd = false
  var canEdit: @MainActor () -> Bool = { true }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
    let editor = FocusedTextView()
    editor.isRichText = false; editor.allowsUndo = true; editor.usesFindBar = true
    editor.isEditable = context.environment.isEnabled
    editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticLinkDetectionEnabled = false
    editor.font = .systemFont(ofSize: 16)
    editor.backgroundColor = .clear; editor.drawsBackground = false
    editor.textContainerInset = NSSize(width: 12, height: 12)
    editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
    editor.delegate = context.coordinator; editor.string = text
    if startsAtEnd { editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0)) }
    editor.setAccessibilityLabel("문서 본문")
    editor.setAccessibilityIdentifier("document-editor")
    scroll.documentView = editor
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let editor = scroll.documentView as? NSTextView else { return }
    editor.isEditable = context.environment.isEnabled
    let changedDocument = context.coordinator.parent.documentID != documentID
    context.coordinator.parent = self
    guard !editor.hasMarkedText(), changedDocument || editor.string != text else { return }
    let selection = editor.selectedRange()
    context.coordinator.updating = true; editor.string = text; context.coordinator.updating = false
    // An update from another window or a new source baseline invalidates this editor's old undo history.
    editor.undoManager?.removeAllActions()
    let length = (text as NSString).length
    editor.setSelectedRange(changedDocument ? NSRange(location: 0, length: 0) :
      selection.clamped(toUTF16Length: length))
  }
  final class FocusedTextView: NSTextView {
    private var requestedFocus = false
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard !requestedFocus, let window else { return }
      requestedFocus = window.makeFirstResponder(self)
      if requestedFocus { scrollRangeToVisible(selectedRange()) }
    }
  }
  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: WikiRawEditor; var updating = false
    init(_ parent: WikiRawEditor) { self.parent = parent }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?) -> Bool { updating || parent.canEdit() }
    func textDidChange(_ notification: Notification) {
      guard !updating, let editor = notification.object as? NSTextView else { return }
      parent.text = editor.string
    }
  }
}
#elseif os(iOS)
import UIKit

struct WikiRawEditor: UIViewRepresentable {
  @Binding var text: String
  let documentID: String
  var startsAtEnd = false
  var canEdit: @MainActor () -> Bool = { true }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let editor = FocusedTextView()
    editor.isEditable = context.environment.isEnabled
    editor.font = .preferredFont(forTextStyle: .body)
    editor.adjustsFontForContentSizeCategory = true
    editor.autocorrectionType = .no; editor.autocapitalizationType = .none
    editor.smartQuotesType = .no; editor.smartDashesType = .no; editor.smartInsertDeleteType = .no
    editor.isFindInteractionEnabled = true
    editor.backgroundColor = .clear; editor.textContainerInset = UIEdgeInsets(top: 16, left: 0, bottom: 24, right: 0)
    editor.accessibilityLabel = "문서 본문"
    editor.accessibilityIdentifier = "document-editor"
    editor.delegate = context.coordinator; editor.text = text
    if startsAtEnd { editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
    return editor
  }
  func updateUIView(_ editor: UITextView, context: Context) {
    editor.isEditable = context.environment.isEnabled
    let changedDocument = context.coordinator.parent.documentID != documentID
    context.coordinator.parent = self
    guard editor.markedTextRange == nil, changedDocument || editor.text != text else { return }
    let selection = editor.selectedRange; let offset = editor.contentOffset
    editor.text = text; editor.undoManager?.removeAllActions()
    let length = (text as NSString).length
    editor.selectedRange = changedDocument ? NSRange(location: 0, length: 0) :
      selection.clamped(toUTF16Length: length)
    if !changedDocument { editor.setContentOffset(offset, animated: false) }
  }
  final class FocusedTextView: UITextView {
    private var requestedFocus = false
    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard !requestedFocus, window != nil else { return }
      requestedFocus = becomeFirstResponder()
      if requestedFocus { scrollRangeToVisible(selectedRange) }
    }
  }
  @MainActor final class Coordinator: NSObject, UITextViewDelegate {
    var parent: WikiRawEditor
    init(_ parent: WikiRawEditor) { self.parent = parent }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      parent.canEdit()
    }
    func textViewDidChange(_ editor: UITextView) { parent.text = editor.text }
  }
}
#endif
