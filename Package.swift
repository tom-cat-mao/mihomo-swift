// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Local Xcode installs compile Localizable.xcstrings via xcstringstool, and the
// KumoApp SwiftUI target relies on SwiftUI macro plugins that only ship with the
// Xcode toolchain. Command Line Tools-only machines have neither, so set
// KUMO_CLT_BUILD=1 to drop both (headless dev/test of CoreKit/CLI/Service only;
// localization falls back to keys). Release/Xcode builds leave this unset.
let isCLTBuild = ProcessInfo.processInfo.environment["KUMO_CLT_BUILD"] == "1"

var kumoCoreResources: [Resource] = [
    .copy("Resources/KumoAgentSkills"),
    .copy("Resources/SubStore")
]
var kumoCoreExclude: [String] = []
if isCLTBuild {
    kumoCoreExclude.append("Resources/Localizable.xcstrings")
} else {
    kumoCoreResources.append(.process("Resources/Localizable.xcstrings"))
}

var packageProducts: [Product] = [
    .library(name: "KumoCoreKit", targets: ["KumoCoreKit"]),
    .library(name: "KumoCLIKit", targets: ["KumoCLIKit"]),
    .executable(name: "kumo", targets: ["KumoCLI"]),
    .executable(name: "KumoService", targets: ["KumoService"])
]
if !isCLTBuild {
    packageProducts.insert(.executable(name: "KumoApp", targets: ["KumoApp"]), at: 2)
}

var packageTargets: [Target] = [
    .target(
        name: "KumoCoreKit",
        dependencies: ["Yams"],
        exclude: kumoCoreExclude,
        resources: kumoCoreResources
    )
]
if !isCLTBuild {
    packageTargets.append(.executableTarget(
        name: "KumoApp",
        dependencies: ["KumoCoreKit"]
    ))
}
packageTargets.append(contentsOf: [
    .target(
        name: "KumoCLIKit",
        dependencies: [
            "KumoCoreKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ]
    ),
    .executableTarget(
        name: "KumoCLI",
        dependencies: ["KumoCLIKit"]
    ),
    .executableTarget(
        name: "KumoService",
        dependencies: ["KumoCoreKit"]
    ),
    .testTarget(
        name: "KumoCoreTests",
        dependencies: ["KumoCoreKit"]
    ),
    .testTarget(
        name: "KumoCLITests",
        dependencies: ["KumoCLIKit", "KumoCoreKit"]
    )
])

let package = Package(
    name: "Kumo",
    platforms: [
        .macOS(.v15)
    ],
    products: packageProducts,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: packageTargets
)
