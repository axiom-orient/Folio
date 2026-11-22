import Foundation
import FolioKnowledgeApple

/// The opaque identity stays in memory. Notifications request observation;
/// equality, not notification count or object identity, admits revocation.
struct FolioCloudIdentity {
  struct Opening: Equatable {
    let generation: Int
    let location: WikiWorkspaceLocation

    init?(completedGeneration: Int?, currentGeneration: Int, requestedLocation: WikiWorkspaceLocation,
      currentLocation: WikiWorkspaceLocation?
    ) {
      guard let completedGeneration, completedGeneration == currentGeneration,
        currentLocation == requestedLocation else { return nil }
      generation = completedGeneration; location = requestedLocation
    }

    func isCurrent(generation: Int, location: WikiWorkspaceLocation?) -> Bool {
      self.generation == generation && self.location == location
    }
  }

  struct Change: Equatable {
    let generation: Int
    let wasAvailable: Bool
    let isAvailable: Bool
  }

  struct Revocation: Equatable {
    let id = UUID()
    let documentGeneration: Int
    let sourceGeneration: Int
  }

  private var token: (any NSObjectProtocol)?
  private(set) var generation = 0
  private(set) var revocation: Revocation?
  var isAvailable: Bool { token != nil }
  var currentToken: (any NSObjectProtocol)? { token }

  func matches(_ other: (any NSObjectProtocol)?) -> Bool {
    guard let token, let other else { return false }
    return token.isEqual(other)
  }

  init(token: (any NSObjectProtocol)?) { self.token = token }

  mutating func observe(_ newToken: (any NSObjectProtocol)?) -> Change? {
    let unchanged = switch (token, newToken) {
    case (nil, nil): true
    case (let previous?, let current?): previous.isEqual(current)
    default: false
    }
    guard !unchanged else { return nil }
    let wasAvailable = isAvailable
    token = newToken
    generation += 1
    return Change(generation: generation, wasAvailable: wasAvailable, isAvailable: isAvailable)
  }

  mutating func beginRevocation(documentGeneration: Int, sourceGeneration: Int) -> Revocation {
    if let revocation { return revocation }
    let captured = Revocation(documentGeneration: documentGeneration, sourceGeneration: sourceGeneration)
    revocation = captured
    return captured
  }

  func mayForget(_ captured: Revocation, documentGeneration: Int, sourceGeneration: Int,
    hasOpenSource: Bool, isOpeningSource: Bool
  ) -> Bool {
    revocation == captured && captured.documentGeneration == documentGeneration
      && sourceGeneration > captured.sourceGeneration && !hasOpenSource && !isOpeningSource
  }

  mutating func finishRevocation(_ captured: Revocation) {
    if revocation == captured { revocation = nil }
  }
}
