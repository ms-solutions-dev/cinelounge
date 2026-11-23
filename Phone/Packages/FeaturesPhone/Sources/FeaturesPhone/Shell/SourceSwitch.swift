import Core

/// Which sources occur in this build variant at all.
///
/// **ROADMAP A1: The store build works without portals, and it must not leave a hole
/// behind** — no empty tab, no dead link, no sentence pointing at something that is
/// missing. Whoever separates only at submission separates too late: then the tab
/// disappears, and Home shows a shelf that no longer loads anything.
///
/// **And until 2026-09-07 the roadmap claimed this was built** — "`SourceSwitch`
/// carries it; `SourceToggleTests` checks it". Both files were comment scaffolds, three
/// and six lines long. The fourth such sentence that day; since E52
/// `scripts/scaffold.py` guards exactly this case.
///
/// ## Why a mutable value and not a plain `#if` switch
///
/// An `#if` condition cannot be flipped in a test — the check run is compiled once, and
/// in the variant that **has** the portals. A test that can only see the built variant
/// never tests the other one, and that is exactly the one that ships.
/// So the build variant is the **default** and the value is a switchable one. The same
/// shape as ``Core/DebugMode/current``.
///
/// ## The gates, and why it is exactly these four
///
/// Counted where the portals enter the app — fourteen files mention them, but they all
/// hang on four places:
///
/// * ``SourceAssembly/portalDataSource(width:)`` — without a source there is no shelf on Home,
///   no search across the portals, no view in the tab, no list in
///   Settings. **This is the gate that carries the most.**
/// * ``CatalogState/hasKey(_:)`` — without an origin there is no tab and no catalog.
/// * ``SettingsModel/Area`` — without a section there is no row in Settings
///   and therefore no hit in the search above it (the catalog derives from it).
/// * ``SourceFormModel`` — without a step there is no question about the bridge on first launch.
///
/// ## How the variant without portals is built
///
/// ```
/// xcodebuild … SWIFT_ACTIVE_COMPILATION_CONDITIONS="OHNE_PORTALE"
/// ```
///
/// `scripts/release.sh` builds it too before uploading — a variant that exists only in the
/// tests and was never compiled is not one.
public enum SourceSwitch {

    /// What the build variant says. **The default and not the effective value.**
    public static let fromBuild: Bool = {
        #if OHNE_PORTALE
            return false
        #else
            return true
        #endif
    }()

    /// Whether the portals occur in this run.
    ///
    /// **Mutable exclusively for tests.** In production nobody writes it; whoever did
    /// would get a tab that vanishes in the middle of operation. Counted on
    /// 2026-09-08: it is written in **three** places, and all three are in the test target.
    ///
    /// ## Why task-local and not `nonisolated(unsafe)`
    ///
    /// **A global mutable value used to live here, and it raised a false alarm twice**
    /// (2026-09-08): "Child mode removes Live and portals from the bar" and
    /// "Every host has a tab that the full state provides" failed in full runs
    /// and passed when run alone.
    ///
    /// The rationale that stood here knew the danger and underestimated it: `.serialized`
    /// on the writing suite orders its tests — **not those of all the others.**
    /// Every other suite runs alongside, and whoever reads in the window between flipping and
    /// resetting sees a variant without portals. With seven test files that
    /// read the bar, it is not a question of whether but of when.
    ///
    /// **`@TaskLocal` solves it at the root instead of with a lock.** A binding applies to
    /// the task tree that sets it and to no other; concurrent tests
    /// can no longer taint each other. In production nobody binds it, so the build variant
    /// applies everywhere — the same behavior as before, just without the shared value.
    ///
    /// It is bound with `SourceSwitch.$portals.withValue(false) { … }`; there is no
    /// reset any more, because there is nothing to reset.
    @TaskLocal public static var portals: Bool = fromBuild

    /// Whether an origin occurs in this build variant.
    ///
    /// **One query for all origins and not one per source.** Today only one
    /// source is on offer; if a second were added (a provider a store does not like),
    /// the question would otherwise appear twice, differently, in the source code.
    public static func hasKey(_ origin: Catalog.Origin) -> Bool {
        switch origin {
        case .portals: portals
        default: true
        }
    }

}
