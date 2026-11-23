import Flows
import Foundation
import SourceProbe
import Testing

@testable import Features

/// The portals in the sidebar — third case of the same shape.
@Suite("Sidebar: portals")
/// On the main actor, because the rules under test live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct SidebarPortalTests {

    private func portal(_ id: String, ready: Bool = true) -> AppSidebar.Portal {
        AppSidebar.Portal(id: id, name: id.capitalized, state: ready ? .ready : .muted)
    }

    /// A portal lives under "Portals" — otherwise the menu button would lead out of the
    /// area instead of up one level.
    @Test("A portal lives under Portals")
    func portalBelongsToPortals() {
        #expect(AppSidebar.mainEntry(for: .portalProvider("serieshub")) == .portals)
        #expect(AppSidebar.mainEntry(for: .portals) == .portals)
        // And the other families stay where they were.
        #expect(AppSidebar.mainEntry(for: .vodProvider("y")) == .vod)
        #expect(AppSidebar.mainEntry(for: .liveProvider("y")) == .live)
    }

    /// The staircase out: portal → Portals → Library. Two steps, as everywhere.
    @Test("The way out leads via Portals to the library")
    func stepOutGoesThroughPortals() {
        let target = AppSidebar.Destination.portalProvider("animehub")
        #expect(target.stepOut == .portals)
        #expect(target.stepOut?.stepOut == .media)
        #expect(target.stepOut?.stepOut?.stepOut == nil)
    }

    /// **Without a portal no level, from one on yes** — and expressly via
    /// the same rule as Live and Movies & Series, so that there are not two
    /// versions of the same decision.
    ///
    /// (When writing this test, "only from two" stood here at first, following
    /// the comment at ``AppSidebar/liveProviders``. The source says something
    /// different: `!ids.isEmpty`. The source prevails.)
    @Test("No level without a portal, one from the first on")
    func levelAppearsFromOne() {
        #expect(AppSidebar.showsProviders(forIDs: []) == false)
        // Since AP59 N5 no level in the sidebar — portals are chosen in the content.
        #expect(!AppSidebar.showsProviders(forIDs: ["serieshub"]))
        #expect(!AppSidebar.showsProviders(forIDs: ["serieshub", "animehub"]))
    }

    /// **A defective portal is shown, not left out.** Otherwise it is simply missing,
    /// and one searches the app for something that the server
    /// has long recognized as broken.
    @Test("A broken portal stays in the list")
    func brokenPortalStaysInTheList() {
        let list = [portal("serieshub"), portal("serieshubtwo", ready: false)]
        #expect(list.count == 2)
        #expect(list.filter(\.isReady).count == 1)
        // The identifier carries on even if it is defective — otherwise the row
        // could not be selected and the reason could be read nowhere.
        #expect(AppSidebar.mainEntry(for: .portalProvider("serieshubtwo")) == .portals)
    }

    /// **The state is already in the list** (decision 27, C11) — one
    /// icon per state, as on the phone.
    @Test("Sign-in, missing setting and silence carry different icons")
    func stateInTheSymbol() {
        let character = [
            PortalState.ready, PortalState("anmeldung"), PortalState("needs_setting"),
            PortalState("stumm"),
        ].map { AppSidebar.Portal(id: "p", name: "P", state: $0).icon }
        #expect(Set(character).count == 4)
        #expect(!AppSidebar.Portal(id: "p", name: "P", state: PortalState("anmeldung")).isReady)
    }

    /// **No caller builds the state from the base text** (check 2026-09-27, Portals
    /// B2) — that is how a known state word became "silent" without reason. Counter-check: with the old call in
    /// `MainView`, `BridgePortalSource` or `Suchquellen` this test turns red.
    @Test(
        "No caller reads the reason as a state word",
        arguments: [
            CodeLocation.features, .featuresPhone,
        ])
    func noReasonAsWord(location: CodeLocation) throws {
        let portalPattern = try NSRegularExpression(pattern: #"Portalzustand\(\s*[\w$.]*grund"#)
        for file in try SourceText.files(in: location) {
            let text = SourceText.strippingCommentLines(file.content)
            let match = portalPattern.numberOfMatches(
                in: text, range: NSRange(text.startIndex..., in: text))
            #expect(match == 0, "\(file.relative) builds the portal state from the reason")
        }
    }
}
