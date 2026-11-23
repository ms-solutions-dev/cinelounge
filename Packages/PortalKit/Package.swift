// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortalKit",
    // iOS is included here because this package also carries the phone program
    // (`Phone/`). Without the line SwiftPM rejects it there.
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PortalKit", targets: ["PortalKit"])
    ],
    dependencies: [
        // Only for the checks that read source text — see there.
        .package(path: "../SourceProbe"),
        .package(path: "../Core"),
        .package(path: "../WordingKit"),
    ],
    targets: [
        .target(
            name: "PortalKit",
            dependencies: ["Core", "WordingKit"]
        ),
        .testTarget(
            name: "PortalKitTests",
            dependencies: ["PortalKit", "SourceProbe"],
            // Real responses from the CineLounge server, recorded on 2026-09-12. They prove that
            // the bridge's models read the server — a replicated response would only prove that
            // someone replicated it correctly.
            resources: [.copy("Mitschnitte")]
        ),
    ]
)
