import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// Where a portal shelf stands on the Home screen.
///
/// **The finding of 2026-09-12, from review:** Portals ends up, for example, right
/// after "Recently added" … but with 5 portals here, the order in which each one
/// stands should be configurable.
///
/// Dragging already worked, and ``HomeViewModel/move(from:after:)`` wrote the own
/// IDs properly into the order — ``StartPreferences/arrange(_:)`` just never read them:
/// There stood only `representative(shelf.id)`, that is, the same rank for every portal shelf.
/// Five portal shelves thus stayed one block.
@Suite("The order of portal shelves")
struct PortalShelfOrderTests {

    /// A shelf as ``ShelvesPerPortalFolder`` builds it from a chosen folder — the
    /// form of the ID is decided by ``Shelf/Identifier/zu(_:)`` and not by this check.
    ///
    /// **A real level ID** (`portal|Suchbegriff|EntryPoint`): Since AP58 R6
    /// ``StartPreferences/isPortalShelf(_:)`` recognizes a portal shelf by this form and no longer
    /// by a prefix.
    private func portalShelf(_ name: String) -> Shelf {
        Shelf(
            id: .zu(.init(.portals, .portalLevel, "\(name)||start")),
            label: .wording(name), sources: [.portals])
    }

    private func fixedShelf(_ identifier: String) -> Shelf {
        Shelf(id: .fixed(identifier), label: .wording(identifier), sources: [.jellyfin])
    }

    /// **The reported case:** a portal shelf between two fixed ones.
    @Test("A portal shelf can be placed individually between two others")
    func individuallySettable() {
        let fresh = fixedShelf("zuletztHinzugefuegt")
        let animehub = portalShelf("animehub")
        let movies = fixedShelf("filme")
        let preferences = StartPreferences(
            order: [fresh.id, animehub.id, movies.id])

        let ordered = preferences.arrange([movies, fresh, animehub])
        #expect(ordered.map(\.id) == [fresh.id, animehub.id, movies.id])
    }

    /// **Five portals, five places** — and not one block.
    @Test("Several portal shelves stay where they were dragged")
    func fivePortals() {
        let one = portalShelf("animehub")
        let two = portalShelf("serieshub")
        let three = portalShelf("ahorn")
        let movies = fixedShelf("filme")
        let live = fixedShelf("live")
        // Dragged: one portal to the front, one between the fixed ones, one to the back.
        let preferences = StartPreferences(
            order: [one.id, live.id, two.id, movies.id, three.id])

        let ordered = preferences.arrange([movies, three, live, one, two])
        #expect(ordered.map(\.id) == [one.id, live.id, two.id, movies.id, three.id])
    }

    /// **The inheritance stays the fallback, and that is why it exists.**
    ///
    /// Anyone who has dragged "From the portals" up has said that about **the portals**.
    /// A freshly chosen portal shelf does not yet appear in the order — it continues to inherit
    /// this place, instead of falling below all library shelves by "what the order
    /// does not know falls to the back".
    @Test("What the order does not know inherits the portals' place")
    func inheritsThePosition() {
        let portals = fixedShelf("portale")
        let movies = fixedShelf("filme")
        let fresh = portalShelf("svt")
        let preferences = StartPreferences(order: [portals.id, movies.id])

        let ordered = preferences.arrange([movies, fresh])
        // The portals' place lies before "Movies" — so the fresh shelf stands at the front.
        #expect(ordered.map(\.id) == [fresh.id, movies.id])
    }

    /// Two shelves that both still inherit must not swap places at every start —
    /// `sorted` is not stable.
    @Test("Two inheriting portal shelves keep their creation order")
    func inheritorsStayStable() {
        let portals = fixedShelf("portale")
        let one = portalShelf("animehub")
        let two = portalShelf("serieshub")
        let preferences = StartPreferences(order: [portals.id])

        for _ in 0..<5 {
            #expect(preferences.arrange([one, two]).map(\.id) == [one.id, two.id])
        }
    }
}

/// What the switch of a portal-shelf row does.
///
/// **The finding of 2026-09-12:** The switch wrote `representative(shelf)`, that is,
/// `ausDenPortalen` — it thereby hid **all** portal shelves. That was right
/// as long as the portals were one block; since each can be set individually, it looked
/// as if it belonged to its row, and did something else.
///
/// The difficult part is not the switch but the **migration**: A
/// collective statement ("all portals off") and an individual statement ("this one on")
/// contradict each other, and without resolution the first press would be a button without effect.
@Suite("The toggle per portal shelf")
struct PortalShelfToggleTests {

    private func portal(_ name: String) -> Shelf.Identifier {
        .zu(.init(.portals, .portalLevel, "\(name)||start"))
    }
    private var allIdentifiers: [Shelf.Identifier] {
        [portal("animehub"), portal("serieshub"), portal("ahorn")]
    }

    @Test("Hiding affects only its own row")
    func hideIndividually() {
        var preferences = StartPreferences()
        preferences.show(portal("animehub"), false, from: allIdentifiers)
        #expect(preferences.shows(portal("animehub")) == false)
        #expect(preferences.shows(portal("serieshub")))
        #expect(preferences.shows(portal("ahorn")))
    }

    /// **The collective statement continues to apply as long as nobody touches a row.** Anyone who
    /// switched off "From the portals" has said that about the portals.
    @Test("An old collective statement still hides all")
    func collectiveStatementStillApplies() {
        let preferences = StartPreferences(hidden: [StartPreferences.portalSlot])
        for identifier in allIdentifiers { #expect(preferences.shows(identifier) == false) }
    }

    /// **The core of the migration.** Without it the row would stay off although the switch is
    /// on — `shows(_:)` would let the collective statement win.
    @Test("Turning on one row dissolves the collective statement")
    func migrationOnEnabling() {
        var preferences = StartPreferences(hidden: [StartPreferences.portalSlot])
        preferences.show(portal("animehub"), true, from: allIdentifiers)

        // The one is on, the others stay off — the state changed only for the
        // touched row.
        #expect(preferences.shows(portal("animehub")))
        #expect(preferences.shows(portal("serieshub")) == false)
        #expect(preferences.shows(portal("ahorn")) == false)
        // And the collective statement is gone, otherwise it would win again at the next read.
        #expect(preferences.hidden.contains(StartPreferences.portalSlot) == false)
    }

    /// **Without a collective statement nothing migrates.** Anyone who never hid their
    /// portals does not get three entries in the store.
    @Test("Without a collective statement the store stays lean")
    func noMigrationWithoutReason() {
        var preferences = StartPreferences()
        preferences.show(portal("animehub"), true, from: allIdentifiers)
        #expect(preferences.hidden.isEmpty)
    }

    /// The collective switch itself — it is there as long as no folder is chosen — continues
    /// to work as before.
    @Test("The collective toggle stays the collective toggle")
    func collectiveToggle() {
        var preferences = StartPreferences()
        preferences.show(StartPreferences.portalSlot, false, from: allIdentifiers)
        #expect(preferences.shows(StartPreferences.portalSlot) == false)
        for identifier in allIdentifiers { #expect(preferences.shows(identifier) == false) }
    }

    /// A shelf that is not a portal shelf does not know the migration.
    @Test("Other shelves stay untouched")
    func othersUntouched() {
        var preferences = StartPreferences(hidden: [StartPreferences.portalSlot])
        preferences.show(.fixed("filme"), false, from: allIdentifiers)
        #expect(preferences.shows(.fixed("filme")) == false)
        // The collective statement still stands — no portal shelf was touched.
        #expect(preferences.hidden.contains(StartPreferences.portalSlot))
    }
}
