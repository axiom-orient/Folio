/// Shared by the development tool and the standalone renderer compilation.
/// These filenames match the AppIcon catalog and the development app bundle.
enum DevelopmentIconLayout {
  static let iconsetName = "FolioIcon.iconset"
  static let icnsFilename = "FolioIcon.icns"
  static let iosFilename = "folio-ios-icon-1024.png"
  static let catalogName = "AppIcon.appiconset"
  static let iosCatalogFilename = "Folio-1024.png"
  static let rasterSizes = [16, 32, 64, 128, 256, 512, 1024]
  static let catalogSizes = [16, 32, 128, 256, 512]

  static func rasterFilename(size: Int) -> String { "folio-icon-\(size).png" }
  static func catalogFilename(size: Int, scale: Int) -> String { "Folio-mac-\(size)@\(scale)x.png" }

  static func iconsetFilenames(size: Int) -> [String] {
    var names: [String] = []
    if size <= 512 { names.append("icon_\(size)x\(size).png") }
    if size >= 32 { names.append("icon_\(size / 2)x\(size / 2)@2x.png") }
    return names
  }
}
