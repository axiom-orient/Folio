// swift-tools-version: 6.3
import PackageDescription

// Development application composition. This graph is not a dependency of the SDK.
let package = Package(name: "FolioMacApplication", platforms: [.macOS("27.0")],
  products: [.executable(name: "FolioMac", targets: ["FolioMac"])],
  dependencies: [.package(path: ".."), .package(path: "../MacIntegration")],
  targets: [.executableTarget(name: "FolioMac", dependencies: [
    .product(name: "FolioUI", package: "Folio"),
    .product(name: "FolioProvider", package: "MacIntegration"),
  ])], swiftLanguageModes: [.v6])
