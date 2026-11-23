// swift-tools-version: 6.0
import PackageDescription

// The lowest layer: models and contracts, nothing else. No third-party dependencies, no
// network, no SwiftUI. This keeps the tests here fast and lets everything else build on
// it without circular references.
let package = Package(
    name: "Core",
    // macOS is declared so that the tests run directly on the Mac with `swift test` instead
    // of in the simulator every time — that keeps feedback on every change in the range of
    // seconds. iOS is listed here because this package also carries the phone program
    // (`Phone/`). Without that line SwiftPM rejects it there.
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Core", targets: ["Core"])
    ],
    // Since 2026-09-17 the foundation lives in `Grundstock` (certificate, Keychain,
    // diagnostics, crash watch, color board) and also carries the reading app. `Core`
    // re-exports its types with `@_exported` — see `Grundstock.swift`.
    dependencies: [
        .package(path: "../Grundstock"),
        // The shared catalog (AP58 R0): What `Core` itself says lives there and not in the
        // catalogs of the two apps.
        .package(path: "../WordingKit"),
        // Only for the checks that read source text — see there.
        .package(path: "../SourceProbe"),
    ],
    targets: [
        // The hot core of the Layer II decoder in C — the reasoning is in its header: Swift
        // without the optimizer cannot run the filter bank in real time, and device.sh builds
        // Debug.
        .target(name: "MP2Synthesis"),
        // libdcadec (LGPL 2.1) for DTS — see HERKUNFT.md in the target folder. NDEBUG removes the
        // library's `assert` bail-outs; -O2 keeps the decoder in real time even in the Debug
        // build of device.sh — the filter bank computes in floating point over 32 subbands per
        // channel.
        .target(
            name: "DCADec",
            cSettings: [
                .define("NDEBUG"),
                .unsafeFlags(["-O2", "-Wno-everything"]),
            ]
        ),
        .target(
            name: "Core",
            dependencies: [
                .product(name: "Grundstock", package: "grundstock"), "MP2Synthesis", "DCADec",
                "WordingKit",
            ]),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core", "SourceProbe"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
