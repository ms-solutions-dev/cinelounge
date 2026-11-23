// swift-tools-version: 6.0
import PackageDescription

// Downloading, storage budget, cleanup.
//
// Downloads are the market gap (see `entwuerfe/markt-recherche-phone.md`) and were, until
// 2026-09-08, a directory of comments. Since then the **core** stands — the decisions, not the
// bytes: jobs, scope, selection, network rule, the portal job including resumability and
// block calculation, storage budget, store, airplane-mode start.
//
// **What does NOT live here is the fetching itself.** `BackgroundSession` is still a
// scaffold. The separation is deliberate and not accidental: Everything difficult about a
// download is a decision — may it load now, is it the same file, how large may a block be,
// what fits into thirteen hours. That can be tested without a network and without a
// simulator, and therefore it is tested.
//
// What it has to carry and what was never needed on the TV: jobs with a scope
// (episode ↔ season) and resolution, the "Wi-Fi only" rule, pausing on
// cellular, pausing and resuming a running transfer, the
// storage budget with items, cleanup — and the airplane-mode start:
// open the app without a network, the downloads are there immediately, no spinner, no
// login attempt. Plex and the ARD Mediathek fail exactly here, and both
// HAVE downloads (ROADMAP A4).
//
// What each source offers to choose: Jellyfin six tiers, Xtream exactly one
// version (there is only one connection), portals host and language version — at
// the ARD real resolution tiers.
//
// Until 2026-09-08 this said "portals not at all". The decision has been reversed
// (ROADMAP AP2, addendum of 2026-09-08); the reasoning is in
// `SelectionRule` and `PortalJob`, not here.
let package = Package(
    name: "Downloads",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "Downloads", targets: ["Downloads"])],
    dependencies: [
        .package(path: "../../../Packages/Core"),
        .package(path: "../../../Packages/Diagnose"),
        .package(path: "../NetworkStatus"),
    ],
    targets: [
        // `Diagnose` since 2026-09-08: A download is the process about which the question "why did
        // that take so long" is asked most often later — and a swallowed hiccup is exactly the
        // answer that is then missing.
        .target(name: "Downloads", dependencies: ["Core", "Diagnose", "NetworkStatus"]),
        .testTarget(
            name: "DownloadsTests",
            dependencies: ["Downloads"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
