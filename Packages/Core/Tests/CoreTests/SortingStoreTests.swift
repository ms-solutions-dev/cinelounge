import Foundation
import Testing

@testable import Core

/// **One store for sort orders, two old formats, two readings of `from`** (AP58 R6, St7).
@Suite("Sort store and sort rule")
struct SortingStoreTests {

    /// **On the TV `from` meant descending.**
    @Test("An old TV row carries over with its reading and is cleared")
    func tvLine() {
        let keychainStore = InMemoryStore()
        let file = InMemoryStore()
        try? keychainStore.set("rating:ab", for: "library.sort.f1")
        try? keychainStore.set("title:auf", for: "library.sort.s1")
        let store = SortStore(store: file, keychain: keychainStore)

        #expect(store.read(area: "f1") == .init(kind: .rating, ascending: false))
        #expect(store.read(area: "s1") == .init(kind: .title, ascending: true))
        #expect((try? keychainStore.value(for: "library.sort.f1")) == nil)
        #expect(SortStore(store: file).read(area: "f1")?.ascending == false)
    }

    /// **In the phone board the direction is spelled out** — no abbreviation to interpret.
    @Test("The phone board carries over under the library identifier")
    func phoneBoard() throws {
        let file = InMemoryStore()
        try file.set(
            #"{"medienserver:movies:f1":{"sortierung":"neu","aufsteigend":true}}"#,
            for: SortStore.phoneBoard)
        #expect(SortStore(store: file).adoptsPhoneBoard())
        #expect(
            SortStore(store: file).read(area: "f1")
                == .init(kind: .added, ascending: true))
        #expect((try? file.value(for: SortStore.phoneBoard)) == nil)
    }

    @Test("The default is deleted, not written")
    func defaultDeletes() {
        let file = InMemoryStore()
        let store = SortStore(store: file)
        store.memorize(.init(kind: .title, ascending: false), area: "f1")
        store.memorize(nil, area: "f1")
        #expect(store.read(area: "f1") == nil)
        #expect((try? file.value(for: SortStore.key)) == nil)
    }

    @Test("Movie and series sections of a provider share one area per list")
    func area() {
        #expect(SortRule.area(forLibrary: "l1|vod|4711") == "l1|vod")
        #expect(SortRule.area(forLibrary: "l1|series|9") == "l1|series")
        #expect(SortRule.area(forLibrary: "l1|series") == "l1|series")
        #expect(SortRule.area(forLibrary: "a1b2") == "a1b2")
    }

    @Test("What the device offers is read: Recording and Added are equivalent")
    func readEquivalently() {
        let store = SortStore(store: InMemoryStore())
        store.memorize(.init(kind: .recording, ascending: true), area: "hv")
        #expect(
            store.read(area: "hv", isOffered: [.added, .title])
                == .init(kind: .added, ascending: true))
        #expect(store.read(area: "hv", isOffered: [.recording, .title])?.kind == .recording)
        store.memorize(.init(kind: .rating, ascending: false), area: "hv")
        #expect(store.read(area: "hv", isOffered: [.added, .title]) == nil)
    }

    @Test("Tap sequence: sort, reverse, default")
    func tapSequence() {
        let preset = SortChoice(kind: SortKind.title, ascending: true, explicit: false)
        let first = preset.next(
            pressOn: .rating, naturalAscending: \.naturalAscending, preset: preset)
        #expect(first == .init(kind: .rating, ascending: false, explicit: true))
        let second = first.next(
            pressOn: .rating, naturalAscending: \.naturalAscending, preset: preset)
        #expect(second.ascending)
        #expect(
            second.next(
                pressOn: .rating, naturalAscending: \.naturalAscending,
                preset: preset) == preset)
    }

    @Test("Series by year, without a year the sequence stays")
    func rows() {
        let title: [(String, Int?)] = [
            ("Lenno Varsk und der Moosturm", 2003), ("Lenno Varsk und der Spiegel", 1996),
            ("Lenno Varsk ohne Jahr", nil), ("Pakuro", 1974),
        ]
        let ordered = SortRule.seriesByYear(title, title: \.0, year: \.1).map(\.0)
        #expect(ordered.prefix(2) == ["Lenno Varsk und der Spiegel", "Lenno Varsk und der Moosturm"])
    }
}
