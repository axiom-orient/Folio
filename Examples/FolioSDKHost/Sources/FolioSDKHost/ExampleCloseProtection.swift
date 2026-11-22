import AppKit
import SwiftUI

/// Only the example app owns this native lifetime boundary. The reusable SDK
/// reports checkpoint failure and does not install application/window delegates.
@MainActor
final class ExampleApplicationDelegate: NSObject, NSApplicationDelegate {
  var hasUncheckpointedEdit = false
  weak var researchWindow: NSWindow?
  private var presentingNotice = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    canEndEditing(in: researchWindow) ? .terminateNow : .terminateCancel
  }

  func canEndEditing(in window: NSWindow?) -> Bool {
    // Resigning first responder finishes native composition before deciding
    // whether its final input has reached the example's recovery checkpoint.
    let ended = window?.makeFirstResponder(nil) ?? true
    guard ended, !hasUncheckpointedEdit else {
      showPreservationNotice(in: window)
      return false
    }
    return true
  }

  private func showPreservationNotice(in window: NSWindow?) {
    guard !presentingNotice else { return }
    presentingNotice = true
    defer { presentingNotice = false }
    window?.makeKeyAndOrderFront(nil)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "아직 보관하지 못한 입력이 있습니다"
    alert.informativeText = "편집 화면에서 복구본 보관을 다시 시도하거나 편집 복사본을 공유해 주세요. 입력을 보관할 때까지 창과 앱을 닫지 않습니다."
    alert.addButton(withTitle: "편집으로 돌아가기")
    alert.runModal()
  }
}

/// A zero-size view finds only its own window. Its proxy preserves SwiftUI's
/// delegate behavior and restores the original delegate when removed.
@MainActor
struct ExampleWindowCloseProtection: NSViewRepresentable {
  let applicationDelegate: ExampleApplicationDelegate

  func makeCoordinator() -> Coordinator { Coordinator(applicationDelegate: applicationDelegate) }

  func makeNSView(context: Context) -> WindowObserverView {
    let view = WindowObserverView()
    view.windowChanged = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
    return view
  }

  func updateNSView(_ view: WindowObserverView, context: Context) { context.coordinator.attach(to: view.window) }

  static func dismantleNSView(_ view: WindowObserverView, coordinator: Coordinator) {
    view.windowChanged = nil
    coordinator.detach()
  }

  final class WindowObserverView: NSView {
    var windowChanged: (@MainActor (NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      windowChanged?(window)
    }
  }

  @MainActor final class Coordinator {
    let applicationDelegate: ExampleApplicationDelegate
    private weak var window: NSWindow?
    private var proxy: WindowDelegateProxy?

    init(applicationDelegate: ExampleApplicationDelegate) { self.applicationDelegate = applicationDelegate }

    func attach(to candidate: NSWindow?) {
      guard window !== candidate else { return }
      detach()
      guard let candidate else { return }
      let delegate = WindowDelegateProxy(applicationDelegate: applicationDelegate, original: candidate.delegate)
      window = candidate
      proxy = delegate
      applicationDelegate.researchWindow = candidate
      candidate.delegate = delegate
    }

    func detach() {
      if let window, let proxy, window.delegate === proxy { window.delegate = proxy.original }
      if applicationDelegate.researchWindow === window { applicationDelegate.researchWindow = nil }
      window = nil
      proxy = nil
    }
  }
}

@MainActor
private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
  private let applicationDelegate: ExampleApplicationDelegate
  // NSObject forwarding hooks are nonisolated and return non-Sendable ObjC
  // delegates. This weak reference is used only on AppKit's main thread;
  // the hooks below enforce that boundary before accessing it.
  nonisolated(unsafe) weak var original: (any NSWindowDelegate)?

  init(applicationDelegate: ExampleApplicationDelegate, original: (any NSWindowDelegate)?) {
    self.applicationDelegate = applicationDelegate
    self.original = original
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard applicationDelegate.canEndEditing(in: sender) else { return false }
    return original?.windowShouldClose?(sender) ?? true
  }

  // AppKit queries and calls its window delegates on the main thread. Forward
  // unhandled optional methods rather than replacing SwiftUI's scene behavior.
  nonisolated override func responds(to selector: Selector!) -> Bool {
    if super.responds(to: selector) { return true }
    precondition(Thread.isMainThread, "AppKit window delegates must be queried on the main thread.")
    return original?.responds(to: selector) ?? false
  }

  nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
    precondition(Thread.isMainThread, "AppKit window delegates must be called on the main thread.")
    return original
  }
}
