import Testing
@testable import FolioUI

@Suite struct CloudDownloadRequestTests {
  @Test func materializedSourceCanBeRequestedAgainInANewPendingEpisode() {
    let path = "notes/agent-evaluation-and-safety.md"
    var requested = Set<String>()
    let first = FolioCloudDownloadRequests.reconcile(requested: &requested, pending: [path],
      expectedGeneration: 7, currentGeneration: 7)
    #expect(first == [path])
    requested.insert(path) // The session records admission immediately before the request I/O.
    let repeated = FolioCloudDownloadRequests.reconcile(requested: &requested, pending: [path],
      expectedGeneration: 7, currentGeneration: 7)
    #expect(repeated == [])

    let materialized = FolioCloudDownloadRequests.reconcile(requested: &requested, pending: [],
      expectedGeneration: 7, currentGeneration: 7)
    #expect(materialized == [])
    #expect(requested.isEmpty)
    let nextEpisode = FolioCloudDownloadRequests.reconcile(requested: &requested, pending: [path],
      expectedGeneration: 7, currentGeneration: 7)
    #expect(nextEpisode == [path])
  }

  @Test func readyAndRemovedSourcesReleaseHistoryWithoutDuplicatingStillPendingRequests() {
    let pending = "notes/agent-design-and-operation.md"
    let newlyPending = "notes/what-is-an-ai-agent.md"
    var requested: Set<String> = [pending, "notes/ready.md", "notes/removed.md"]

    let first = FolioCloudDownloadRequests.reconcile(requested: &requested, pending: [pending, newlyPending],
      expectedGeneration: 9, currentGeneration: 9)
    #expect(first == [newlyPending])
    #expect(requested == [pending])
    requested.insert(newlyPending)
    let repeated = FolioCloudDownloadRequests.reconcile(requested: &requested, pending: [pending, newlyPending],
      expectedGeneration: 9, currentGeneration: 9)
    #expect(repeated == [])
  }

  @Test func obsoleteGenerationCannotClearOrRearmTheCurrentSessionsRequests() {
    let path = "notes/agent-evaluation-and-safety.md"
    var requested: Set<String> = [path]

    let obsoleteReady = FolioCloudDownloadRequests.reconcile(requested: &requested, pending: [],
      expectedGeneration: 10, currentGeneration: 11)
    #expect(obsoleteReady == nil)
    #expect(requested == [path])
    let current = FolioCloudDownloadRequests.reconcile(requested: &requested, pending: [path],
      expectedGeneration: 11, currentGeneration: 11)
    #expect(current == [])
    let obsoletePending = FolioCloudDownloadRequests.reconcile(requested: &requested, pending: ["notes/unrelated.md"],
      expectedGeneration: 10, currentGeneration: 11)
    #expect(obsoletePending == nil)
    #expect(requested == [path])
  }
}
