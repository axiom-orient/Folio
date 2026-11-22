import FolioUI
import SwiftUI

@main
struct FolioIOSApp: App {
  @UIApplicationDelegateAdaptor(WikiIOSLifecycle.self) private var delegate
  @State private var model: WikiAppModel
  init() {
    let model = WikiAppModel(); _model = State(initialValue: model); delegate.model = model
  }
  var body: some Scene { WindowGroup("Folio") { WikiRootView(model: model) } }
}
