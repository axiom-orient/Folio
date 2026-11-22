import AppKit
import FolioUI
import FolioProvider
import SwiftUI

@main
struct FolioMacApp: App {
  @NSApplicationDelegateAdaptor(WikiMacDelegate.self) private var delegate
  @State private var model: WikiAppModel
  init() {
    let connection = WikiMacConnection()
    let model = WikiAppModel(connectProvider: { service, status in
      await connection.connect(service: service, status: status)
    }, disconnectProvider: { await connection.disconnect() },
      nearbyEnabled: Bundle.main.object(forInfoDictionaryKey: "FolioNearbyEnabled") as? Bool ?? true,
      migrateLegacyStorage: Bundle.main.object(forInfoDictionaryKey: "FolioMigrateLegacyStorage") as? Bool ?? true)
    _model = State(initialValue: model); delegate.model = model
  }
  var body: some Scene {
    WindowGroup("Folio", id: "main") { WikiRootView(model: model) }.defaultSize(width: 1040, height: 760)
    Settings { FolioAgentSettingsView() }
  }
}

@MainActor private final class WikiMacDelegate: NSObject, NSApplicationDelegate {
  var model: WikiAppModel?
  private var terminating = false
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminating else { return .terminateLater }
    guard let model else { return .terminateNow }
    // Finish native composition before checkpointing the shared draft values.
    guard sender.windows.allSatisfy({ $0.makeFirstResponder(nil) }) else {
      model.message = "입력 중인 편집을 마친 뒤 다시 종료해 주세요."
      return .terminateCancel
    }
    terminating = true
    Task {
      do {
        try await model.closeForTermination()
        sender.reply(toApplicationShouldTerminate: true)
      } catch {
        model.message = "종료하지 않았습니다: \(error.localizedDescription)"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "편집을 보호하기 위해 종료하지 않았습니다"
        alert.informativeText = "입력은 앱에 남아 있습니다. 열린 원문 편집을 저장하거나 명시적으로 버린 뒤 다시 종료해 주세요. 복구본 보관 오류라면 저장 공간과 접근 권한을 확인하거나 편집 복사본을 공유해 주세요.\n\n" + error.localizedDescription
        alert.addButton(withTitle: "편집으로 돌아가기")
        alert.runModal()
        terminating = false
        sender.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
  }
}
