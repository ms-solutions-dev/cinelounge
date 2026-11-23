import Core
import Foundation
import Testing

@testable import Features

/// The portal shelves of the Home screen — **what is chosen is shown, and sorted
/// the same way as in the portal area** (2026-09-13).
///
/// Two findings from the same day: *"currently I have 2 selected, but not all of them are
/// shown on Home"* — and *"I set a sort order there, and it should carry over to Home
/// along with that sort order."* Both run through the same place,
/// ``HomeModel/portalFolderShelves(libraries:choice:)``, and a test over the whole
/// model proves both together: the choice lies **below** an entry point, and the
/// request carries the stored order.
@MainActor
struct PortalShelfTests {

    /// A source that reports a portal with one entry point and records every request.
    final class PortalContentSource: ContentSource, @unchecked Sendable {
        nonisolated var displayName: String { "Portal-Doppel" }
        nonisolated var canStartAtOffset: Bool { false }
        /// **A test double keeps its own state** — nobody should wrap it.
        nonisolated var tracksStateItself: Bool { true }

        private(set) var requestJoin: [(level: String, filter: ItemFilter)] = []

        nonisolated func imageURL(
            itemID: String, kind: ImageKind, width: Int, tag: String?
        )
            -> URL?
        { nil }

        func libraries() async throws -> [Core.Library] {
            [Core.Library(id: "animehub||/beliebt", name: "Beliebte Serien", kind: .portalLevel)]
        }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            requestJoin.append((library, filter))
            return [MediaItem(id: "animehub|s1|/serie/1", kind: .series, title: "Eine Serie")]
        }
        func item(id: String) async throws -> MediaItem { throw Missing.nothing }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw Missing.nothing
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }

        enum Missing: Error { case nothing }
    }

    /// **The level below the entry point** — only `/beliebt` is reported, `/beliebt/action`
    /// is chosen. Before 2026-09-13 it silently fell through.
    static let deepChoice = ShelfPreferences.PortalChoice(
        identifier: "animehub||/beliebt/action", name: "ANIMEHUB · Beliebte Serien · Action")

    /// **With a pinned profile** (AP58 R6): the Home screen reads the order per profile,
    /// and concurrent tests switch the shared pointer.
    @Test("A deeply chosen folder becomes a shelf — sorted as in the portal section")
    func deepChoiceWithSorting() async throws {
        try await ProfilePointer.als(nil) {
            let store = InMemoryStore()
            var preferences = ShelfPreferences()
            preferences.select(Self.deepChoice, on: true)
            preferences.save(to: store)
            // The same store that ``LibraryModel`` writes to on the sort button.
            LibraryModel.saveOrder(
                .init(sorting: .title, ascending: false, isExplicit: true),
                for: Core.Library(id: Self.deepChoice.identifier, name: "", kind: .portalLevel),
                to: store)

            let source = PortalContentSource()
            let model = HomeModel(source: source, store: store, shelfStore: store)
            await model.load()

            guard case .ready(_, let shelves) = model.state else {
                Issue.record("Home not ready: \(model.state)")
                return
            }
            let shelf = try #require(shelves.first { $0.id == Self.deepChoice.identifier })
            #expect(shelf.titleKey == Self.deepChoice.name)
            #expect(shelf.items.map(\.id) == ["animehub|s1|/serie/1"])

            let request = try #require(source.requestJoin.first { $0.level == Self.deepChoice.identifier })
            #expect(request.filter.sortBy == .title)
            #expect(request.filter.ascending == false)
        }
    }

    /// **Without a store, the portal's own order stays** — `.natural`, as
    /// when the level itself is first opened.
    /// **With a pinned profile** (AP58 R6): the Home screen reads the order per profile,
    /// and concurrent tests switch the shared pointer.
    @Test("Without a remembered sort order the shelf asks in the portal's order")
    func naturalWithoutStore() async throws {
        try await ProfilePointer.als(nil) {
            let store = InMemoryStore()
            var preferences = ShelfPreferences()
            preferences.select(Self.deepChoice, on: true)
            preferences.save(to: store)

            let source = PortalContentSource()
            await HomeModel(source: source, store: store, shelfStore: store).load()

            let request = try #require(source.requestJoin.first { $0.level == Self.deepChoice.identifier })
            #expect(request.filter.sortBy == .natural)
            #expect(request.filter.ascending == true)
        }
    }
}

/// The provider shelves of the Home screen — **sorted as in the "Movies & Series" area**
/// (2026-09-13: *"vod de serien paramount … is shown but not with the correct
/// sort order"*). The media server stays with the newest; a provider's section
/// carries the order someone chose there — and without a choice that of the area.
@MainActor
struct ProviderShelfTests {

    final class ProviderSource: ContentSource, @unchecked Sendable {
        nonisolated var displayName: String { "Anbieter-Doppel" }
        nonisolated var canStartAtOffset: Bool { false }
        /// **A test double keeps its own state** — nobody should wrap it.
        nonisolated var tracksStateItself: Bool { true }
        // **With a lock**, because the Home screen queries its libraries concurrently —
        // without it, one of two requests got lost on the first run.
        private let lock = NSLock()
        private var _requests: [(category: String, filter: ItemFilter)] = []
        var requestJoin: [(category: String, filter: ItemFilter)] {
            lock.withLock { _requests }
        }

        nonisolated func imageURL(
            itemID: String, kind: ImageKind, width: Int, tag: String?
        )
            -> URL?
        { nil }
        func libraries() async throws -> [Core.Library] {
            [
                Core.Library(id: "jf-filme", name: "Filme", kind: .movies),
                Core.Library(id: "liste|vod|7", name: "DE Kino", kind: .movies),
            ]
        }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            lock.withLock { _requests.append((library, filter)) }
            return [MediaItem(id: library + "-1", kind: .movie, title: "Ein Film")]
        }
        func item(id: String) async throws -> MediaItem { throw Missing.nothing }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw Missing.nothing
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
        enum Missing: Error { case nothing }
    }

    @Test("The provider category carries the remembered order, Jellyfin the newest")
    func rememberedOrder() async throws {
        let store = InMemoryStore()
        LibraryModel.saveOrder(
            .init(sorting: .rating, ascending: false, isExplicit: true),
            for: Core.Library(id: "liste|vod|7", name: "DE Kino", kind: .movies), to: store)

        let source = ProviderSource()
        await HomeModel(source: source, store: store, shelfStore: store).load()

        let category = try #require(source.requestJoin.first { $0.category == "liste|vod|7" })
        #expect(category.filter.sortBy == .rating)
        #expect(category.filter.ascending == false)
        let movies = try #require(source.requestJoin.first { $0.category == "jf-filme" })
        #expect(movies.filter.sortBy == .dateAdded)
        #expect(movies.filter.ascending == false)
    }

    @Test("Without a choice the category uses the section's default — the title")
    func sectionDefault() async throws {
        let source = ProviderSource()
        await HomeModel(source: source, store: InMemoryStore(), shelfStore: InMemoryStore()).load()
        let category = try #require(source.requestJoin.first { $0.category == "liste|vod|7" })
        #expect(category.filter.sortBy == .title)
        #expect(category.filter.ascending == true)
    }
}
