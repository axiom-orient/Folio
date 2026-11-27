import Foundation

enum DevelopmentAssets {
  static func preview(_ request: DevelopmentRequest) -> [DevelopmentCommand] {
    commands(request, renderer: URL(fileURLWithPath: "/<private-temporary>/render-assets"))
  }

  static func copies(_ request: DevelopmentRequest) -> [(source: URL, destination: URL)] {
    let source = request.root.appendingPathComponent("Assets")
    let destination = request.root.appendingPathComponent("Apps/Assets.xcassets/" + DevelopmentIconLayout.catalogName)
    var result = [(source.appendingPathComponent(DevelopmentIconLayout.iosFilename),
      destination.appendingPathComponent(DevelopmentIconLayout.iosCatalogFilename))]
    for size in DevelopmentIconLayout.catalogSizes {
      for scale in [1, 2] {
        result.append((source.appendingPathComponent(DevelopmentIconLayout.rasterFilename(size: size * scale)),
          destination.appendingPathComponent(DevelopmentIconLayout.catalogFilename(size: size, scale: scale))))
      }
    }
    return result
  }

  @MainActor static func render(_ request: DevelopmentRequest) throws {
    try validate(request)
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appendingPathComponent("folio-assets-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: temporary) }
    let renderer = temporary.appendingPathComponent("render-assets")
    for command in commands(request, renderer: renderer) { try DevelopmentProcess.run(command) }
    for copy in copies(request) {
      try DevelopmentPaths.validate(copy.destination, root: request.root)
      let stage = copy.destination.deletingLastPathComponent().appendingPathComponent(".folio-icon-" + UUID().uuidString + ".png")
      defer { try? manager.removeItem(at: stage) }
      try manager.copyItem(at: copy.source, to: stage)
      if manager.fileExists(atPath: copy.destination.path) {
        _ = try manager.replaceItemAt(copy.destination, withItemAt: stage)
      } else { try manager.moveItem(at: stage, to: copy.destination) }
    }
  }

  private static func commands(_ request: DevelopmentRequest, renderer: URL) -> [DevelopmentCommand] {
    let root = request.root
    let assets = root.appendingPathComponent("Assets")
    return [DevelopmentPlan.command(request, "/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-swift-version", "6",
      root.appendingPathComponent("Sources/FolioDevelopment/DevelopmentIconLayout.swift").path,
      root.appendingPathComponent("Sources/FolioUI/FolioTheme.swift").path,
      root.appendingPathComponent("script/render_assets.swift").path, "-o", renderer.path]),
      DevelopmentPlan.command(request, renderer.path, [assets.path]),
      DevelopmentPlan.command(request, "/usr/bin/iconutil", ["-c", "icns",
        assets.appendingPathComponent(DevelopmentIconLayout.iconsetName).path,
        "-o", assets.appendingPathComponent(DevelopmentIconLayout.icnsFilename).path])]
  }

  private static func validate(_ request: DevelopmentRequest) throws {
    let assets = request.root.appendingPathComponent("Assets")
    let iconset = assets.appendingPathComponent(DevelopmentIconLayout.iconsetName)
    var outputs = copies(request).map(\.destination)
    outputs.append(assets.appendingPathComponent(DevelopmentIconLayout.icnsFilename))
    outputs.append(assets.appendingPathComponent(DevelopmentIconLayout.iosFilename))
    for size in DevelopmentIconLayout.rasterSizes {
      outputs.append(assets.appendingPathComponent(DevelopmentIconLayout.rasterFilename(size: size)))
      for name in DevelopmentIconLayout.iconsetFilenames(size: size) {
        outputs.append(iconset.appendingPathComponent(name))
      }
    }
    for output in outputs { try DevelopmentPaths.validate(output, root: request.root) }
  }
}
