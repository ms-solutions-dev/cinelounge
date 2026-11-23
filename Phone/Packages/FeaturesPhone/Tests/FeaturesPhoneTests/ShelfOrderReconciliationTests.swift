import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// **The "done when" check of AP40, applied to the shelf order.**
///
/// *A check reads the value of one app with the reader of the other.* A check
/// that queries only its own side would be green again at the next rename — that is exactly how
/// the sixteen deviations of 2026-09-19 arose, without any check run turning red.
///
/// **The TV writes with ``Core/ShelfPreferences``, the phone reads with
/// ``StartPreferences``** — and vice versa. Both types remain what they are; shared
/// since 2026-09-21 is the store (``Core/ShelfOrder``, `shelves.json`).
@Suite("Shelf order: the same reader on both sides")
struct ShelfOrderReconciliationTests {

    @Test("What the TV orders, the phone reads")
    func fromTVToPhone() {
        let bucket = InMemoryStore()

        var otherSide = ShelfPreferences(order: ["resume", "live", "neu:jellyfin:filme:42"])
        otherSide.setVisible(false, for: "portale")
        otherSide.selectChannel("Das Nordlicht HD", on: true)
        otherSide.select(.init(identifier: "animehub|x|y", name: "Animehub · Beliebte"), on: true)
        otherSide.save(to: bucket)

        let here = StartPreferences.load(from: bucket)
        #expect(here.order.map(\.rawValue) == ["resume", "live", "neu:jellyfin:filme:42"])
        #expect(here.shows(.fixed("portale")) == false)
        #expect(here.liveChannel == ["Das Nordlicht HD"])
        #expect(here.portalFolders.map(\.name) == ["Animehub · Beliebte"])
    }

    @Test("What the phone orders, the TV reads")
    func fromPhoneToTV() {
        let bucket = InMemoryStore()

        var here = StartPreferences.preset
        here.set(order: [.fixed("resume"), .fixed("live"), .fixed("portale")])
        here.show(.fixed("live"), false)
        here.set(liveChannel: ["ZINNE HD"])
        here.set(
            portalFolders: .init(identifier: "serieshub|x|y", name: "Beliebte Serien"),
            under: "serieshub", atMost: 3)
        here.save(to: bucket)

        let otherSide = ShelfPreferences.load(from: bucket)
        #expect(otherSide.order == ["resume", "live", "portale"])
        #expect(otherSide.isVisible("live") == false)
        #expect(otherSide.liveChannel == ["ZINNE HD"])
        #expect(otherSide.portalFolders.map(\.identifier) == ["serieshub|x|y"])
        // **The fixed rows are named the same on both sides** (AP40, 2026-09-20) — and
        // that is why the arrangement arrives here at all. `arrange(_:)` skips what it does
        // not know; before the alignment every transferred order was exactly that.
        #expect(otherSide.arrange(["resume", "live", "portale"]) == ["resume", "portale"])
    }

    /// **Neither side clears anything away from the other.**
    ///
    /// The hero shelves exist only here, the provider categories only over there. Whoever, when
    /// saving, reinvented the file instead of changing it would take the foreign part
    /// from the transferred state — silently, because it does not know that it exists.
    @Test("What one side does not know survives the other side saving")
    func foreignSurvives() {
        let bucket = InMemoryStore()

        var otherSide = ShelfPreferences(order: ["resume"])
        otherSide.selectCategory("de-kino", on: true)
        otherSide.setShelvesPerProvider(8)
        otherSide.save(to: bucket)

        var here = StartPreferences.load(from: bucket)
        here.fillHeroes(.fixed("resume"), true, from: [.fixed("resume"), .fixed("live")])
        here.save(to: bucket)

        let back = ShelfPreferences.load(from: bucket)
        #expect(back.providerCategories == ["de-kino"])
        #expect(back.shelvesPerProvider == 8)
        #expect(StartPreferences.load(from: bucket).fillsHeroes(.fixed("resume")))
    }
}
