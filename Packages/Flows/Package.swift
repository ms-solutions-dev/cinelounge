// swift-tools-version: 6.2
import PackageDescription

// The flows that both programs run the same way — **models, not views.**
//
// **Why the package exists** (AP58 R0, report A §1 and X0). Until 2026-09-26 TV and
// phone shared models and rules (`Core`, `ParentalControls`, `ProfileKit` …),
// but no flows: `Phone/ARCHITEKTUR.md` laid down that `Features` is not shared
// but "rethought", and in the process the view models were rewritten too. Around
// 35 areas of logic have stood twice since, and almost all have already drifted apart.
// Here the shared version grows, area by area (R1–R7).
//
// **What may go in here:** `@Observable` models and flows that a screen drives
// without knowing it. **What may not:** SwiftUI views, focus and navigation, engines,
// gestures — the list "expressly not centralizable" in report A. Anyone who writes
// `import SwiftUI` here has missed the cut.
//
// Writing goes through `Diagnose` (on the phone into the error ledger, on the TV into the trace),
// saying goes through `WordingKit` (via `Core.AppLanguageSetting.word`).
let package = Package(
    name: "Flows",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Flows", targets: ["Flows"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Diagnose"),
        // **Since R3 (states, 2026-09-26):** The one failure interpretation reads the error types
        // of the three sources — a refusal by the media server, by the provider and by the
        // portal service. It lives here because it has to interpret identically on both devices.
        .package(path: "../JellyfinKit"),
        .package(path: "../PlaylistKit"),
        .package(path: "../PortalKit"),
        // Only for the check that every key of the states is in the shared catalog.
        .package(path: "../WordingKit"),
        // **Since AP58 R5 (Live, Sports):** `LiveCatalog` compares favorites via the
        // key of the list store (the ``ChannelLock`` has filtered the
        // source since 2026-09-27, `LiveLibrary`); `SportsSchedule`
        // reads via the ``ChannelListingSource``. Both packages themselves depend only on `Core`.
        .package(path: "../ParentalControls"),
        // **Since AP58 R2:** profile PIN and "forgot PIN" (`ProfilePinFlow`,
        // `PinRecoveryFlow`), sharing a profile (`SharingFlow`) and the startup of the
        // profiles (`Startup`, `LegacyData` — for that `PlaylistKit`).
        .package(path: "../ProfileKit"),
        .package(path: "../Household"),
        .package(path: "../Grundstock"),
        .package(path: "../SourceProbe"),
    ],
    targets: [
        .target(
            name: "Flows",
            dependencies: [
                "Core", "Diagnose", "JellyfinKit", "PlaylistKit", "PortalKit", "ParentalControls",
                "ProfileKit", "Household", .product(name: "CloudSync", package: "grundstock"),
            ],
            // As in `Features`: Models that a UI drives live on the
            // main actor. Exceptions are `nonisolated` and pure calculations.
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(
            name: "FlowsTests",
            dependencies: [
                "Flows", "Core", "JellyfinKit", "PlaylistKit", "PortalKit", "WordingKit",
                "ParentalControls", .product(name: "CloudSync", package: "grundstock"),
                "SourceProbe",
            ]),
    ]
)
