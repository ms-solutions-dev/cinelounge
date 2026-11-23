import Core
import Foundation
import Testing

@testable import PlaylistKit

/// Tests ``StateSource`` — **the wrapper that books progress into the position ledger** (AP42 ·
/// row 2, 2026-09-21).
///
/// Two kinds of tests stand here, and the second is the one that gets forgotten: that the
/// wrapper **leaves everything else unchanged**. A wrapper that inherits a default of the contract
/// answers *for* the source instead of asking it — `trailer(for:)` would give `nil` over an
/// existing trailer, `collections()` an empty list over a full shelf. That is
/// the finding of 2026-08-13. ("the stream comes from the source") in its nastiest form: there
/// a default cut one wire, here it cut all of them at once.
@Suite("State source")
struct StateSourceTests {

    // MARK: - A double that records every query

    final class TestDouble: ContentSource, @unchecked Sendable {

        let displayName = "Doppel"
        nonisolated let canStartAtOffset = false
        nonisolated let tracksStateItself: Bool

        /// Which contract rows were touched — the core of these tests.
        private(set) var asked: Set<String> = []
        private(set) var reported: [String] = []

        init(tracksStateItself: Bool = false) {
            self.tracksStateItself = tracksStateItself
        }

        private func memorize(_ was: String) { asked.insert(was) }

