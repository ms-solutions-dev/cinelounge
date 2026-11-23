import Foundation
import Testing

@testable import Core

/// A bookmark list for club, competition and single match — and a store per profile
/// (decision 27, B5).
@Suite("Sport watchlist")
struct SportWatchlistTests {

    private static func match(
        _ id: String, _ title: String, competition: String? = nil
    ) -> SportEvent {
        SportEvent(
            id: id, kind: .football, competition: competition, title: title,
            start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 7_000),
            epgIDs: ["epg"])
    }

    private static func freshDefaults() -> UserDefaults {
        let name = "sportmerkzettel-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    // MARK: - Was gemerkt ist

    @Test("Following a club bookmarks all its matches, in any spelling")
    func followClub() {
        var watchlist = SportReminderList()
        watchlist.toggleTeam("Demirbahçe")
        #expect(watchlist.marks(Self.match("a", "DEMIRBAHCE - Kalesaray")))
        #expect(watchlist.follows(Self.match("a", "DEMIRBAHCE - Kalesaray")))
        #expect(!watchlist.marks(Self.match("b", "Yeşiltaş - Dalgaspor")))
    }

    @Test("Following a competition bookmarks every match in it")
    func followCompetition() {
        var watchlist = SportReminderList()
        watchlist.toggleCompetition("Göl Ligi")
        #expect(watchlist.marks(Self.match("a", "X - Y", competition: "GOL LIGI")))
        #expect(!watchlist.marks(Self.match("b", "X - Y", competition: "Talliga")))
    }

    @Test("Bookmarking a single match bookmarks only that one")
    func bookmarkGame() {
        var watchlist = SportReminderList()
        watchlist.toggleMatch("a")
        #expect(watchlist.marks(Self.match("a", "X - Y")))
        #expect(watchlist.isBookmarked(Self.match("a", "X - Y")))
        #expect(!watchlist.follows(Self.match("a", "X - Y")))
        #expect(!watchlist.marks(Self.match("b", "X - Y")))
        watchlist.toggleMatch("a")
        #expect(!watchlist.marks(Self.match("a", "X - Y")))
        #expect(watchlist.isEmpty)
    }

    @Test("Cleanup takes only past matches, never clubs — and never against an empty schedule")
    func cleanUp() {
        var watchlist = SportReminderList()
        watchlist.toggleTeam("Demirbahçe")
        watchlist.toggleMatch("gestern")
        watchlist.toggleMatch("heute")
        let empty = watchlist.cleanUp(to: [])
        #expect(!empty)
        #expect(watchlist.matches == ["gestern", "heute"])
        let cleaned = watchlist.cleanUp(to: ["heute", "morgen"])
        #expect(cleaned)
        #expect(watchlist.matches == ["heute"])
        #expect(watchlist.hasTeam("demirbahce"))
    }

    // MARK: - Ablage

    @Test("The list is kept per profile and does not fall back to the device")
    func perProfile() {
        let file = InMemoryStore()
        let parents = SportReminderListStore(
            store: file, profile: { "eltern" }, keychain: nil, old: nil)
        let kind = SportReminderListStore(
            store: file, profile: { "kind" }, keychain: nil, old: nil)
        var watchlist = SportReminderList()
        watchlist.toggleTeam("Bergland")
        watchlist.toggleMatch("a")
        parents.write(watchlist)

        #expect(parents.read() == watchlist)
        #expect(kind.read().isEmpty)
        #expect((try? file.value(for: SportReminderList.key + ".eltern")) != nil)
    }

    @Test("An empty list leaves no entry")
    func emptyWithoutEntry() {
        let file = InMemoryStore()
        let store = SportReminderListStore(
            store: file, profile: { "p" }, keychain: nil, old: nil)
        var watchlist = SportReminderList()
        watchlist.toggleMatch("a")
        store.write(watchlist)
        watchlist.toggleMatch("a")
        store.write(watchlist)
        #expect((try? file.value(for: SportReminderList.key + ".p")) == nil)
    }

    /// **Both old lists migrate once, and afterwards the old locations are empty**
    /// (decision 2: clean cut).
    @Test("The lists of both devices move together into the profile")
    func takeover() throws {
        let file = InMemoryStore()
        let keychain = InMemoryStore()
        let old = Self.freshDefaults()
        try keychain.set(
            #"{"competitions":["gol ligi"],"labels":{"gol ligi":"Göl Ligi","bergland":"Bergland"},"teams":["bergland"]}"#,
            for: SportReminderList.legacyTV)
        RecordSheet.write(["spiel-1"], under: SportReminderList.legacyPhone, in: file)
        old.set(["spiel-0"], forKey: SportReminderList.legacyPhone)

        let store = SportReminderListStore(
            store: file, profile: { "p" }, keychain: keychain, old: old)
        let watchlist = store.read()

        #expect(watchlist.hasTeam("Bergland"))
        #expect(watchlist.hasCompetition("Göl Ligi"))
        #expect(watchlist.labels["bergland"] == "Bergland")
        #expect(watchlist.matches == ["spiel-0", "spiel-1"])
        #expect((try? keychain.value(for: SportReminderList.legacyTV)) == nil)
        #expect((try? file.value(for: SportReminderList.legacyPhone)) == nil)
        #expect(old.stringArray(forKey: SportReminderList.legacyPhone) == nil)
        #expect(
            RecordSheet.read(SportReminderList.self, under: SportReminderList.key + ".p", from: file)
                == watchlist)
    }

    @Test("If the profile already holds a list, the old location stays untouched")
    func noTakeoverOverCatalog() throws {
        let file = InMemoryStore()
        let keychain = InMemoryStore()
        try keychain.set(#"{"teams":["alt"]}"#, for: SportReminderList.legacyTV)
        var own = SportReminderList()
        own.toggleMatch("neu")
        RecordSheet.write(own, under: SportReminderList.key + ".p", in: file)

        let store = SportReminderListStore(
            store: file, profile: { "p" }, keychain: keychain, old: nil)
        #expect(store.read() == own)
        #expect((try? keychain.value(for: SportReminderList.legacyTV)) != nil)
    }
}

