// swift-tools-version: 6.0
import PackageDescription

// The design layer for the phone.
//
// It is NOT the one of the TV program and must never become it: there, all measures are
// calculated for 1920 × 1080 at three meters, here for 393 × 852 at thirty centimeters. A
// poster is 240 points wide there, 110 here. `Tokens.Focus` does not exist here at all —
// there is no focus, there is a thumb.
//
// What is SHARED — roles, color board, contrast, symbols, type scales, profile marks,
// language aids — has lived in the shared package `Styling` since AP58 (2026-09-26).
// This package is the phone layer on top and passes it on; the measures nevertheless stay
// per device, there as a variant.
//
// macOS is in the list so that `swift test` runs on the computer instead of in the
// simulator — feedback in seconds instead of minutes.
let package = Package(
    name: "DesignSystemPhone",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DesignSystemPhone", targets: ["DesignSystemPhone"])
    ],
    dependencies: [
        .package(path: "../../../Packages/Core"),
        .package(path: "../../../Packages/Styling"),
    ],
    targets: [
        // **Without `Diagnose`** (AP58, 2026-09-26). The rule from AP6 still applies — whoever
        // writes a `catch` writes a line into the log —, but which log that is gets told by the app
        // target via `ImageMessage`. Otherwise a shared design layer would drag the phone's error
        // log along onto the TV.
        .target(name: "DesignSystemPhone", dependencies: ["Core", "Styling"]),
        .testTarget(
            name: "DesignSystemPhoneTests",
            dependencies: ["DesignSystemPhone", "Styling"],
            // Real posters from the library, brought to 96 × 96 — exactly the size at which the series
            // color is calculated. Fetched with `scripts/posters-fetch.sh`. Whatever goes wrong in the
            // derivation goes wrong on real images; a painted test image proves nothing.
            resources: [.copy("Fixtures")]
        ),
    ]
)
