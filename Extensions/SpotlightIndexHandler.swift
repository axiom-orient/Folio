import CoreSpotlight
import Foundation
import FolioKnowledgeApple

final class SpotlightIndexHandler: CSIndexExtensionRequestHandler {
  override func searchableIndex(_ searchableIndex: CSSearchableIndex,
    reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void
  ) {
    guard let groupID = Bundle.main.object(forInfoDictionaryKey: "FolioAppGroupID") as? String else { acknowledgementHandler(); return }
    WikiSpotlightRecovery.reindex(appGroupID: groupID, acknowledgement: acknowledgementHandler)
  }

  override func searchableIndex(_ searchableIndex: CSSearchableIndex,
    reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void
  ) {
    guard let groupID = Bundle.main.object(forInfoDictionaryKey: "FolioAppGroupID") as? String else { acknowledgementHandler(); return }
    WikiSpotlightRecovery.reindex(appGroupID: groupID, identifiers: Set(identifiers), acknowledgement: acknowledgementHandler)
  }
}
