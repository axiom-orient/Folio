import FolioUI

/// Compose the optional SEMI adapter with the shared application model.
@MainActor public enum FolioMacComposition {
  public static func makeModel(nearbyEnabled: Bool, migrateLegacyStorage: Bool) -> WikiAppModel {
    let connection = WikiMacConnection()
    return WikiAppModel(connectProvider: { service, status in
      await connection.connect(service: service, status: status)
    }, disconnectProvider: { await connection.disconnect() },
      nearbyEnabled: nearbyEnabled, migrateLegacyStorage: migrateLegacyStorage)
  }
}
