// swift-tools-version: 6.0
import PackageDescription

// Jellyfin as a content source. Uses the project's official SDK, which is generated from
// the server interface — so neither endpoints nor models have to be rebuilt by hand
// and updated with every server version.
let package = Package(
    name: "JellyfinKit",
    // iOS is listed here too, because this package also carries the phone program
    // (`Phone/`). Without the line SwiftPM rejects it there.
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "JellyfinKit", targets: ["JellyfinKit"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift.git", from: "2.1.0"),
    ],
    targets: [
        .target(
            name: "JellyfinKit",
            dependencies: [
                "Core",
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "JellyfinKitTests",
            dependencies: ["JellyfinKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
