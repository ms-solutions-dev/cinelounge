// swift-tools-version: 6.0
import PackageDescription

// One person, their access, their settings — the same for both programs.
//
// Created on 2026-09-21 (AP41). The central finding of the 2026-09-19 review:
// **There is no profile concept.** "Account" is a Jellyfin user, channel lists hang on
// the device, the server person is a third login via a device token — three places to
// switch and three owners for the question "where did I leave off".
//
// Why a package of its own and not a folder in the views: `Account`,
// `AccountsModel`, `UmzugModell`, `AccountState` and `SetupState` currently live in
// `Features` and `FeaturesPhone` **separately** — the accounts model alone separates 195
// lines, and the rule "move without server ID" is opposite on the two sides. A concept
// that both programs interpret differently is not a concept.
//
// Pure logic and no SwiftUI: what a profile is must be answerable with a test suite and
// not with a screenshot.
let package = Package(
    name: "ProfileKit",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ProfileKit", targets: ["ProfileKit"])],
    // `CloudSync` from `grundstock` carries the CloudKit sync (AP43). **Here and not in
    // `Core`:** `TopShelf` depends on `Core` and on nothing else — deliberately, because it is a
    // process with a budget of seconds. If the mapping lived there, the extension would pull
    // in CloudKit without ever opening a zone.
    dependencies: [
        // Only for the checks that read source text — see there.
        .package(path: "../SourceProbe"),
        .package(path: "../Core"), .package(path: "../ParentalControls"),
        .package(path: "../Grundstock"),
    ],
    targets: [
        .target(
            name: "ProfileKit",
            dependencies: [
                "Core", "ParentalControls", .product(name: "CloudSync", package: "grundstock"),
            ]),
        .testTarget(name: "ProfileKitTests", dependencies: ["ProfileKit", "SourceProbe"]),
    ]
)
