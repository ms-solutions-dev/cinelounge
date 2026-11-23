// swift-tools-version: 6.0
import PackageDescription

// The views. Everything you see and touch.
//
// This is the only package of this project that does NOT come from the TV program and also
// takes nothing over from it: around 50,000 of the 75,000 lines there move along unchanged —
// Core, JellyfinKit, PlaylistKit, PortalKit, RatingsKit, Playback and the models. The 22,373
// lines of views do not move. They are not converted, they are rethought: the TV is operated
// from three meters with a pointer, the phone from thirty centimeters with a thumb that does
// not reach the upper third.
//
// Why everything is nevertheless in ONE package and not nine: because the boundaries worth
// anything lie beneath the views (Core, downloads, parental controls, network condition) and
// not between them. The library and search use the same tiles, the same states, the same
// sheets — a boundary in between would be a boundary straight through the toolbox.
//
// Instead, order is kept with folders, and the cut is fine: one file per view, per sheet,
// per building block, per model. `private` applies file-wide; a fine cut is therefore also
// the encapsulation.
//
// STORE VERSION (ROADMAP A1): Every source must be switchable off at build time, without
// leaving holes — the version for the store comes without portals. Whoever separates that
// only at submission separates too late. The switch lives in `Huelle/SourceSwitch.swift`;
// `PortalKit` and the folder `Portals/` depend on it and on nothing else.
let package = Package(
    name: "FeaturesPhone",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FeaturesPhone", targets: ["FeaturesPhone"])
    ],
    dependencies: [
        // Only for the tests that read source code — see there.
        .package(path: "../../../Packages/SourceProbe"),
        // shared with the TV program
        .package(path: "../../../Packages/Core"),
        .package(path: "../../../Packages/JellyfinKit"),
        .package(path: "../../../Packages/PlaylistKit"),
        .package(path: "../../../Packages/PortalKit"),
        .package(path: "../../../Packages/RatingsKit"),
        // AP78: the trailer from YouTube.
        .package(path: "../../../Packages/Trailer"),
        .package(path: "../../../Packages/Playback"),
        // handy-eigen
        .package(path: "../DesignSystemPhone"),
        .package(path: "../../../Packages/Diagnose"),
        // The shared flows (AP58 R0) — what TV and phone handle identically.
        .package(path: "../../../Packages/Flows"),
        .package(path: "../NetworkStatus"),
        // **Moved into the TV project on 2026-09-07. (G3).** Parental controls are not a phone matter:
        // they belong to the shared packages, and those all live over there. A change to a rule
        // thereby applies immediately to both programs instead of being built twice.
        .package(path: "../../../Packages/ParentalControls"),
        .package(path: "../Downloads"),
        .package(path: "../../../Packages/SecondScreen"),
        // **Since AP41 (2026-09-21).** `SetupState` answers "what is set up here?" from now
        // on from the profile book instead of from the device — and thereby for the person currently
        // operating the app instead of for everyone who picks it up.
        .package(path: "../../../Packages/ProfileKit"),
        // **Since AP58 R2 (2026-09-26):** brand sync, self-registration, signing out and redeeming
        // an invitation — the same version as on the TV.
        .package(path: "../../../Packages/Household"),
        // **`CloudSync` explicitly** (AP58, finding A5): `CloudView` writes `import Wolke`. Until
        // 2026-09-26 it only came in via `ProfileKit`.
        .package(path: "../../../Packages/Grundstock"),
    ],
    targets: [
        .target(
            name: "FeaturesPhone",
            dependencies: [
                "Core", "JellyfinKit", "PlaylistKit", "PortalKit", "RatingsKit", "Playback",
                "DesignSystemPhone", "Diagnose", "Flows", "NetworkStatus", "ParentalControls", "Downloads",
                "SecondScreen", "ProfileKit", "Household", "Trailer",
                .product(name: "CloudSync", package: "grundstock"),
            ]
        ),
        // **With test material** (2026-09-09). House rule: test material is real server responses,
        // not invented sample data — and a real response is too large to write into a string in the
        // source. The folder copy keeps the path `Fixtures/…` in the bundle; the same construction
        // as in the sister project at `PlaylistKit`.
        .testTarget(
            name: "FeaturesPhoneTests", dependencies: ["FeaturesPhone", "Flows", "SourceProbe"],
            resources: [.copy("Fixtures")]),
    ]
)
