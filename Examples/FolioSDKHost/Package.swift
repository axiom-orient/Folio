// swift-tools-version: 6.3
import PackageDescription

// This relative path belongs only to the checked-out example. The Folio SDK
// manifest has no dependency on the example or on a neighboring repository.
let package = Package(
  name: "FolioSDKHost",
  platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [
    .executable(name: "FolioSDKHost", targets: ["FolioSDKHost"]),
    .library(name: "FolioResearchExample", targets: ["FolioResearchExample"]),
  ],
  dependencies: [.package(name: "Folio", path: "../..")],
  targets: [
    .executableTarget(name: "FolioSDKHost", dependencies: ["FolioResearchExample"]),
    .target(name: "FolioResearchExample", dependencies: [
      .product(name: "FolioCore", package: "Folio"),
      .product(name: "FolioSDKUI", package: "Folio"),
    ], resources: [.copy("Resources/ResearchLibrary")]),
  ],
  swiftLanguageModes: [.v6]
)
