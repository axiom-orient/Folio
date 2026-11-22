import Foundation
import FolioKnowledge
import FolioKnowledgeApple
import Observation

struct FolioDocumentContext: Equatable, Identifiable {
  let root: URL
  let generation: Int
  var id: String { root.absoluteString + ":" + String(generation) }
}

/// Catalog projection and operation lifetime. WikiWorkspace owns every source effect.
@MainActor @Observable
final class FolioDocumentLibrary {
  struct LoadProblem: Equatable {
    let title: String
    let detail: String

    init(_ error: any Error) {
      if case WikiError.conflict = error { title = "문서의 다른 버전을 확인해 주세요" }
      else { title = "폴더와 휴지통을 준비하지 못했습니다" }
      detail = error.localizedDescription
    }
  }
  enum Phase: Equatable {
    case ready, loading(UUID), applying(UUID)
    var isApplying: Bool { if case .applying = self { true } else { false } }
    var isBusy: Bool { self != .ready }
  }
  private(set) var phase: Phase = .ready
  private(set) var entries: [WikiLibraryEntry] = []
  private(set) var trash: [WikiTrashEntry] = []
  private(set) var context: FolioDocumentContext?
  private(set) var loadProblem: LoadProblem?
  @ObservationIgnored private var completionWaiters: [CheckedContinuation<Void, Never>] = []

  var folders: [String] { ["notes"] + entries.filter(\.isDirectory).map(\.relativePath) }

  func children(in folder: String) -> [WikiLibraryEntry] {
    entries.filter { ($0.relativePath as NSString).deletingLastPathComponent == folder }
      .sorted {
        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
        return ($0.relativePath as NSString).lastPathComponent.localizedStandardCompare(
          ($1.relativePath as NSString).lastPathComponent) == .orderedAscending
      }
  }

  func moveDestinations(for path: String) -> [String] {
    let parent = (path as NSString).deletingLastPathComponent
    return folders.filter { $0 != parent && $0 != path && !$0.hasPrefix(path + "/") }
  }

  func reset() {
    guard !phase.isApplying else { return }
    context = nil; entries = []; trash = []; phase = .ready; loadProblem = nil
  }

  func reload(workspace: WikiWorkspace, context: FolioDocumentContext, afterMutation: Bool = false) async throws {
    guard !phase.isApplying || afterMutation else { return }
    let id = UUID()
    let admittedPhase = phase.isApplying ? phase : .loading(id)
    self.context = context; phase = admittedPhase
    defer { if phase == .loading(id) { phase = .ready } }
    let entries: [WikiLibraryEntry]
    let trash: [WikiTrashEntry]
    do {
      entries = try await workspace.libraryEntries()
      trash = try await workspace.trashEntries()
    } catch {
      if self.context == context, phase == admittedPhase { loadProblem = LoadProblem(error) }
      throw error
    }
    guard self.context == context, phase == admittedPhase else { return }
    self.entries = entries; self.trash = trash; loadProblem = nil
  }

  func apply(_ command: WikiFileOperation, expectedRevision: String?, workspace: WikiWorkspace,
    context: FolioDocumentContext
  ) async throws -> WikiFileChange {
    let id = try begin(context: context)
    let task = Task { try await workspace.performFileOperation(command, expectedRevision: expectedRevision, operationID: id) }
    return try await task.value
  }

  /// Materialization updates only the visible trash projection. It never
  /// replays a file mutation or covers the editor with a loading phase.
  func refreshTrash(workspace: WikiWorkspace, context: FolioDocumentContext) async throws {
    guard self.context == context, !phase.isApplying else { return }
    let received = try await workspace.trashEntries()
    guard !Task.isCancelled, self.context == context, !phase.isApplying else { return }
    trash = received
  }

  func editMetadata(_ document: WikiDocument, title: String, tags: [String], workspace: WikiWorkspace,
    context: FolioDocumentContext
  ) async throws -> WikiWriteReceipt {
    let id = try begin(context: context)
    let task = Task {
      let plan = try await workspace.prepareMetadataEdit(relativePath: document.relativePath,
        expectedRevision: document.revision, title: title, tags: tags, operationID: id)
      return try await workspace.execute(plan)
    }
    return try await task.value
  }

  private func begin(context: FolioDocumentContext) throws -> UUID {
    guard !phase.isBusy else { throw CocoaError(.userCancelled) }
    let id = UUID()
    self.context = context; phase = .applying(id)
    return id
  }
  func finish() {
    phase = .ready
    let waiters = completionWaiters; completionWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  /// The caller finishes receipt/navigation handling before releasing the lane.
  /// Draining only the source Task would let foreground reopening race that work.
  func drain() async {
    guard phase.isApplying else { return }
    await withCheckedContinuation { completionWaiters.append($0) }
  }
}
