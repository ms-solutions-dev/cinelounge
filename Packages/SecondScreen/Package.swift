// swift-tools-version: 6.0
import PackageDescription

// The phone controls the TV — and sets it up.
//
// **Moved here from the phone project on 2026-09-10**, for the same reason as parental
// controls on 2026-09-07. (G3): It is a shared package, and those all live in this directory.
// The trigger was the handoff (AP5): bundle, one-time key and encryption were finished and
// tested in the phone project, and the TV — the receiver — could not reach a single line of
// it. **A channel that only one side knows is not a channel.**
//
// What the package carries is therefore the CONTRACT between two devices and not a user
// interface: the bundle, the key, the packet, the wire. The views live on both sides in
// their own program — on the phone in `FeaturesPhone/Einrichtung`, on the TV in `Features`.
//
// **The remote is decided and built.** Whether it goes through Jellyfin's session commands
// or through a wire of its own depended on measurement M3 — and the handoff has answered
// that: if the channel carries the handoff, it carries the remote too. The contracts for it
// have been filled in alongside since then: `Command`, `StateMirror`, `RemoteKeyboard`,
// plus `OwnWire`, `RemoteReceiver` and `ControlPath`.
//
// **Until 2026-09-11 this said the opposite** — that the three were still to be
// built — while `Sources/Zweitschirm` sat right next to it with sixteen files and
// 1,677 lines. That sentence was the quietest error this package had: It did not throw, it
// reported nothing, and whoever searched for a wire built it a second time (AP22).
//
// **One reservation remains, and it belongs here:** `RemoteKeyboard` is built and tested but
// connected to **no** input field — `signIn` and `signOut` have zero callers, `pending` stays
// `false`, and a line typed on the phone is discarded. The wiring is in AP24 and is
// explicitly "build once plus ten places individually".
let package = Package(
    name: "SecondScreen",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [.library(name: "SecondScreen", targets: ["SecondScreen"])],
    dependencies: [
        // Only for the checks that read source text — see there.
        .package(path: "../SourceProbe"),
        .package(path: "../Core"), .package(path: "../ParentalControls"),
        .package(path: "../PlaylistKit"),
        // **Since AP44 (2026-09-21).** In version 2 the bundle carries the profiles —
        // the wire is the way back for devices without iCloud, and a way back that only carries the
        // signed-in account sets up a device on which the family is missing.
        .package(path: "../ProfileKit"),
        // **Since 2026-09-27** (ultra e5, round A.8): Pairing, handoff and connection
        // write to the log at every decision point — on the phone into the error book,
        // on the TV into the trace. Until then this package had zero log points,
        // and "pairing does not work" could only be clarified by asking back.
        .package(path: "../Diagnose"),
    ],
    targets: [
        .target(
            name: "SecondScreen",
            dependencies: ["Core", "Diagnose", "ParentalControls", "PlaylistKit", "ProfileKit"]),
        .testTarget(name: "SecondScreenTests", dependencies: ["SecondScreen", "SourceProbe"]),
    ]
)
