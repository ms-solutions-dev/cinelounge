import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// That the version without portals has no holes.
///
/// **No empty tab, no dead link, no sentence that points to something missing** —
/// ROADMAP A1. Whoever separates only at submission separates too late: Then the tab drops,
/// and the Home screen shows a shelf that loads nothing any more.
///
/// **This file was six lines of comment until 2026-09-07**, while the roadmap
/// claimed it checked this. The fourth such sentence on that day.
///
/// **It is checked against the switched size and not against the build type.** A check run is
/// compiled once, and in the version **with** portals; a check that can only see the
/// built version never sees the shipped one.
@Suite("Source toggles", .serialized)
struct SourceToggleTests {

    /// **`.serialized` on the suite and `reset()` after every check.** The
    /// size is shared; two checks that switch it concurrently color each other,
    /// and which wins depends on an order that does not exist.
    ///
    /// **And `.serialized` is not enough** — it orders the checks of **this** suite,
    /// not of all. Every other runs alongside, and whoever reads the bar in the window between switching
    /// and switching back sees a version without portals. Exactly that
    /// happened on 2026-09-08; see ``Source togglessperre``.
    private func lacksPortals(_ check: () throws -> Void) rethrows {
        try SourceSwitch.$portals.withValue(false, operation: check)
    }

    private static func state() -> CatalogState {
        CatalogState([
            Catalog(
                id: .init(.portals, .portalLevel, "alle"), origin: .portals,
                label: .key("tab.portals"), kind: .portalLevel,
                sourceIdentifier: "alle", extent: 3)
        ])
    }

    /// **The tab drops even if the catalog still stands.** That is the case one
    /// really has: A viewer sets up with portals, then a version comes
    /// without them — the catalog still lies in the Keychain. A dimmed or empty
    /// tab would be an invitation to something that does not exist.
    @Test("Without portals there is no portals tab")
    func noTab() {
        #expect(Self.state().tabs.contains(.portals), "with portals it is there")
        lacksPortals {
            #expect(!Self.state().tabs.contains(.portals))
            #expect(!Self.state().hasKey(.portals))
        }
    }

    /// **Without a source no shelf, no search, no view.** The gate that carries the
    /// most: Fourteen files name the portals, and almost all hang on this factory.
    @MainActor
    @Test("Without portals there is no portal source")
    func noSource() {
        lacksPortals {
            let source = SourceAssembly.portalDataSource(width: 110)
            #expect(source == nil)
        }
    }

    /// **And no row in Settings.** It would be the dead link: It leads to a
    /// screen that looks for a bridge that this version does not address.
    @Test("Without portals there is no portals settings section")
    func noArea() {
        #expect(SettingsModel.Area.available.contains(.portals))
        lacksPortals {
            #expect(!SettingsModel.Area.available.contains(.portals))
        }
    }

    /// **And no search hit that leads there.** The catalog derives its
    /// section entries from the same list; a hit on a screen that does not
    /// exist would be "linked but not built" — produced only at build time.
    @Test("Without portals the settings search finds no portals section")
    func noMatch() {
        lacksPortals {
            let targets = Set(SettingsCatalog.all.map(\.view))
            #expect(!targets.contains(.portalSettings))
            #expect(!SettingsCatalog.all.contains { $0.area == .portals })
        }
    }

    /// **The build type stays the default.** Without this check nobody would notice if
    /// someone hard-wired the value by mistake — the version with portals is the one in
    /// which all other checks run, and it would still look right.
    ///
    /// **Since 2026-09-08 what is checked is the binding and no longer the reset.** The
    /// size has become task-local: A binding applies to the task tree that sets it and
    /// ends with it — there is nothing left to reset, and exactly **that** is
    /// the promise that belongs recorded here. Before, this said "After reset, what the
    /// build type says applies again"; that was right and did not protect against a
    /// concurrent check reading in the window in between.
    @Test("Outside the binding, what the build type says applies again")
    func bindingEnds() {
        SourceSwitch.$portals.withValue(false) {
            #expect(!SourceSwitch.portals)
        }
        #expect(SourceSwitch.portals == SourceSwitch.fromBuild)
    }
}

/// The environment fallback — **ROADMAP AP4.**
///
/// **On screen it said "Channel lists · none" in gold while the app ran with a
/// provider access.** Both were true: Settings show what is **set up**,
/// and an access from `CINELOUNGE_XTREAM` is not set up. Correct and yet
/// misleading — gold means in this app "something is missing here that can be added", and
/// nothing was missing; it just stood elsewhere.
///
/// **The roadmap wrote: "with the first real setup the contradiction
/// disappears."** That is true and no answer: The check hook exists so that one can look
/// **without** setup — and it was exactly there that the value column lied.
@Suite("Environment fallback")
struct EnvironmentFallbackTests {

    @Test("An access from the environment is recognised as such")
    func detected() {
        let using = ["CINELOUNGE_XTREAM": "http://beispiel.invalid"]
        #expect(SourceAssembly.fromEnvironment(.channelList, environment: using))
        // **The provider counts too, and that is no convenience:** The same access
        // brings channels **and** catalog — see `Catalog.Origin.provider`.
        #expect(SourceAssembly.fromEnvironment(.provider, environment: using))
        #expect(!SourceAssembly.fromEnvironment(.jellyfin, environment: using))
    }

    /// **Without variables nothing comes from the environment** — the case of the shipped
    /// program. Without this check the new value would be a line that never applies
    /// on the device and would still be everywhere.
    @Test("Without variables nothing comes from the environment")
    func empty() {
        for origin in Catalog.Origin.allCases {
            #expect(!SourceAssembly.fromEnvironment(origin, environment: [:]))
        }
    }

    /// **`CINELOUNGE_AUFENTHALT=everything` is the view mode** and switches every origin
    /// on. It must be checked along, because it is the only place where a single
    /// variable changes **all** answers.
    @Test("The view mode turns every origin on")
    func stay() {
        let everything = ["CINELOUNGE_AUFENTHALT": "alles"]
        for origin in Catalog.Origin.allCases {
            #expect(SourceAssembly.fromEnvironment(origin, environment: everything))
        }
    }
}
