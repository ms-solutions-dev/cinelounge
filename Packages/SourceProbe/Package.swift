// swift-tools-version: 6.0
import PackageDescription

// The path board for checks that read source text (AP58, 2026-09-26).
//
// **Not a program package, only a check tool.** It hangs on no app target and
// only on test targets. Around sixty check files read sources by path and
// search pattern; until here each of them computed its own way up from `#filePath`
// ("four levels, then `Sources/…`"), and every move of a file or
// a package broke them each at their own spot. Now they name a
// symbolic location, and the board knows where it lies.
//
// **Without dependencies**, so that every package can include it, `Core` too.
let package = Package(
    name: "SourceProbe",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [.library(name: "SourceProbe", targets: ["SourceProbe"])],
    targets: [
        .target(name: "SourceProbe"),
        .testTarget(name: "SourceProbeTests", dependencies: ["SourceProbe"]),
    ]
)
