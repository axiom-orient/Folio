// swift-tools-version: 6.3
import PackageDescription

#if os(macOS)
let platformProducts: [Product] = [
  .executable(name: "FolioSearchEvaluation", targets: ["FolioSearchEvaluation"]),
  .executable(name: "FolioCorpusReview", targets: ["FolioCorpusReview"]),
  .executable(name: "FolioAgentsCLI", targets: ["FolioAgentsCLI"]),
  .executable(name: "FolioVaultImport", targets: ["FolioVaultImportCLI"]),
  .executable(name: "FolioDeveloper", targets: ["FolioDeveloperCLI"]),
]
let platformTargets: [Target] = [
  .executableTarget(name: "FolioSearchEvaluation", dependencies: ["FolioKnowledge", "FolioKnowledgeApple", "FolioSemanticModels"], path: "Tools/SearchEvaluation"),
  .executableTarget(name: "FolioCorpusReview", dependencies: [
    "FolioKnowledge",
    "FolioKnowledgeApple"], path: "Tools/CorpusReview"),
  .executableTarget(name: "FolioAgentsCLI", dependencies: ["FolioAgents"], path: "Tools/AgentManager"),
  .executableTarget(name: "FolioVaultImportCLI", dependencies: ["FolioVaultImport"], path: "Tools/VaultImport"),
  .executableTarget(name: "FolioDeveloperCLI", dependencies: ["FolioDevelopment"], path: "Tools/Developer"),
]
#else
let platformProducts: [Product] = []
let platformTargets: [Target] = []
#endif

let package = Package(
  name: "Folio", platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [
    .library(name: "FolioSemanticModels", targets: ["FolioSemanticModels"]),
    .library(name: "FolioCore", targets: ["FolioCore"]),
    .library(name: "FolioSDKUI", targets: ["FolioSDKUI"]),
    // Compatibility products for the existing Folio application and adapters.
    .library(name: "FolioUI", targets: ["FolioUI"]),
    .library(name: "FolioKnowledge", targets: ["FolioKnowledge"]),
    .library(name: "FolioKnowledgeApple", targets: ["FolioKnowledgeApple"]),
  ] + platformProducts,
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
  ],
  targets: [
    .systemLibrary(name: "FolioKnowledgeSQLite", path: "Vendor/KnowledgeKit/Sources/KnowledgeKitSQLite"),
    .target(name: "FolioKnowledge", dependencies: ["FolioKnowledgeSQLite",
      .product(name: "Markdown", package: "swift-markdown"), .product(name: "Yams", package: "Yams")],
      path: "Vendor/KnowledgeKit/Sources/KnowledgeKit"),
    .target(name: "FolioKnowledgeApple", dependencies: ["FolioKnowledge",
      .product(name: "Markdown", package: "swift-markdown"), .product(name: "ZIPFoundation", package: "ZIPFoundation")],
      path: "Vendor/KnowledgeKit/Sources/KnowledgeKitApple", resources: [.copy("Resources/ZIPFoundation-LICENSE.txt")]),
    .target(name: "FolioNearbyTransport", path: "Vendor/Acornry/Sources/Acornry"),
    .target(name: "FolioSemanticModels", dependencies: ["FolioKnowledge", "FolioKnowledgeApple"],
      // Keep model packages intact without a top-level Resources directory in
      // the iOS bundle, which codesign treats as an ambiguous bundle layout.
      resources: [
        "LICENSE-E5.txt", "LICENSE-SwiftTransformers.txt", "MODEL_SOURCE.json",
        "MultilingualE5Small.mlpackage", "Precompiled.charsmap", "Relevance",
        "TOKENIZER_SOURCE.json", "Unigram.foliotokens", "tokenizer.json", "tokenizer_config.json",
      ].map { .copy("Resources/\($0)") }),
    .target(name: "FolioCore", dependencies: ["FolioKnowledge", "FolioKnowledgeApple"]),
    .target(name: "FolioSDKUI", dependencies: ["FolioCore"]),
    .target(name: "FolioUI", dependencies: [
      "FolioSemanticModels",
      "FolioCore",
      .target(name: "FolioAgents", condition: .when(platforms: [.macOS])),
      "FolioNearbyTransport",
      .product(name: "Markdown", package: "swift-markdown"),
      "FolioKnowledge",
      "FolioKnowledgeApple",
    ], resources: [.copy("Resources/Acornry-LICENSE.txt"), .copy("Resources/Acornry-THIRD_PARTY_NOTICES.md")]),
    .target(name: "FolioAgents", dependencies: [.product(name: "Yams", package: "Yams")]),
    .target(name: "FolioVaultImport", dependencies: [.product(name: "Yams", package: "Yams"), "FolioKnowledge"]),
    .target(name: "FolioDevelopment"),
    .testTarget(name: "FolioKnowledgeTests", dependencies: ["FolioKnowledge", "FolioKnowledgeApple", "FolioSemanticModels"], resources: [.copy("Fixtures")]),
    .testTarget(name: "FolioCoreTests", dependencies: ["FolioCore", "FolioKnowledge", "FolioKnowledgeApple"]),
    .testTarget(name: "FolioUITests", dependencies: ["FolioUI", .product(name: "Markdown", package: "swift-markdown")]),
    .testTarget(name: "FolioAgentsTests", dependencies: ["FolioAgents"]),
    .testTarget(name: "FolioVaultImportTests", dependencies: ["FolioVaultImport", "FolioKnowledge"]),
    .testTarget(name: "FolioDevelopmentTests", dependencies: ["FolioDevelopment"]),
  ] + platformTargets,
  swiftLanguageModes: [.v6]
)
