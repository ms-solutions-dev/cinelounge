// swift-tools-version: 6.0
import PackageDescription

// Colours, type scale and metrics from the interface template. Depends only on
// Core, so that the accent colour of a series becomes a real colour here.
let package = Package(
    name: "DesignSystem",
    // macOS is declared so that the tests run directly on the
    // machine with `swift test` instead of in the simulator every time — that keeps the
    // feedback on every change within seconds.
    platforms: [.tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"])
    ],
    dependencies: [
        .package(path: "../Core"),
        // The shared design (AP58): roles, colour board, symbols, type levels.
        // This package has since been the TV layer on top of it and passes it on.
        .package(path: "../Styling"),
    ],
    targets: [
        .target(name: "DesignSystem", dependencies: ["Core", "Styling"]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem", "Core", "Styling"]),
    ]
)
