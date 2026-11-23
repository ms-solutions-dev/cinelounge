import Foundation
import Testing

@testable import Core

/// Order and visibility of the rows. As with ``HeroPreferences``, the core is not in
/// saving but in the behavior when the catalog changes: a library that is added or
/// disappears must not invalidate the setting.
@Suite("Home screen rows")
struct ShelfPreferencesTests {

    private let available = ["resume", "serien", "filme", "heim"]

    @Test("Without a setting the default order stays")
    func defaultKeepsOrder() {
        let preferences = ShelfPreferences()

        #expect(preferences.arrange(available) == available)
    }

    @Test("The saved order is applied")
    func customOrder() {
        let preferences = ShelfPreferences(order: ["filme", "resume", "heim", "serien"])

        #expect(preferences.arrange(available) == ["filme", "resume", "heim", "serien"])
    }

    @Test("A newly added row appears at the end, not nowhere")
    func newShelfAppears() {
        // The most important case: whoever sets an order today and creates a library
        // tomorrow should see it. With a strict list it would be invisible, and one searches
        // for the bug in the app.
        let preferences = ShelfPreferences(order: ["resume", "serien"])

        let arranged = preferences.arrange(["resume", "serien", "filme", "neu"])

        #expect(arranged.prefix(2) == ["resume", "serien"])
        #expect(arranged.contains("neu"))
        #expect(arranged.contains("filme"))
    }

    @Test("A vanished row does not disturb the order")
    func removedShelfIgnored() {
        // Happens when a library is deleted. The setting still names it — it should be
        // skipped, not leave a gap.
        let preferences = ShelfPreferences(order: ["resume", "gelöscht", "serien"])

        #expect(preferences.arrange(["resume", "serien"]) == ["resume", "serien"])
    }

    @Test("Hidden rows do not appear")
    func hiddenAreOmitted() {
        var preferences = ShelfPreferences()
        preferences.setVisible(false, for: "heim")

        let arranged = preferences.arrange(available)

        #expect(!arranged.contains("heim"))
        #expect(arranged.count == 3)
        #expect(preferences.isVisible("serien"))
    }

    @Test("Hiding and showing again leaves no residue")
    func toggleVisibility() {
        var preferences = ShelfPreferences()

        preferences.setVisible(false, for: "filme")
        #expect(!preferences.isVisible("filme"))

        preferences.setVisible(true, for: "filme")
        #expect(preferences.isVisible("filme"))
        #expect(preferences.hidden.isEmpty)
    }

    // MARK: - Verschieben

    @Test("Moving swaps with the neighbour")
    func moveSwapsNeighbours() {
        var preferences = ShelfPreferences()
        preferences.move("filme", up: true, within: available)

        #expect(preferences.arrange(available) == ["resume", "filme", "serien", "heim"])
    }

    @Test("Moving also works with an empty setting")
    func moveFromEmptyState() {
        // On the first move no sequence is saved yet. Without the existing identifiers the
        // method would not know between which neighbors the swap happens — that is why it is
        // given them.
        var preferences = ShelfPreferences()
        #expect(preferences.order.isEmpty)

        preferences.move("heim", up: true, within: available)

        #expect(preferences.order.count == available.count)
        #expect(preferences.arrange(available) == ["resume", "serien", "heim", "filme"])
    }

    @Test("Nothing is lost at the edge")
    func moveAtEdges() {
        var preferences = ShelfPreferences(order: available)

        // The first one further up, the last one further down — both must do nothing and
        // break nothing.
        preferences.move("resume", up: true, within: available)
        #expect(preferences.arrange(available) == available)

        preferences.move("heim", up: false, within: available)
        #expect(preferences.arrange(available) == available)
    }

    @Test("Moving an unknown identifier changes nothing")
    func moveUnknown() {
        var preferences = ShelfPreferences(order: available)
        preferences.move("gibtsnicht", up: true, within: available)

        #expect(preferences.arrange(available) == available)
    }

    // MARK: - Ablage

    @Test("Order and hidden rows survive saving and loading")
    func survivesStorage() {
        let store = InMemoryStore()

        var saved = ShelfPreferences(order: ["filme", "resume"])
        saved.setVisible(false, for: "heim")
        saved.save(to: store)

        let loaded = ShelfPreferences.load(from: store)

        #expect(loaded.order == ["filme", "resume"])
        #expect(loaded.hidden == ["heim"])
    }

