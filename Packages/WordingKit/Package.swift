// swift-tools-version: 6.0
import PackageDescription

// The wordings of the shared packages — **one catalog that both programs carry.**
//
// Until 2026-09-26 (AP58 R0, report B finding 4) no shared package had its
// own catalog: Their texts went via `bundle: .main` into the catalog of the app that
// happened to carry them. Every app therefore had to keep every key of every package, and
// nobody checked that — on the phone "German · player.subtitleForced" appeared in the
// track choice. A key that is here is in no app catalog; which catalog
// keeps what is enforced by `scripts/strings.py` and `Phone/scripts/strings.py`.
//
// **Lowest layer, even below `Core`:** `Core` looks things up here, and therefore
// this package hangs on nothing. The app's language choice (`Core.AppLanguageSetting`) passes its
// language in, instead of this package reading it.
//
// `defaultLocalization` is `en`, because both app catalogs keep `en` as source language —
// a fallback to a language other than the apps' would be a third rule.
let package = Package(
    name: "WordingKit",
    defaultLocalization: "en",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "WordingKit", targets: ["WordingKit"])
    ],
    targets: [
        .target(name: "WordingKit", resources: [.process("Resources")]),
        .testTarget(name: "WordingKitTests", dependencies: ["WordingKit"]),
    ]
)
