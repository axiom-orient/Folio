// swift-tools-version: 6.3
import Foundation
import PackageDescription

// The default graph is self-contained. Set this path explicitly to opt in to
// the separately maintained SEMI adapter and its integration tests.
let sdkPath = ProcessInfo.processInfo.environment["FOLIO_SEMI_SDK_PATH"]
let includeSEMI = sdkPath.map { !$0.isEmpty } ?? false
var dependencies: [Package.Dependency] = [.package(name: "Folio", path: "..")]
var targets: [Target] = []
if includeSEMI, let sdkPath {
  dependencies.append(.package(name: "SEMIProviderSDK", path: sdkPath))
  targets.append(.target(name: "FolioProvider", dependencies: [
    .product(name: "FolioUI", package: "Folio"),
    .product(name: "FolioKnowledge", package: "Folio"),
    .product(name: "FolioKnowledgeApple", package: "Folio"),
    .product(name: "SEMIAppIntegration", package: "SEMIProviderSDK"),
  ], path: "Sources/FolioProvider"))
  targets.append(.testTarget(name: "FolioProviderTests", dependencies: ["FolioProvider",
    .product(name: "FolioSemanticModels", package: "Folio"),
    .product(name: "FolioKnowledge", package: "Folio"),
    .product(name: "FolioKnowledgeApple", package: "Folio"),
    .product(name: "SEMIControl", package: "SEMIProviderSDK"),
    .product(name: "SEMICore", package: "SEMIProviderSDK"),
  ]))
} else {
  targets.append(.target(name: "FolioProvider", dependencies: [
    .product(name: "FolioUI", package: "Folio"),
  ], path: "Sources/FolioStandalone"))
}
let package = Package(name: "FolioMacIntegration", platforms: [.macOS("27.0")],
  products: [.library(name: "FolioProvider", targets: ["FolioProvider"])],
  dependencies: dependencies, targets: targets, swiftLanguageModes: [.v6])