    @Test("An empty setting clears the file")
    func emptyRemovesEntries() {
        let store = InMemoryStore()

        var preferences = ShelfPreferences(order: ["a"])
        preferences.setVisible(false, for: "b")
        preferences.save(to: store)

        ShelfPreferences().save(to: store)

        // **No entry and not an empty one.** A file with nothing but empty lists says the
        // same thing and looks like a setting that nobody made.
        #expect((try? store.value(for: ShelfOrder.key)) == nil)
        #expect(ShelfPreferences.load(from: store) == ShelfPreferences())
    }

    @Test("Unreadable data in the store yields the default and no crash")
    func brokenStoredValue() {
        // ``FileStore`` cannot leave half a file behind — it writes completely and
        // replaces. It can still be written into by hand, and then "as new" is the only
        // answer that takes nobody's Home screen away.
        let store = InMemoryStore()
        try? store.set("{kein JSON", for: ShelfOrder.key)

        #expect(ShelfPreferences.load(from: store) == ShelfPreferences())
    }

    @Test("A foreign field survives saving this page")
    func foreignFieldSurvives() {
        // Only the phone sets the hero shelves; here they do not exist. Whoever invented the
        // file anew when moving a row instead of changing it would remove them — and nobody
        // would notice, because this side does not know that they exist.
        let store = InMemoryStore()
        ShelfOrder(heroShelves: ["filme"]).write(in: store)

        var preferences = ShelfPreferences.load(from: store)
        preferences.setVisible(false, for: "heim")
        preferences.save(to: store)

        #expect(ShelfOrder.read(from: store).heroShelves == ["filme"])
        #expect(ShelfOrder.read(from: store).hidden == ["heim"])
    }

    // MARK: - What used to live in the Keychain

    @Test("The old version migrates into the file — separators and all")
    func migratesFromKeychain() {
        let legacy = InMemoryStore()
        try? legacy.set("filme;resume", for: "shelves.order")
        try? legacy.set("heim", for: "shelves.hidden")
        try? legacy.set("animehub|x|y\u{001F}Animehub · Beliebte", for: "shelves.portalFolders")
        try? legacy.set("ahorn;zinne", for: "shelves.liveChannels")
        try? legacy.set("8", for: "shelves.providerShelves")
        try? legacy.set("de-kino", for: "shelves.providerCategories")
        let fresh = InMemoryStore()

        #expect(ShelfPreferences.adopt(from: legacy, in: fresh))

        let read = ShelfPreferences.load(from: fresh)
        #expect(read.order == ["filme", "resume"])
        #expect(read.hidden == ["heim"])
        #expect(read.liveChannel == ["ahorn", "zinne"])
        #expect(!read.liveChannelsNamed, "identifiers come from the Keychain")
        #expect(read.shelvesPerProvider == 8)
        #expect(read.providerCategories == ["de-kino"])
        #expect(read.portalFolders.map(\.name) == ["Animehub · Beliebte"])
        // **Afterwards the Keychain is empty** — otherwise a second truth would remain, and
        // the next version would read it again.
        #expect((try? legacy.value(for: "shelves.order")) == nil)
    }

    @Test("A migration overwrites nothing that is already set")
    func migrationNeverOverwrites() {
        let legacy = InMemoryStore()
        try? legacy.set("filme", for: "shelves.order")
        let fresh = InMemoryStore()
        ShelfPreferences(order: ["serien"]).save(to: fresh)

        #expect(ShelfPreferences.adopt(from: legacy, in: fresh) == false)
        #expect(ShelfPreferences.load(from: fresh).order == ["serien"])
    }

    @Test("If nothing arrives, the old version stays")
    func migrationKeepsOldWhenWriteFails() {
        // **The on-device finding of 2026-08-16 as a check**: on the Apple TV a store was
        // silently swallowed. Whoever cleaned up here without looking would take the viewer's
        // arrangement away and write it nowhere.
        let legacy = InMemoryStore()
        try? legacy.set("filme;resume", for: "shelves.order")

        #expect(ShelfPreferences.adopt(from: legacy, in: DeafStore()) == false)
        #expect((try? legacy.value(for: "shelves.order")) == "filme;resume")
    }
}

/// **The order of the chosen channels** (AP46/AP32, 2026-09-25) — until then only that
/// of choosing.
@Suite("Channel shelf · order")
struct ChannelOrderingTests {

