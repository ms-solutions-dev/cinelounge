// swift-tools-version: 6.2
import PackageDescription

// The household at the CineLounge server, seen from the app (AP58 R2, finding P3).
//
// **Profile and portals together, and therefore a package of its own.** The person mark lives
// in the profile (``ProfileKit/PortalMarkerSlot``), the way to the server in ``PortalKit``. Until
// 2026-09-26 the sync therefore existed twice in the programmes — on the TV in
// `JoinFlow.swift`, on the phone in `TokenReconciliation.swift`, ninety percent
// character-identical and already drifted apart (loaner device, self sign-in). `ProfileKit` is not supposed to know
// PortalKit, PortalKit no profile; so the connection sits here.
let package = Package(
    name: "Household",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Household", targets: ["Household"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Diagnose"),
        .package(path: "../PortalKit"),
        .package(path: "../ProfileKit"),
    ],
    targets: [
        .target(
            name: "Household",
            dependencies: ["Core", "Diagnose", "PortalKit", "ProfileKit"],
            // As in `Features` and `Flows`: What a UI calls lives on the main
            // actor. Pure calculations are `nonisolated`.
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "HouseholdTests", dependencies: ["Household"]),
    ]
)
