import Foundation

enum DevelopmentAssets {
  static func preview(_ request: DevelopmentRequest) -> [DevelopmentCommand] {
    commands(request, renderer: URL(fileURLWithPath: "/<private-temporary>/render-assets"))
  }

  static func copies(_ request: DevelopmentRequest) -> [(source: URL, destination: URL)] {
    var result: [(URL, URL)] = []
    for variant in DevelopmentIconLayout.variants {
      let destination = request.root.appendingPathComponent("Apps/Assets.xcassets/\(variant.catalog).appiconset")
      result.append((request.root.appendingPathComponent("Assets/" + variant.iosFilename), destination.appendingPathComponent("\(variant.name)-1024.png")))
      for size in DevelopmentIconLayout.catalogSizes {
        for scale in [1, 2] {
          result.append((request.root.appendingPathComponent("Assets/" + variant.rasterFilename(size: size * scale)),
            destination.appendingPathComponent("\(variant.name)-mac-\(size)@\(scale)x.png")))
        }
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
    var result = [DevelopmentPlan.command(request, "/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-swift-version", "6",
      root.appendingPathComponent("Sources/FolioDevelopment/DevelopmentIconLayout.swift").path,
      root.appendingPathComponent("Sources/FolioUI/FolioTheme.swift").path,
      root.appendingPathComponent("script/render_assets.swift").path, "-o", renderer.path]),
      DevelopmentPlan.command(request, renderer.path, [root.appendingPathComponent("Assets").path])]
    for variant in DevelopmentIconLayout.variants {
      result.append(DevelopmentPlan.command(request, "/usr/bin/iconutil", ["-c", "icns",
        root.appendingPathComponent("Assets/\(variant.iconName).iconset").path, "-o", root.appendingPathComponent("Assets/\(variant.iconName).icns").path]))
    }
    return result
  }

  private static func validate(_ request: DevelopmentRequest) throws {
    var outputs = copies(request).map(\.destination)
    for variant in DevelopmentIconLayout.variants {
      outputs.append(request.root.appendingPathComponent("Assets/\(variant.iconName).icns"))
      outputs.append(request.root.appendingPathComponent("Assets/" + variant.iosFilename))
      for size in DevelopmentIconLayout.rasterSizes {
        outputs.append(request.root.appendingPathComponent("Assets/" + variant.rasterFilename(size: size)))
        for name in DevelopmentIconLayout.iconsetFilenames(size: size) {
          outputs.append(request.root.appendingPathComponent("Assets/\(variant.iconName).iconset/" + name))
        }
      }
    }
    for output in outputs { try DevelopmentPaths.validate(output, root: request.root) }
  }
}
