import Core
import Foundation
import Testing

@testable import Features

/// **The Home screen on cold start** (AP70, 2026-10-11). Diagnosis F-017: 67 s until the
/// first shelf — three builds at once, portal folders one after another into the timeout, and
/// nothing that could have been shown until then.
@MainActor
struct HomeColdStartTests {

    /// Counts how often "Continue Watching" is fetched — and can take arbitrarily long doing so.
    final class CountingSource: ContentSource, @unchecked Sendable {
        let lock = NSLock()
        private(set) var fetches = 0
        var delay: Duration = .zero
        nonisolated var displayName: String { "Zähler" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }
        nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? {
            nil
        }
        func libraries() async throws -> [Core.Library] { [] }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { throw URLError(.badURL) }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] {
            lock.withLock { fetches += 1 }
            try await Task.sleep(for: delay)
            return ["a1", "b2", "c3"].map { MediaItem(id: $0, kind: .movie, title: $0) }
        }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw URLError(.badURL)
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func removeFromContinueWatching(_ itemID: String) async throws {}
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    @Test("Three builds at once are one build")
    func oneBuild() async throws {
        await ProfilePointer.als(nil) {
            let source = CountingSource()
            source.delay = .milliseconds(50)
            let store = InMemoryStore()
            let model = HomeModel(
                source: source, store: store, shelfStore: store, snapshotStore: InMemoryStore())
            async let one: Void = model.load()
            async let two: Void = model.fresh()
            async let three: Void = model.load(force: true)
            _ = await (one, two, three)
            // The first one carries, the others wait; `force` then buys exactly one follow-up run.
            #expect(source.fetches <= 2, "\(source.fetches) fetches")
            guard case .ready = model.state else {
                Issue.record("Home not ready: \(model.state)")
                return
            }
        }
    }

    @Test("The cold start shows the snapshot before the source answers")
    func snapshot() async throws {
        try await ProfilePointer.als(nil) {
            let store = InMemoryStore()
            let snapshots = InMemoryStore()
            // First run: builds and remembers.
            let first = HomeModel(
                source: CountingSource(), store: store, shelfStore: store,
                snapshotStore: snapshots)
            await first.load()
            let remembered = try #require(HomeSnapshot.read(from: snapshots, forItem: nil))
            #expect(remembered.shelves.contains { $0.id == ShelfPreferences.resumeID })

            // Second run: the source takes forever — the Home screen stands immediately anyway.
            let slow = CountingSource()
            slow.delay = .seconds(30)
            let second = HomeModel(
                source: slow, store: store, shelfStore: store, snapshotStore: snapshots)
            let setup = Task { await second.load() }
            // Under load this may take longer — what is waited for is the state, not the clock.
            for _ in 0..<250 {
                if case .ready = second.state { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard case .ready(_, let shelves) = second.state else {
                Issue.record("No snapshot shown: \(second.state)")
                setup.cancel()
                return
            }
            #expect(
                shelves.first { $0.id == ShelfPreferences.resumeID }?.items.map(\.id) == ["a1", "b2", "c3"])
            setup.cancel()
        }
    }

    /// **Disabled portals must not appear anywhere** (product decision, 2026-10-11) — not even
    /// for the two seconds that the snapshot stands before the real build.
    @Test("Portal tiles do not come from the image")
    func noPortalsInTheImage() async throws {
        await ProfilePointer.als(nil) {
            let store = InMemoryStore()
            let snapshots = InMemoryStore()
            let shelf = HomeModel.Shelf(
                id: ShelfPreferences.resumeID, titleKey: "home.continueWatching",
                items: [
                    MediaItem(id: "a1", kind: .movie, title: "a1"),
                    MediaItem(id: "flatone|k|/x", kind: .movie, title: "verboten"),
                ],
                usesWideCards: false)
            HomeSnapshot(heroes: [], shelves: [shelf], state: Date())
                .write(in: snapshots, forItem: nil)
            let slow = CountingSource()
            slow.delay = .seconds(30)
            let model = HomeModel(
                source: slow, store: store, shelfStore: store, snapshotStore: snapshots)
            let setup = Task { await model.load() }
            for _ in 0..<250 {
                if case .ready = model.state { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            defer { setup.cancel() }
            guard case .ready(_, let shelves) = model.state else {
                Issue.record("No snapshot shown: \(model.state)")
                return
            }
            #expect(shelves.first { $0.id == ShelfPreferences.resumeID }?.items.map(\.id) == ["a1"])
        }
    }

    @Test("Without a snapshot it stays with the loading spinner")
    func withoutSnapshot() async throws {
        try await ProfilePointer.als(nil) {
            let slow = CountingSource()
            slow.delay = .seconds(30)
            let model = HomeModel(
                source: slow, store: InMemoryStore(), shelfStore: InMemoryStore(),
                snapshotStore: InMemoryStore())
            let setup = Task { await model.load() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.state == .loading)
            setup.cancel()
        }
    }

    @Test("Removed from Continue Watching: the row for the Top Shelf is the same as on screen")
    func remove() async throws {
        await ProfilePointer.als(nil) {
            let store = InMemoryStore()
            let model = HomeModel(
                source: CountingSource(), store: store, shelfStore: store,
                snapshotStore: InMemoryStore())
            await model.load()
            #expect(model.continueWatchingInState.map(\.id) == ["a1", "b2", "c3"])
            await model.removeFromContinueWatching(MediaItem(id: "b2", kind: .movie, title: "b2"))
            #expect(model.continueWatchingInState.map(\.id) == ["a1", "c3"])
        }
    }
}
