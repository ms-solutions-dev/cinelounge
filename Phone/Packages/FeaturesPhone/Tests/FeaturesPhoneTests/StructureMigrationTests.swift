import Core
import Foundation
import Playback
import Testing

@testable import FeaturesPhone

/// **What was moved from user defaults into the file on 2026-09-21** (AP40).
///
/// Four small settings, four takeovers, and each may take effect **exactly once**.
/// The rule is the same everywhere as for the age limit: first write, then
/// read back, then clear — and never overwrite anything that is already there.
@Suite("The migration of the small settings")
struct StructureMigrationTests {

    private static func oldStore() -> UserDefaults {
        UserDefaults(suiteName: "probe.\(UUID().uuidString)") ?? .standard
    }

    /// **The most interesting of the four**, because here a separator is dissolved: The
    /// old store carried `fresh:from` in one word. What once stands in the file has two
    /// fields — otherwise the new form would drag along the trouble of the old one.
    @Test("`neu:ab` becomes two fields")
    func sortingMigrates() {
        let legacy = Self.oldStore()
        let movies = Catalog.Identifier(.jellyfin, .movies, "filme")
        let allSeries = Catalog.Identifier(.jellyfin, .allSeries, "serien")
        legacy.set(
            [movies.rawValue: "neu:ab", allSeries.rawValue: "bewertung:zu"],
            forKey: SortMemory.key)
        let file = InMemoryStore()

        #expect(SortMemory.adopt(from: legacy, in: file))

        let memory = SortMemory(store: file)
        #expect(memory.last(zu: movies)?.sorting == .fresh)
        #expect(memory.last(zu: movies)?.ascending == true)
        #expect(memory.last(zu: allSeries)?.sorting == .rating)
        #expect(memory.last(zu: allSeries)?.ascending == false)
        #expect(legacy.dictionary(forKey: SortMemory.key) == nil)
    }

    /// **An unreadable row drops out and does not take the others with it.** It would
    /// yield `nil` anyway; taking it along would mean carrying it forever.
    @Test("An unreadable row does not migrate")
    func unreadableRowDropsOut() {
        let legacy = Self.oldStore()
        let movies = Catalog.Identifier(.jellyfin, .movies, "filme")
        legacy.set(
            [movies.rawValue: "neu:ab", "broken": "noColon"],
            forKey: SortMemory.key)
        let file = InMemoryStore()

        SortMemory.adopt(from: legacy, in: file)

        let board = RecordSheet.read(
            [String: SortStore.ContentEntryRecord].self, under: SortStore.key, from: file)
        #expect(board?.count == 1)
        #expect(board?["filme"] == .init(kind: .added, ascending: true))
    }

    /// **The second stage (AP58 R6):** The phone board moves into the shared board,
    /// under the ID that the TV also uses — and is cleared afterwards.
    @Test("The phone board becomes the shared board")
    func phoneBoardMigrates() {
        let file = InMemoryStore()
        RecordSheet.write(
            [
                "medienserver:movies:a1": SortMemory.ContentEntryRecord(
                    sorting: "bewertung", ascending: true),
                "anbieter:movies:liste|vod": SortMemory.ContentEntryRecord(
                    sorting: "titel", ascending: false),
            ], under: SortMemory.key, in: file)

        #expect(SortMemory.adopt(from: Self.oldStore(), in: file))

        let shared = SortStore(store: file)
        #expect(shared.read(area: "a1") == .init(kind: .rating, ascending: true))
        #expect(shared.read(area: "liste|vod") == .init(kind: .title, ascending: false))
        #expect((try? file.value(for: SortMemory.key)) == nil)
        #expect(
            SortMemory(store: file).last(zu: .init(.jellyfin, .movies, "a1"))
                == OrderChoice(sorting: .rating, ascending: true, explicit: true))
    }

    /// **Since 2026-09-26 ``Core/SportReminderListStore`` fetches the note itself** (B5) —
    /// from user defaults as well as from the file store, into the profile's compartment.
    @Test("The watchlist moves from the standard defaults into the profile")
    @MainActor
    func watchlistMigrates() {
        let legacy = Self.oldStore()
        legacy.set(["spiel-2", "spiel-1"], forKey: "live.sportMarks")
        let file = InMemoryStore()

        let watchlist = SportReminderListStore(
            store: file, profile: { "p" }, keychain: nil, old: legacy
        ).read()

        #expect(watchlist.matches == ["spiel-1", "spiel-2"])
        #expect(
            RecordSheet.read(
                SportReminderList.self, under: SportReminderList.key + ".p", from: file)
                == watchlist)
        #expect(legacy.stringArray(forKey: "live.sportMarks") == nil)
    }

    @Test("The image layout per format migrates")
    @MainActor
    func imagePositionMigrates() {
        let legacy = Self.oldStore()
        legacy.set(["2.4": ImageLayout.fillsScreen.rawValue], forKey: PictureFill.key)
        let file = InMemoryStore()

        #expect(PictureFill.adopt(from: legacy, in: file))

        #expect(PictureFill(store: file).state(forItem: 2.39) == .fillsScreen)
        #expect(legacy.dictionary(forKey: PictureFill.key) == nil)
    }

    /// **None of the four overwrites what is already in the file.** The second start
    /// must not undo what was set after the first.
    @Test("If the file already holds something, nothing happens")
    @MainActor
    func neverOverwrite() {
        let legacy = Self.oldStore()
        legacy.set(["live"], forKey: TabSelection.key)
        let file = InMemoryStore()
        RecordSheet.write(["portale"], under: TabSelection.key, in: file)

        #expect(TabSelection.adopt(from: legacy, in: file) == false)

        #expect(TabSelection.stored(store: file) == ["portale"])
        // **And the old store stays standing**: Only what was really
        // taken over is cleared.
        #expect(legacy.stringArray(forKey: TabSelection.key) == ["live"])
    }
}
