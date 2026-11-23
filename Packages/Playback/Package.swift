// swift-tools-version: 6.0
import PackageDescription

// VLCKit used to live here — over a hundred megabytes in the finished program. Since the
// VLC teardown (2026-08-16, product decision) only the system engine plays;
// the package remains as the home of the engine and rule layer.
let package = Package(
    name: "Playback",
    // iOS is listed here because this package also carries the phone program
    // (`Phone/`). Without the line SwiftPM rejects it there.
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Playback", targets: ["Playback"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "Playback",
            dependencies: [
                "Core"
            ],
            // AVKit EXPLICITLY: The `avDisplayManager` category on UIWindow
            // lives there, and nothing forces loading via a link symbol —
            // as long as VLCKit was in the program, IT brought the framework along.
            // After the teardown every frame-rate registration crashed with
            // "unrecognized selector" (crash reports 2026-08-16, 12:25–12:31).
            // **For iOS too**, since the phone uses the same engine: Without the
            // framework every frame-rate and picture-in-picture registration crashes with
            // "unrecognized selector", and nothing forces its loading via a
            // link symbol.
            linkerSettings: [.linkedFramework("AVKit", .when(platforms: [.tvOS, .iOS]))]
        ),
        .testTarget(
            name: "PlaybackTests",
            dependencies: ["Playback"]
        ),
    ]
)
