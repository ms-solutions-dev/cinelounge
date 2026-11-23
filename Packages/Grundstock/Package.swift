// swift-tools-version: 6.0
import PackageDescription

// The foundation under all programs for the home lab: certificate, Keychain,
// diagnostics, crash guard, device ID, color board. None of it knows whether a
// film is playing or a book is open above it.
//
// **Why a separate package** (StoryShelf AP1, 2026-09-17): The reading app
// needs exactly these files — and nothing else from `Core`, which is 90 %
// image and sound and brings two C targets. Copying would have produced two
// diverging versions within a month (the `NetworkWatch` duplication of 2026-09-11
// was the warning); depending on all of `Core` would mean compiling
// 30,000 lines of video code on every build.
//
// **The litmus test for every file here:** Would a weather app for the home lab
// need it too? If "image", "sound" or "channel" appears in the name or the first
// comment, it belongs in `Core`.
//
// No third-party dependencies, no network, no SwiftUI — like `Core`, which
// builds on it and re-exports its types with `@_exported`.
//
// **`CloudSync` is the second product** (2026-09-21, CineLounge AP43): the
// CloudKit carrier for everything profile-related — one zone per profile in the
// private database, shared via a share into another account's shared database.
// Built for StoryShelf (E52 there), moved here because CineLounge needs the same
// and a second version would diverge within a month. It passes the same litmus
// test: it knows no session, no watchlist and no channel — only
// records with fields, zones, change tokens, queue and sharing.
//
// **A product of its own and not part of `Grundstock`**, because it links `CloudKit`:
// anyone who needs only the foundation should not have to compile this framework too.
let package = Package(
    name: "Grundstock",
    // macOS for `swift test` on the Mac; iOS for the phone and the reading app.
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Grundstock", targets: ["Grundstock"]),
        .library(name: "CloudSync", targets: ["CloudSync"]),
    ],
    targets: [
        .target(name: "Grundstock"),
        .testTarget(name: "GrundstockTests", dependencies: ["Grundstock"]),
        .target(name: "CloudSync", dependencies: ["Grundstock"]),
        .testTarget(name: "CloudSyncTests", dependencies: ["CloudSync"]),
    ]
)
