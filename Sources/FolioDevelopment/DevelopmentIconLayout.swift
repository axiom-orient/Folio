/// Shared by the development tool and the standalone renderer compilation.
/// Existing asset names are part of the app catalogs' references.
enum DevelopmentIconLayout {
  struct Variant: Sendable {
    let prefix: String
    let name: String
    let catalog: String
    var iconName: String { name + "Icon" }
    var iosFilename: String { prefix + "-ios-icon-1024.png" }
    func rasterFilename(size: Int) -> String { "\(prefix)-icon-\(size).png" }
  }

  static let variants = [
    Variant(prefix: "folio", name: "Folio", catalog: "AppIcon"),
    Variant(prefix: "folio-minimalism", name: "FolioMinimalism", catalog: "FolioMinimalismIcon"),
  ]
  static let rasterSizes = [16, 32, 64, 128, 256, 512, 1024]
  static let catalogSizes = [16, 32, 128, 256, 512]

  static func iconsetFilenames(size: Int) -> [String] {
    var names: [String] = []
    if size <= 512 { names.append("icon_\(size)x\(size).png") }
    if size >= 32 { names.append("icon_\(size / 2)x\(size / 2)@2x.png") }
    return names
  }
}
