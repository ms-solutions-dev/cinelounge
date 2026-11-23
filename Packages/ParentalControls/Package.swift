// swift-tools-version: 6.0
import PackageDescription

// Age limits, PIN and the sixteen locked doors.
//
// Moved here from the phone project on 2026-09-07 (G3): it is one of the shared
// packages, and those all live in this directory. Since then the phone pulls it in
// through a path, like the six others — so a change to a rule applies to both
// programs at once.
//
// In the TV program, parental controls were a single comment line in
// `LivePreferences.swift:21` until then. `MediaItem.ageRating` is DISPLAYED in four
// places and CHECKED in none.
//
// Why a package of its own and not a folder in the views: because this is where the
// one kind of bug lives that you cannot see on screen. The most serious finding of the
// usability pass was that parental controls claimed to lock what they did not lock â
// from the child account, four taps led to the "Adult channels" switch, without a PIN.
// A gap like that is found with a test over a rule table, not with the eye.
//
// Key sentence from `_EINBAU-NOTIZEN.md`: the server's user policy is READ AND
// DISPLAYED, but the app will not RELY on it.
let package = Package(
    name: "ParentalControls",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ParentalControls", targets: ["ParentalControls"])],
    dependencies: [.package(path: "../Core"), .package(path: "../Diagnose")],
    targets: [
        .target(name: "ParentalControls", dependencies: ["Core", "Diagnose"]),
        .testTarget(
            name: "ParentalControlsTests",
            dependencies: ["ParentalControls"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