    @Test("A channel moves one place, and the order survives saving")
    func moves() {
        var preferences = ShelfPreferences(liveChannel: ["a", "b", "c"])
        preferences.moveChannel("c", up: true)
        #expect(preferences.liveChannel == ["a", "c", "b"])
        preferences.moveChannel("a", up: false)
        #expect(preferences.liveChannel == ["c", "a", "b"])

        let store = InMemoryStore()
        preferences.save(to: store)
        #expect(ShelfPreferences.load(from: store).liveChannel == ["c", "a", "b"])
    }

    @Test("Nothing happens at the edge or for unknowns")
    func marginStays() {
        var preferences = ShelfPreferences(liveChannel: ["a", "b"])
        preferences.moveChannel("a", up: true)
        preferences.moveChannel("b", up: false)
        preferences.moveChannel("x", up: true)
        #expect(preferences.liveChannel == ["a", "b"])
    }
}

/// **The live shelf choice stores names** (decision 21, 2026-09-26). The TV had stored
/// channel identifiers until then, the phone names — in the same field.
@Suite("Channel shelf · names instead of identifiers")
struct ChannelNamesTests {

    private func channel(_ id: String, _ name: String) -> Channel {
        Channel(id: id, name: name, streamURL: URL(fileURLWithPath: "/x"), playlistID: "l1")
    }

    private var catalog: [Channel] {
        [
            channel("101", "DE: Das Nordlicht HD"), channel("102", "DE: Das Nordlicht SD"),
            channel("7", "ZINNE"),
        ]
    }

    @Test("An old choice of identifiers becomes names once, unresolvable ones drop out")
    func identifiersBecomeNames() {
        let store = InMemoryStore()
        ShelfOrder(liveChannel: ["7", "weg", "101", "102"]).write(in: store)

        let read = ShelfPreferences.loadNamed(from: store, channels: catalog)

        #expect(read.liveChannel == [channel("7", "ZINNE").channelName, catalog[0].channelName])
        #expect(ShelfOrder.read(from: store).liveChannel == read.liveChannel, "saved")
        #expect(ShelfOrder.read(from: store).liveChannelsNamed)
    }

    /// **Once and not at every read.** If the list is silent later, the choice stays —
    /// otherwise a chosen channel would vanish at the first outage.
    @Test("A translated choice survives a list without its channels")
    func onlyOnce() {
        let store = InMemoryStore()
        ShelfOrder(liveChannel: ["7"]).write(in: store)
        _ = ShelfPreferences.loadNamed(from: store, channels: catalog)

        let later = ShelfPreferences.loadNamed(
            from: store, channels: [channel("9", "Avena")])

        #expect(later.liveChannel == ["ZINNE"])
    }

    @Test("Without a channel list nothing is translated and nothing discarded")
    func withoutListNothing() {
        let store = InMemoryStore()
        ShelfOrder(liveChannel: ["7", "101"]).write(in: store)

        let read = ShelfPreferences.loadNamed(from: store, channels: [])

        #expect(read.liveChannel == ["7", "101"])
        #expect(!ShelfOrder.read(from: store).liveChannelsNamed)
    }

    /// **What the phone writes survives the translation unchanged** — they are names, and
    /// the phone does not set the mark.
    @Test("Names from the phone stay as they are")
    func namesFromPhoneStay() {
        let store = InMemoryStore()
        let name = catalog[0].channelName
        ShelfOrder(liveChannel: [name, "ZINNE"]).write(in: store)

        #expect(ShelfPreferences.loadNamed(from: store, channels: catalog).liveChannel == [name, "ZINNE"])
    }

    @Test("The name is the same as on the phone: without prefix and without tag")
    func nameAsOnPhone() {
        #expect(catalog[0].channelName == ChannelDisplayName("DE: Das Nordlicht HD").name)
        #expect(catalog[0].channelName == catalog[1].channelName)
        #expect(ChannelDisplayName("DE: Das Nordlicht HD").tag == "HD")
    }
}

/// A store that accepts every write and keeps nothing.
///
/// **That is exactly what Application Support did on the Apple TV** (2026-08-16):
/// `write` failed, the `try?` in front of it swallowed it, and on reading nothing was
/// there.
private struct DeafStore: KeyValueStore {
    func set(_ value: String, for key: String) throws {}
    func value(for key: String) throws -> String { throw SecureStore.Failure.notFound }
    func remove(_ key: String) throws {}
}
