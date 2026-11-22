import FolioResearchExample
import SwiftUI

@main
struct FolioSDKHostApp: App {
  @NSApplicationDelegateAdaptor(ExampleApplicationDelegate.self) private var applicationDelegate

  var body: some Scene {
    Window("연구 자료함", id: "research") {
      FolioResearchExampleView { applicationDelegate.hasUncheckpointedEdit = $0 }
        .frame(minWidth: 720, minHeight: 480)
        .background {
          ExampleWindowCloseProtection(applicationDelegate: applicationDelegate)
            .frame(width: 0, height: 0)
        }
    }
  }
}
