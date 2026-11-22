import FolioUI

/// The standalone application has no SEMI connection provider.
@MainActor public enum FolioMacComposition {
  public static func makeModel(nearbyEnabled: Bool, migrateLegacyStorage: Bool) -> WikiAppModel {
    WikiAppModel(nearbyEnabled: nearbyEnabled, migrateLegacyStorage: migrateLegacyStorage)
  }
}