/// **The TV's list lives in the Keychain** (Live check, finding 9,
/// 2026-09-27): the file store falls back to `Caches` there, and the system clears that.
@Suite("Sport watchlist: the TV's store")
struct SportWatchlistTVTests {

    @Test("The TV puts it in the Keychain, not in the file store")
    func keychain() {
        #expect(SportReminderListStore.tv(profile: { nil }).store is SecureStore)
    }

    /// What lay in the file store since 2026-09-26 comes over once — and is cleared there
    /// only after a successful read-back (decision 2).
    @Test("A list from the file store moves once into the durable store")
    func migrationFromFileStore() {
        let file = InMemoryStore()
        let duration = InMemoryStore()
        var watchlist = SportReminderList()
        watchlist.toggleTeam("Bergland")
        RecordSheet.write(watchlist, under: SportReminderList.key + ".p", in: file)

        let store = SportReminderListStore(
            store: duration, profile: { "p" }, keychain: nil, old: nil, previous: file)
        #expect(store.read() == watchlist)
        #expect((try? file.value(for: SportReminderList.key + ".p")) == nil)
        #expect(
            RecordSheet.read(
                SportReminderList.self, under: SportReminderList.key + ".p", from: duration)
                == watchlist)
    }

    /// Only its own compartment: a parent profile's list stays in the file store when the child
    /// profile reads (finding 4).
    @Test("The move takes only the slot of the reading profile")
    func migrationOnlyOwnSlot() {
        let file = InMemoryStore()
        var parents = SportReminderList()
        parents.toggleMatch("a")
        RecordSheet.write(parents, under: SportReminderList.key + ".eltern", in: file)
        let kind = SportReminderListStore(
            store: InMemoryStore(), profile: { "kind" }, keychain: nil, old: nil,
            previous: file)
        #expect(kind.read().isEmpty)
        #expect((try? file.value(for: SportReminderList.key + ".eltern")) != nil)
    }

    struct FailingStore: KeyValueStore {
        struct TestError: Error {}
        func set(_ value: String, for key: String) throws { throw TestError() }
        func value(for key: String) throws -> String { throw TestError() }
        func remove(_ key: String) throws {}
    }

    @Test("If the durable store does not write, the list stays in the file store")
    func migrationWithoutReadBack() {
        let file = InMemoryStore()
        var watchlist = SportReminderList()
        watchlist.toggleTeam("Bergland")
        RecordSheet.write(watchlist, under: SportReminderList.key + ".p", in: file)
        let store = SportReminderListStore(
            store: FailingStore(), profile: { "p" }, keychain: nil, old: nil, previous: file)
        #expect(store.read() == watchlist)
        #expect((try? file.value(for: SportReminderList.key + ".p")) != nil)
    }
}
