#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI retains presentation intent; one attached native panel explicitly
/// permits directories. It never owns a workspace or runs an import itself.
struct WikiFolderPicker: NSViewRepresentable {
  let contentTypes: [UTType]
  let cancellation: () -> Void
  let completion: (Result<[URL], Error>) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> AttachmentView {
    let view = AttachmentView()
    view.attached = { [weak coordinator = context.coordinator] window in coordinator?.present(in: window) }
    return view
  }
  func updateNSView(_ view: AttachmentView, context: Context) {}
  static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) { coordinator.cancel() }

  final class AttachmentView: NSView {
    var attached: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      Task { @MainActor [weak self] in
        guard self?.window === window else { return }
        self?.attached?(window)
      }
    }
  }

  @MainActor final class Coordinator {
    let owner: WikiFolderPicker
    private var panel: NSOpenPanel?
    private var started = false
    private var finished = false
    init(_ owner: WikiFolderPicker) { self.owner = owner }

    func present(in window: NSWindow) {
      guard !started else { return }
      started = true
      let panel = NSOpenPanel()
      self.panel = panel
      let files = owner.contentTypes.filter { $0 != .folder }
      panel.canChooseDirectories = true
      panel.canChooseFiles = !files.isEmpty
      if !files.isEmpty { panel.allowedContentTypes = files }
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = true
      panel.beginSheetModal(for: window) { [weak self] response in
        guard let self, !self.finished else { return }
        self.finished = true; self.panel = nil
        if response == .OK { self.owner.completion(.success(panel.urls)) }
        else { self.owner.cancellation() }
      }
    }
    func cancel() {
      guard !finished else { return }
      panel?.cancel(nil)
    }
  }
}
#endif
