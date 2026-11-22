#if os(iOS)
import UIKit
import SwiftUI

/// View/navigation disappearance is not scene closure. Capture the native scene
/// identity so only its actual disconnect removes the window registration.
struct WikiSceneIdentity: UIViewRepresentable {
  let connected: @MainActor (String) -> Void
  func makeUIView(context: Context) -> SceneIdentityView {
    let view = SceneIdentityView(); view.connected = connected; return view
  }
  func updateUIView(_ view: SceneIdentityView, context: Context) { view.connected = connected }
  final class SceneIdentityView: UIView {
    var connected: (@MainActor (String) -> Void)?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard let id = window?.windowScene?.session.persistentIdentifier else { return }
      Task { @MainActor [weak self] in
        guard let self, self.window?.windowScene?.session.persistentIdentifier == id else { return }
        self.connected?(id)
      }
    }
  }
}

/// One application lifecycle owner across iPhone/iPad scenes. Draft recovery is
/// synchronous at suspension; the short background lease only finishes admitted I/O.
@MainActor public final class WikiIOSLifecycle: NSObject, UIApplicationDelegate {
  public var model: WikiAppModel?
  private var transition: Task<Void, Never>?
  private var generation = 0
  private var backgroundID: UIBackgroundTaskIdentifier = .invalid
  public func applicationDidEnterBackground(_ application: UIApplication) {
    generation += 1
    model?.restrictMobileAccess(protectedDataAvailable: model?.protectedDataAvailable ?? false)
    endBackgroundTask()
    backgroundID = application.beginBackgroundTask(withName: "Finish wiki source access") { [weak self] in
      self?.transition?.cancel(); self?.endBackgroundTask()
    }
    suspend(releasing: backgroundID)
  }
  public func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
    // A normal screen lock does not revoke Class C access after the first unlock.
    if FolioStorage.mobileDataReady() { return }
    generation += 1
    model?.restrictMobileAccess(protectedDataAvailable: false)
    suspend()
  }
  public func applicationDidBecomeActive(_ application: UIApplication) { resume(application) }
  public func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
    if application.applicationState == .active { resume(application) }
  }
  private func suspend(releasing backgroundLease: UIBackgroundTaskIdentifier? = nil) {
    let previous = transition
    transition = Task { [weak self] in
      await self?.model?.pauseMobileObservation()
      if let previous { await previous.value }
      await self?.model?.suspendMobile()
      if let backgroundLease, self?.backgroundID == backgroundLease { self?.endBackgroundTask() }
    }
  }
  private func resume(_ application: UIApplication) {
    generation += 1; let current = generation; let previous = transition
    transition = Task { [weak self] in
      if let previous { await previous.value }
      guard self?.generation == current, application.applicationState == .active else { return }
      await self?.model?.resumeMobile()
    }
  }
  private func endBackgroundTask() {
    guard backgroundID != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid
  }
}
#endif
