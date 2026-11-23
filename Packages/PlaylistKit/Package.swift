// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaylistKit",
    // iOS is included here because this package also carries the phone program
    // (`Phone/`). Without the line SwiftPM rejects it there.
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PlaylistKit", targets: ["PlaylistKit"])
    ],
    dependencies: [
        // Only for the checks that read source text — see there.
        .package(path: "../SourceProbe"),
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "PlaylistKit",
            dependencies: ["Core"]
        ),
        .testTarget(
            name: "PlaylistKitTests",
            dependencies: ["PlaylistKit", "SourceProbe"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
