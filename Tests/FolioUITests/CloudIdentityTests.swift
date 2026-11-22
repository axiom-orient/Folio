import Foundation
import FolioKnowledgeApple
import Testing
@testable import FolioUI

@Test func equalOpaqueIdentitiesDoNotRevokeTheSourceEvenWhenInstancesDiffer() throws {
  let initial = CloudIdentityToken(1)
  let equivalent = CloudIdentityToken(1)
  #expect(initial !== equivalent)
  var identity = FolioCloudIdentity(token: initial)
  let first = identity.observe(equivalent)
  let duplicate = identity.observe(equivalent)
  #expect(first == nil)
  #expect(duplicate == nil)
  #expect(identity.generation == 0)
  #expect(identity.revocation == nil)
  #expect(identity.isAvailable)
}

@Test func boundCloudDraftAccountStopsMatchingWhenObservedIdentityChanges() {
  let bound = CloudIdentityToken(1)
  var identity = FolioCloudIdentity(token: bound)
  #expect(identity.matches(CloudIdentityToken(1)))
  #expect(!identity.matches(nil))
  _ = identity.observe(CloudIdentityToken(2))
  #expect(!identity.matches(bound))
  #expect(identity.matches(CloudIdentityToken(2)))
}

@Test @MainActor func cloudSourceAdmissionKeepsTheBoundIdentityAcrossNotificationTiming() async {
  let storage = FolioStorageAccess()
  let session = FolioWorkspaceSession(storageAccess: storage)
  let original = CloudIdentityToken(1)
  let system = MutableCloudIdentity(original)
  let account = FolioCloudAccount(session: session, storageAccess: storage, token: original, systemToken: { system.token })
  account.bindSourceIdentity(original)
  #expect(account.sourceMatchesCurrentIdentity)
  system.token = CloudIdentityToken(2)
  #expect(!account.sourceMatchesCurrentIdentity)
  await account.identityChanged(closeWorkspace: {})
  #expect(!account.sourceMatchesCurrentIdentity)
  account.bindSourceIdentity(CloudIdentityToken(2))
  #expect(account.sourceMatchesCurrentIdentity)
  system.token = nil
  #expect(!account.sourceMatchesCurrentIdentity)
}

@MainActor private final class MutableCloudIdentity {
  var token: (any NSObjectProtocol)?
  init(_ token: (any NSObjectProtocol)?) { self.token = token }
}

@Test func duplicateWindowNotificationsAdmitOneRevocationAndLaterIdentityChangesShareItsLane() throws {
  var identity = FolioCloudIdentity(token: CloudIdentityToken(1))
  let observed = identity.observe(CloudIdentityToken(2))
  let change = try #require(observed)
  #expect(change.wasAvailable && change.isAvailable)
  let captured = identity.beginRevocation(documentGeneration: 4, sourceGeneration: 8)
  let duplicate = identity.observe(CloudIdentityToken(2))
  let duplicateRevocation = identity.beginRevocation(documentGeneration: 4, sourceGeneration: 8)
  #expect(duplicate == nil)
  #expect(duplicateRevocation == captured)
  #expect(identity.generation == 1)

  let observedLater = identity.observe(CloudIdentityToken(3))
  let later = try #require(observedLater)
  #expect(later.generation == 2)
  let sharedRevocation = identity.beginRevocation(documentGeneration: 4, sourceGeneration: 8)
  #expect(sharedRevocation == captured)
  #expect(identity.mayForget(captured, documentGeneration: 4, sourceGeneration: 9,
    hasOpenSource: false, isOpeningSource: false))
  identity.finishRevocation(captured)
  #expect(identity.revocation == nil)
  #expect(identity.isAvailable)
}

@Test func unavailableIdentityIsDistinctFromAnAvailableAccountChangeAndDuplicateNilIsIgnored() throws {
  var identity = FolioCloudIdentity(token: CloudIdentityToken(1))
  let observedUnavailable = identity.observe(nil)
  let unavailable = try #require(observedUnavailable)
  #expect(unavailable.wasAvailable)
  #expect(!unavailable.isAvailable)
  #expect(!identity.isAvailable)
  let duplicate = identity.observe(nil)
  #expect(duplicate == nil)
  #expect(identity.generation == unavailable.generation)

  let observedAvailable = identity.observe(CloudIdentityToken(2))
  let available = try #require(observedAvailable)
  #expect(!available.wasAvailable)
  #expect(available.isAvailable)
  #expect(available.generation == unavailable.generation + 1)
}