        func libraries() async throws -> [Library] {
            memorize("libraries")
            return [Library(id: "l1", name: "Filme", kind: .movies)]
        }
        func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            memorize("items")
            return [title("film:42", "Stille")]
        }
        func itemCount(in library: Library.ID, filter: ItemFilter) async throws -> Int? {
            memorize("itemCount")
            return 7
        }
        func item(id: String) async throws -> MediaItem {
            memorize("item")
            return title(id, "Stille")
        }
        func children(of itemID: String) async throws -> [MediaItem] {
            memorize("children")
            return [title("film:43", "Folge")]
        }
        func resumable(limit: Int) async throws -> [MediaItem] {
            memorize("resumable")
            return [title("film:99", "Von der Quelle")]
        }
        func collections() async throws -> [MediaItem] {
            memorize("collections")
            return [title("sammlung:1", "Reihe")]
        }
        func segments(for itemID: String) async throws -> [MediaSegment] {
            memorize("segments")
            return []
        }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            memorize("streamURL")
            return URL(string: "http://s/1.mkv")!
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {
            memorize("report")
            reported.append(itemID)
        }
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws { memorize("setPlayed") }
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {
            memorize("setFavorite")
        }
        func favorites() async throws -> [MediaItem] {
            memorize("favorites")
            return [title("film:77", "Von der Quelle")]
        }
        func trailer(for itemID: String) async throws -> MediaItem? {
            memorize("trailer")
            return title("trailer:1", "Vorschau")
        }
        func nextEpisode(after itemID: String) async throws -> MediaItem? {
            memorize("nextEpisode")
            return title("film:44", "Nächste")
        }
        func similarItem(to itemID: String) async throws -> MediaItem? {
            memorize("similarItem")
            return title("film:45", "Ähnlich")
        }
        func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] {
            memorize("similarItems")
            return [title("film:46", "Ähnlich")]
        }
        func episodes(of seriesID: String) async throws -> [MediaItem] {
            memorize("episodes")
            return [title("film:47", "Folge")]
        }
        func trickplay(for itemID: String) async throws -> Trickplay? {
            memorize("trickplay")
            return nil
        }
        func beginSession(for itemID: String) async throws { memorize("beginSession") }
        func endSession(for itemID: String, at position: TimeInterval) async throws {
            memorize("endSession")
        }
        nonisolated func imageURL(
            itemID: String, kind: ImageKind, width: Int, tag: String?
        ) -> URL? {
            URL(string: "http://bild/\(itemID)")
        }
        func listChanges() async -> AsyncStream<Void> {
            memorize("listChanges")
            return AsyncStream { $0.finish() }
        }
        func refreshAfterPlayback(ids: [String]) async { memorize("refresh") }

        private func title(_ id: String, _ name: String) -> MediaItem {
            MediaItem(id: id, kind: .movie, title: name, runtime: 5400)
        }
    }

    // MARK: - Buchen

    @Test("A reported position lands in the state ledger")
    func slotIsBooked() async throws {
        let ledger = InMemoryStore()
        let wrapper = StateSource(TestDouble(), ledger: ledger)

        try await wrapper.report(
            progress: PlaybackProgress(position: 600, duration: 5400, isWatched: false),
            for: "film:42", isPaused: false)

        #expect(StillLedger.read(from: ledger).state.titlePositions["film:42"]?.location == 600)
    }

    /// **Booked and passed on anyway.** The source may then
    /// discard its cache or keep a session.
    @Test("The source still gets the report")
    func sourceLearnsItToo() async throws {
        let double = TestDouble()
        let wrapper = StateSource(double, ledger: InMemoryStore())

        try await wrapper.report(
            progress: PlaybackProgress(position: 600, duration: 5400, isWatched: false),
            for: "film:42", isPaused: false)

        #expect(double.reported == ["film:42"])
    }

    @Test("The remembered state appears in fresh titles")
    func stateIsInTheTitles() async throws {
        let ledger = InMemoryStore()
        let wrapper = StateSource(TestDouble(), ledger: ledger)

        try await wrapper.report(
            progress: PlaybackProgress(position: 600, duration: 5400, isWatched: false),
            for: "film:42", isPaused: false)

        let title = try await wrapper.items(in: "l1", filter: .default)
        #expect(title.first?.progress?.position == 600)
    }

    @Test("Started titles come from the ledger and not from the source")
    func startedFromTheLedger() async throws {
        let ledger = InMemoryStore()
        let double = TestDouble()
        let wrapper = StateSource(double, ledger: ledger)

        try await wrapper.report(
            progress: PlaybackProgress(position: 600, duration: 5400, isWatched: false),
            for: "film:42", isPaused: false)
        _ = try await wrapper.items(in: "l1", filter: .default)

        let pending = try await wrapper.resumable(limit: 12)
        #expect(pending.map(\.id) == ["film:42"])
        #expect(!double.asked.contains("resumable"))
    }

    @Test("Marked titles come from the ledger")
    func favoritesFromTheLedger() async throws {
        let ledger = InMemoryStore()
        let wrapper = StateSource(TestDouble(), ledger: ledger)

        try await wrapper.setFavorite(true, for: "film:42")

        #expect(try await wrapper.favorites().map(\.id) == ["film:42"])
    }

    /// **The promise of AP42, through the wrapper.**
    @Test("Two profiles, two states")
    func twoProfilesTwoStates() async throws {
        let ledger = InMemoryStore()
        let wrapper = StateSource(TestDouble(), ledger: ledger)

        try await ProfilePointer.als("eltern") {
            try await wrapper.report(
                progress: PlaybackProgress(position: 600, duration: 5400, isWatched: false),
                for: "film:42", isPaused: false)
        }

        let forChild = try await ProfilePointer.als("kind") {
            try await wrapper.resumable(limit: 12)
        }
        let forParents = try await ProfilePointer.als("eltern") {
            try await wrapper.resumable(limit: 12)
        }

        #expect(forChild.isEmpty)
        #expect(forParents.map(\.id) == ["film:42"])
    }

    // MARK: - Durchreichen

    /// **The core of this file.** An inherited default answered for the source instead of
    /// asking it — and silently so.
    @Test("Every line of the contract reaches the source")
    func everyRowReachesTheSource() async throws {
        let double = TestDouble()
        let wrapper = StateSource(double, ledger: InMemoryStore())

        _ = try await wrapper.libraries()
        _ = try await wrapper.items(in: "l1", filter: .default)
        _ = try await wrapper.itemCount(in: "l1", filter: .default)
        _ = try await wrapper.item(id: "film:42")
        _ = try await wrapper.children(of: "film:42")
        _ = try await wrapper.collections()
        _ = try await wrapper.segments(for: "film:42")
        _ = try await wrapper.streamURL(
            for: "film:42",
            decision: PlaybackDecision(engine: .native, delivery: .remuxInApp, reason: .nativeContainer))
        _ = try await wrapper.trailer(for: "film:42")
        _ = try await wrapper.nextEpisode(after: "film:42")
        _ = try await wrapper.similarItem(to: "film:42")
        _ = try await wrapper.similarItems(to: "film:42", limit: 5)
        _ = try await wrapper.episodes(of: "serie:1")
        _ = try await wrapper.trickplay(for: "film:42")
        try await wrapper.beginSession(for: "film:42")
        try await wrapper.endSession(for: "film:42", at: 600)
        _ = await wrapper.listChanges()
        await wrapper.refreshAfterPlayback(ids: ["film:42"])

        #expect(
            double.asked == [
                "libraries", "items", "itemCount", "item", "children", "collections", "segments",
                "streamURL", "trailer", "nextEpisode", "similarItem", "similarItems", "episodes",
                "trickplay", "beginSession", "endSession", "listChanges", "refresh",
            ])
    }

    @Test("Name, start point and image address come from the source")
    func nonisolatedLookups() {
        let wrapper = StateSource(TestDouble(), ledger: InMemoryStore())

        #expect(wrapper.displayName == "Doppel")
        #expect(wrapper.canStartAtOffset == false)
        #expect(
            wrapper.imageURL(itemID: "film:42", kind: .primary, width: 300, tag: nil)
                == URL(string: "http://bild/film:42"))
    }

    // MARK: - Whoever keeps its own state

    /// **Jellyfin and the portals pass through.** What has been watched, the server knows; whoever kept it
    /// here on the side would have two truths as soon as someone watches something on the phone.
    @Test("Over a source with its own state the wrapper books nothing")
    func ownStateIsNotBooked() async throws {
        let ledger = InMemoryStore()
        let wrapper = StateSource(TestDouble(tracksStateItself: true), ledger: ledger)

        try await wrapper.report(
            progress: PlaybackProgress(position: 600, duration: 5400, isWatched: false),
            for: "film:42", isPaused: false)

        #expect(StillLedger.read(from: ledger) == StillLedger())
    }

    @Test("Over a source with its own state its Continue Watching applies")
    func ownStateStaysItsOwn() async throws {
        let double = TestDouble(tracksStateItself: true)
        let wrapper = StateSource(double, ledger: InMemoryStore())

        #expect(try await wrapper.resumable(limit: 12).map(\.id) == ["film:99"])
        #expect(try await wrapper.favorites().map(\.id) == ["film:77"])
    }

    /// **The wrapper is harmless about itself**, because it keeps its own state.
    /// Whoever wraps twice still books once.
    @Test("Wrapped twice books once")
    func wrappedTwiceBooksOnce() async throws {
        let ledger = InMemoryStore()
        let wrapper = StateSource(StateSource(TestDouble(), ledger: ledger), ledger: ledger)

        try await wrapper.report(
            progress: PlaybackProgress(position: 600, duration: 5400, isWatched: false),
            for: "film:42", isPaused: false)

        #expect(StillLedger.read(from: ledger).journal.count == 1)
    }
}
