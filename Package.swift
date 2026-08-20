// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlgobuddyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlgobuddyCore", targets: ["AlgobuddyCore"])
    ],
    dependencies: [],  // Deliberately empty: a build must need nothing beyond the Swift toolchain.
    targets: [
        .target(name: "AlgobuddyCore"),
        // Bundled into algobuddy.app by the Makefile, because SwiftPM alone cannot
        // produce the .app wrapper a menu bar app needs.
        .executableTarget(name: "AlgobuddyApp", dependencies: ["AlgobuddyCore"]),
        .testTarget(
            name: "AlgobuddyCoreTests",
            dependencies: ["AlgobuddyCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
