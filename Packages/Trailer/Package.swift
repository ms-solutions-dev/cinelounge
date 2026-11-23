// swift-tools-version: 6.0
import PackageDescription

// The trailer from YouTube — as a package of its own, so that the only third-party dependency
// besides the Jellyfin SDK stays in one place and does not grow into `Playback` or `Features`.
// YouTubeKit (MIT, alexeichhorn) resolves the YouTube key on the device
// itself to a playable address; no server, no WebView (AP78, 2026-10-11).
//
// **Pinned to one version, not "from":** YouTube changes something every few months, and
// each new YouTubeKit version is then an answer to that, which is a build of its own with
// its own on-device test. A build should not silently pull a different version than the
// one before. Bumping happens here by hand, with a justification in the roadmap.
let package = Package(
    name: "Trailer",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Trailer", targets: ["Trailer"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/alexeichhorn/YouTubeKit", exact: "0.4.9"),
    ],
    targets: [
        .target(
            name: "Trailer",
            dependencies: [
                "Core",
                .product(name: "YouTubeKit", package: "YouTubeKit"),
            ]
        ),
        .testTarget(
            name: "TrailerTests",
            dependencies: ["Trailer"]
        ),
    ]
)
