import Foundation
import Testing

@testable import Core

/// The rules of the shelf order that TV and phone have shared since the check pass of
/// 2026-09-27 (findings A-S6, A-S7, A-S8).
struct ShelfViewTests {

    // MARK: - A-S7: eine Sichtbarkeitsregel

    @Test("“From the portals” hidden: the TV also hides the portal folder shelves")
    func portalSlotHidesFolders() {
        let preferences = ShelfPreferences(hidden: [ShelfIdentifier.portals])
        #expect(!preferences.isVisible("animehub|beliebt|/serien"))
        #expect(preferences.isVisible("resume"))
    }

    @Test("A hidden tab shelf hides its categories — on both devices")
    func registerShelfHidesCategories() {
        let preferences = ShelfPreferences(hidden: ["liste|vod"])
        #expect(!preferences.isVisible("liste|vod|4711"))
        #expect(preferences.isVisible("liste|series|12"))
        #expect(ShelfView.shows("liste|vod|4711", hidden: ["liste|vod"]) == false)
    }

    @Test("Whoever enables a folder while portals are hidden sees exactly that one")
    func enablingResolvesTheCollectiveStatement() {
        var preferences = ShelfPreferences(hidden: [ShelfIdentifier.portals])
        let folder = ["animehub|beliebt|/serien", "sto|neu|/neu"]
        preferences.setVisible(true, for: folder[0], within: ["resume"] + folder)
        #expect(preferences.isVisible(folder[0]))
        #expect(!preferences.isVisible(folder[1]))
    }

    // MARK: - A-S6: abwesende Regale behalten ihren Platz

    @Test("Reordering leaves identifiers that are missing today in place")
    func leadKeepsAbsent() {
        let fresh = ShelfView.merge(
            order: ["a", "fehlt", "b", "c"], using: ["c", "a", "b", "neu"])
        #expect(fresh == ["c", "fehlt", "a", "b", "neu"])
    }

    @Test("Duplicate identifiers in the order drop out when merging")
    func leadDeduplicated() {
        let fresh = ShelfView.merge(order: ["a", "a", "b"], using: ["b", "b", "a"])
        #expect(fresh == ["b", "a"])
    }

    // MARK: - A-S8: Kopfbereich je Profil

    @Test("The hero area choice lives in the profile order — the TV reads and writes it")
    func heroShelvesPerProfile() {
        let store = InMemoryStore()
        var preferences = ShelfPreferences.load(from: store, forItem: "anna")
        preferences.fillHeroes("filme", false, from: ["filme", "serien"])
        preferences.save(to: store, forItem: "anna")

        #expect(ShelfOrder.read(from: store, forItem: "anna").heroShelves == ["serien"])
        let read = ShelfPreferences.load(from: store, forItem: "anna")
        #expect(!read.fillsHeroes("filme"))
        #expect(read.fillsHeroes("serien"))
        #expect(ShelfPreferences.load(from: store, forItem: "benedikt").fillsHeroes("filme"))
    }

    @Test("Without its own choice the device's old exclusion list still applies")
    func deviceChoiceAsFallback() {
        let device = HeroPreferences(excluded: ["heim"])
        var preferences = ShelfPreferences()
        #expect(!preferences.fillsHeroes("heim", device: device))
        #expect(preferences.fillsHeroes("filme", device: device))

        // The first own choice starts from what applied until then.
        preferences.fillHeroes("filme", false, from: ["filme", "serien", "heim"], device: device)
        #expect(preferences.heroShelves == ["serien"])
    }

    @Test("The last hero shelf cannot be deselected — empty would again mean “all”")
    func lastRemains() {
        var preferences = ShelfPreferences()
        preferences.fillHeroes("filme", false, from: ["filme", "serien"])
        preferences.fillHeroes("serien", false, from: ["filme", "serien"])
        #expect(preferences.heroShelves == ["serien"])
    }
}
