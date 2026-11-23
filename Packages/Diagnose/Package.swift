// swift-tools-version: 6.0
import PackageDescription

// Recording of errors and diagnostics — **the one logging path for shared logic.**
//
// Delineation, so that nothing arises twice here:
//
//   `Core.Diagnostics` (from `Grundstock`, plus the playback and focus trace in `Core`)
//   is the BASE: `os.log` in the categories `network` and `playback`, the ring buffer
//   `Trace` for the on-device display, the report's disk traces, the
//   redaction rule and the `DiagnosticID`.
//
//   THIS package is the FACADE above it: `Diagnose.step/hint/error` with six
//   areas and four severity levels. Where a line goes besides `os.log` is decided by
//   ``LogRoute``: on the phone into the ERROR BOOK, which keeps the history across app launches
//   on disk; on the TV into the ring buffer `Diagnostics.Trace`, from
//   which its report and its error trace already read. In addition cleanup, report and the
//   events that exist only on a phone.
//
// **Shared since 2026-09-26** (AP58 R0, finding X0). Until then the package lay under
// `Phone/Packages/` and knew only iOS. Logic that moves out of the surfaces into shared
// packages (`Flows`) writes here — on the phone it would otherwise lose its
// error book lines, on the TV it would exist only in `os.log`.
//
// **The TV's callers stay with `Diagnostics.*` for now** (around 150 places,
// finding X0). They move with their logic to `Flows` (R1–R7) and then write
// through this facade; a mass migration beforehand would only have moved lines.
//
// The package depends on `Core` and on nothing else. It knows no SwiftUI — the display
// of the error book lives in `FeaturesPhone/Diagnose/`.
let package = Package(
    name: "Diagnose",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Diagnose", targets: ["Diagnose"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "Diagnose", dependencies: ["Core"]),
        .testTarget(
            name: "DiagnoseTests",
            dependencies: ["Diagnose"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
