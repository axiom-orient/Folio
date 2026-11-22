// swift-tools-version: 6.3
import Foundation
import PackageDescription
let sdkPath = ProcessInfo.processInfo.environment["FOLIO_SEMI_SDK_PATH"]
  ?? "../../../repository/SEMI-ControlPlane/Packages/SEMIProviderSDK"
let package = Package(name: "FolioMacIntegration", platforms: [.macOS("27.0")],
  products: [.library(name: "FolioProvider", targets: ["FolioProvider"])],
  dependencies: [.package(path: ".."), .package(path: sdkPath)],
  targets: [.target(name: "FolioProvider", dependencies: [
    .product(name: "FolioKnowledge", package: "Folio"),
    .product(name: "FolioKnowledgeApple", package: "Folio"),
    .product(name: "SEMIAppIntegration", package: "SEMIProviderSDK"),
  ]), .testTarget(name: "FolioProviderTests", dependencies: ["FolioProvider",
    .product(name: "FolioSemanticModels", package: "Folio"),
    .product(name: "FolioKnowledge", package: "Folio"),
    .product(name: "FolioKnowledgeApple", package: "Folio"),
    .product(name: "SEMIControl", package: "SEMIProviderSDK"),
    .product(name: "SEMICore", package: "SEMIProviderSDK"),
  ])], swiftLanguageModes: [.v6])
