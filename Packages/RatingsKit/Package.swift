// swift-tools-version: 6.0
import PackageDescription

// Ratings from third-party sources. Deliberately a package of its own and not in
// JellyfinKit: It has nothing to do with the Jellyfin server and should stay usable
// without it.
let package = Package(
    name: "RatingsKit",
    // iOS is listed here because this package also supports the phone program
    // (`Phone/`). Without the line SwiftPM rejects it there.
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RatingsKit", targets: ["RatingsKit"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "RatingsKit", dependencies: ["Core"]),
        .testTarget(name: "RatingsKitTests", dependencies: ["RatingsKit"]),
    ]
)
