// swift-tools-version: 6.0
import PackageDescription

// The shared design of both programs — **roles shared, dimensions per device.**
//
// Until 2026-09-26 (AP58, report B findings 11–19) `DesignSystem` (TV) and
// `DesignSystemPhone` carried the same concepts under different names, two colour boards, two
// contrast formulas, two copied profile colours and two icon registers whose
// meanings crossed. This package separates what is shared (names, roles,
// colour values, icons, profile marks, accessibility aids) from what has to stay different
// per device (dimensions, font sizes, stripe width) — the values stand here
// as a variant per ``UIPlatform`` side by side, in one file per concept.
//
// **The two old packages remain as a thin platform layer** and pass this package
// on with `@_exported`: Focus, button styles and haptics still belong there, and the
// old names forward to the new ones until the call sites have been converted.
//
// **Depends only on `Core`** — not on `Diagnose` and not on `ProfileKit`: The design
// lies beneath everything that draws views, and would otherwise pull the error log or the
// profile logic onto every device that only needs a colour.
let package = Package(
    name: "Styling",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Styling", targets: ["Styling"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../SourceProbe"),
    ],
    targets: [
        .target(name: "Styling", dependencies: ["Core"]),
        .testTarget(name: "StylingTests", dependencies: ["Styling", "SourceProbe"]),
    ]
)
