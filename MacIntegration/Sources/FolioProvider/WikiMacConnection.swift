import Foundation
import AppKit
import FolioKnowledgeApple
import FolioKnowledge

/// App composition retains the SDK's existing connection; no second transport,
/// registration, consent or approval state machine is introduced.
@MainActor public final class WikiMacConnection {
  private var provider: WikiCapabilityProvider?
  private var connection: WikiCapabilityProvider.Connection?
  private var observation: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var endpointScope: URL?
  public init() {}

  public func connect(service: WikiSearchService, status: @escaping @MainActor (String) -> Void) async {
    generation += 1; let currentGeneration = generation
    await closeCurrent()
    guard currentGeneration == generation else { return }
    do {
      guard let bundleID = Bundle.main.bundleIdentifier else { throw CocoaError(.fileNoSuchFile) }
      let provider = WikiCapabilityProvider(service: service)
      let endpoint = try chooseEndpointIfSandboxed()
      let connection = try await provider.connect(bundleIdentifier: bundleID, endpointURL: endpoint)
      guard currentGeneration == generation else { _ = await connection.disconnectAndWait(); return }
      self.provider = provider; self.connection = connection
      observation = Task { [weak self] in
        for await current in connection.updates() {
          guard !Task.isCancelled, self?.connection === connection else { return }
          switch current {
          case .connected: status("SEMI에 연결됨")
          case .connecting: status("SEMI 연결 중")
          case .interrupted, .invalidated, .disconnected: status("SEMI 연결이 종료되었습니다. 다시 연결해 주세요.")
          }
        }
      }
    } catch {
      guard currentGeneration == generation else { return }
      endpointScope?.stopAccessingSecurityScopedResource(); endpointScope = nil
      status(error.localizedDescription)
    }
  }

  public func disconnect() async {
    generation += 1; await closeCurrent()
  }

  private func closeCurrent() async {
    let current = connection
    let scope = endpointScope
    observation?.cancel(); observation = nil; connection = nil; provider = nil; endpointScope = nil
    if let current { _ = await current.disconnectAndWait() }
    scope?.stopAccessingSecurityScopedResource()
  }

  /// Selecting the descriptor grants only rendezvous metadata access. Wiki consent
  /// and mutation approval remain in SEMI after the connection is established.
  private func chooseEndpointIfSandboxed() throws -> URL? {
    guard Bundle.main.object(forInfoDictionaryKey: "FolioSandboxed") as? Bool == true else { return nil }
    let key = "Folio.semiEndpointBookmark"
    if let bookmark = UserDefaults.standard.data(forKey: key) {
      var stale = false
      if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
        relativeTo: nil, bookmarkDataIsStale: &stale), !stale, url.startAccessingSecurityScopedResource() {
        endpointScope = url; return url
      }
    }
    let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.title = "SEMI 연결 정보 선택"
    panel.message = "SEMI의 연결 정보(control-plane.endpoint)를 선택하세요. 위치: ~/Library/Application Support/SEMI/InterApp. 위키 접근과 변경은 SEMI에서 별도로 승인합니다."
    guard panel.runModal() == .OK, let url = panel.url, url.lastPathComponent == "control-plane.endpoint",
      url.startAccessingSecurityScopedResource() else { throw WikiError.unavailable("SEMI 연결 정보를 선택하지 않았습니다.") }
    endpointScope = url
    UserDefaults.standard.set(try url.bookmarkData(options: .withSecurityScope,
      includingResourceValuesForKeys: nil, relativeTo: nil), forKey: key)
    return url
  }

}
