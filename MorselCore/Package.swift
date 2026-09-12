// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MorselCore",
    // MorselCore itself has no platform requirements — it is pure logic and
    // runs under `swift test` on Linux. These bounds exist only to satisfy
    // GRDB, which MorselData depends on.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MorselCore", targets: ["MorselCore"]),
        .library(name: "MorselData", targets: ["MorselData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
    ],
    targets: [
        // Pure logic: no dependencies, deliberately. Keep it that way — this is
        // what stays testable on Linux with no Xcode.
        .target(name: "MorselCore"),
        .target(
            name: "MorselData",
            dependencies: [
                "MorselCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "MorselCoreTests", dependencies: ["MorselCore"]),
        .testTarget(name: "MorselDataTests", dependencies: ["MorselData"]),
    ],
    swiftLanguageModes: [.v6]
)
