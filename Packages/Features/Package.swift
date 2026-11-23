// swift-tools-version: 6.2
import PackageDescription

// The app's views. Depends on Core (models), DesignSystem (styling)
// and JellyfinKit (content) — but nothing depends on this. That keeps
// the app target thin and the views individually testable.
let package = Package(
    name: "Features",
    // macOS 15, because the toolbar views used here exist there only from
    // this version — the tests run on the computer.
    platforms: [.tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Features", targets: ["Features"])
    ],
    dependencies: [
        // Only for the tests that read source text — see there.
        .package(path: "../SourceProbe"),
        .package(path: "../Core"),
        // The shared flows (AP58 R0) — what TV and phone run identically.
        .package(path: "../Flows"),
        .package(path: "../ParentalControls"),
        .package(path: "../DesignSystem"),
        .package(path: "../JellyfinKit"),
        // The player belongs to the UI, but its engines do not belong here: the
        // picture surface is different with VLC than with the system player, and both
        // live in `Playback`. The framework itself comes as a finished product
        // and only for the TV — the tests here run on the computer and
        // do not see it.
        .package(path: "../Playback"),
        .package(path: "../PlaylistKit"),
        // The third source: foreign portals via the bridge on the home network (AP20).
        .package(path: "../PortalKit"),
        .package(path: "../RatingsKit"),
        // AP78: the trailer from YouTube, a package of its own because of the foreign dependency.
        .package(path: "../Trailer"),
        // The second screen: setup handoff (E67) and remote (AP8). Both
        // speak over the same frame, and both ends live there — the TV
        // uses only the receiver side here.
        .package(path: "../SecondScreen"),
        // **Since AP41, row 5 (2026-09-21).** The account list has become a profile list:
        // Settings shows people, and the credentials live inside them.
        .package(path: "../ProfileKit"),
        // **Since AP58 R2 (2026-09-26):** brand reconciliation, self sign-in, sign-out and
        // redeeming an invitation — one version for TV and phone.
        .package(path: "../Household"),
        // **`CloudSync` explicitly** (AP58, finding A5): `ProfileModel` and `CloudSheet`
        // write `import Wolke`. Until 2026-09-26 it came in only via `ProfileKit` —
        // a refactoring there would have broken this surface without anything stating it here.
        .package(path: "../Grundstock"),
    ],
    targets: [
        .target(
            name: "Features",
            dependencies: [
                "ParentalControls", "Flows",
                "Core", "DesignSystem", "JellyfinKit", "Playback", "PlaylistKit", "PortalKit",
                "RatingsKit", "SecondScreen", "ProfileKit", "Household", "Trailer",
                .product(name: "CloudSync", package: "grundstock"),
            ],
            // **Everything here runs on the main actor unless stated otherwise** (AP32,
            // 2026-09-24). A package full of views and the models that drive them has the
            // main actor as its rule anyway; the 33 individual annotations for it are gone.
            // **The exceptions are `nonisolated` and statements, not silencers:** pure
            // values and computations that previously ran without an actor and touch no state
            // of the surface. The compiler checks them like any other source text.
            // Why `DesignSystem` does not go along is stated in the roadmap under AP32.
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(
            name: "FeaturesTests", dependencies: ["Features", "Flows", "SourceProbe"]),
    ]
)
