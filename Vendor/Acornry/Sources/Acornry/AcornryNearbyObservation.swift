import Foundation

/// Every buffered observation carries the latest receive-release revision, so
/// dropping one hint cannot hide a release from the next observed event.
/// Public events retain their existing cases and delivery order.
package struct AcornryNearbyObservation: Sendable {
  package let event: AcornryEvent?
  package let receiveRevision: UUID
}