@Test func aLateRevocationCompletionCannotForgetOrReleaseANewerSourceOwner() {
  var identity = FolioCloudIdentity(token: CloudIdentityToken(1))
  let old = identity.beginRevocation(documentGeneration: 10, sourceGeneration: 20)
  #expect(!identity.mayForget(old, documentGeneration: 10, sourceGeneration: 20,
    hasOpenSource: false, isOpeningSource: false))
  #expect(!identity.mayForget(old, documentGeneration: 11, sourceGeneration: 22,
    hasOpenSource: false, isOpeningSource: false))
  #expect(!identity.mayForget(old, documentGeneration: 10, sourceGeneration: 21,
    hasOpenSource: true, isOpeningSource: false))
  #expect(!identity.mayForget(old, documentGeneration: 10, sourceGeneration: 21,
    hasOpenSource: false, isOpeningSource: true))
  identity.finishRevocation(old)
  let current = identity.beginRevocation(documentGeneration: 11, sourceGeneration: 22)
  #expect(!identity.mayForget(old, documentGeneration: 11, sourceGeneration: 23,
    hasOpenSource: false, isOpeningSource: false))
  identity.finishRevocation(old)
  #expect(identity.revocation == current)
  #expect(identity.mayForget(current, documentGeneration: 11, sourceGeneration: 23,
    hasOpenSource: false, isOpeningSource: false))
}

@Test func anIdentityChangeDuringCloudOpeningInvalidatesItsCapturedAdmissionEpoch() throws {
  var identity = FolioCloudIdentity(token: nil)
  let unavailable = identity.observe(nil)
  #expect(unavailable == nil)
  let available = identity.observe(CloudIdentityToken(1))
  _ = try #require(available)
  let openingEpoch = identity.generation
  let duplicate = identity.observe(CloudIdentityToken(1))
  #expect(duplicate == nil)
  #expect(identity.generation == openingEpoch)
  let changed = identity.observe(CloudIdentityToken(2))
  _ = try #require(changed)
  #expect(identity.generation != openingEpoch)
}

@Test func supersededCloudOpeningCannotInspectOrRevokeTheNewSourceAfterAnIdentityChange() throws {
  let cloud = WikiWorkspaceLocation.managedCloud(containerIdentifier: "iCloud.example.Folio", workspaceID: UUID())
  var identity = FolioCloudIdentity(token: CloudIdentityToken(1))
  let oldOpeningEpoch = identity.generation
  let observed = identity.observe(CloudIdentityToken(2))
  _ = try #require(observed)
  #expect(identity.generation != oldOpeningEpoch)

  // B opened under the new identity before superseded A returned nil. Even
  // when both requested the same cloud location, A cannot inspect/revoke B.
  let current = try #require(FolioCloudIdentity.Opening(completedGeneration: 12, currentGeneration: 12,
    requestedLocation: cloud, currentLocation: cloud))
  let superseded = FolioCloudIdentity.Opening(completedGeneration: nil, currentGeneration: 12,
    requestedLocation: cloud, currentLocation: cloud)
  let stale = FolioCloudIdentity.Opening(completedGeneration: 11, currentGeneration: 12,
    requestedLocation: cloud, currentLocation: cloud)
  #expect(superseded == nil)
  #expect(stale == nil)
  #expect(current.isCurrent(generation: 12, location: cloud))
  // Recheck after an awaited identity observation: a newer source at the same
  // location and a different location both invalidate the captured owner.
  #expect(!current.isCurrent(generation: 13, location: cloud))
  #expect(!current.isCurrent(generation: 12, location: .localManaged(workspaceID: UUID())))
}

private final class CloudIdentityToken: NSObject {
  private let value: Int
  init(_ value: Int) { self.value = value }
  override func isEqual(_ object: Any?) -> Bool { (object as? CloudIdentityToken)?.value == value }
  override var hash: Int { value }
}
