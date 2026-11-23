// swift-tools-version: 6.0
import PackageDescription

// Where the phone currently stands: Wi-Fi, cellular, tunnel, nothing at all.
//
// The TV program does not have this package, and that is not an oversight:
// An Apple TV is on a cable. The phone changes network in the middle of a movie,
// and five different things depend on that — the location line ("what this source can do
// on the go"), the downloads rule "Wi-Fi only", the suggested
// resolution, the playback target (on the go "Apple TV" silently falls back to the
// phone) and the state `cellular`.
//
// Finding from LUECKEN.md no. 10: Today there is not a single line `NWPathMonitor` in the
// whole project — the app does not know whether it is on Wi-Fi. And
// `ThroughputMemory.maxAge` is set to six hours; for a device that leaves the
// home, that is the wrong number.
let package = Package(
    name: "NetworkStatus",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "NetworkStatus", targets: ["NetworkStatus"])],
    // **Depends on nothing** (Grundstock cut, 2026-09-17): The dependency
    // on `Core` was listed here without any file using it — not a single `import`
    // in the whole target. Removed; this lets the reading app include the package via
    // the path without pulling in video code.
    targets: [
        .target(name: "NetworkStatus"),
        .testTarget(name: "NetworkStatusTests", dependencies: ["NetworkStatus"]),
    ]
)
