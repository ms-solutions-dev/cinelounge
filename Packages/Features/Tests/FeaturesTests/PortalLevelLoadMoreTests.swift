import Core
import Foundation
import ParentalControls
import Testing

@testable import Features

/// A portal level loads more on the TV — and asks the server for sorted results (AP60).
///
/// **The finding of 2026-09-30:** Serieshub → Collections → "Anime Japan auf Deutsch"
/// stated 900 entries and showed 24. The TV fetched only page 1 and then sorted
/// those 24 — so by rating a 6 from page 1 stood ahead of an 8 from page 3.
@Suite("Portal level: load more and ask sorted")
@MainActor
struct PortalLevelLoadMoreTests {

    /// Two pages, and what was asked.
    final class TwoSided: PageSource, @unchecked Sendable {
        var asked: [(next: String?, sortBy: ItemFilter.SortBy)] = []

        nonisolated var displayName: String { "Zweiseitig" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }
        nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? { nil }

        static func title(_ id: String) -> MediaItem {
            MediaItem(id: id, kind: .series, title: id)
        }

        func page(
            in library: Core.Library.ID, filter: ItemFilter, next: String?,
            progress: @Sendable (Int) async -> Void
        ) async throws -> PageChunk {
            asked.append((next, filter.sortBy))
            if next == nil {
                await progress(24)
                return PageChunk(items: [Self.title("a"), Self.title("b")], next: "@2")
            }
            return PageChunk(items: [Self.title("b"), Self.title("c")], next: nil)
        }

        func libraries() async throws -> [Core.Library] { [] }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            Issue.record("A portal level asks page by page, not in one piece")
            return []
        }
        func item(id: String) async throws -> MediaItem { Self.title(id) }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw URLError(.unsupportedURL)
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    private func level(_ source: any ContentSource, rule: ProtectionRule = .pending) -> LibraryModel {
        LibraryModel(
            source: source,
            library: Core.Library(id: "serieshub||anime", name: "Anime", kind: .portalLevel),
            rule: rule, store: InMemoryStore(), sortStore: InMemoryStore())
    }

    private func ids(_ model: LibraryModel) -> [String] {
        if case .ready(let items) = model.state { return items.map(\.id) }
        return []
    }

    @Test("The end of the grid fetches the next page, without duplicates")
    func loadMore() async {
        let source = TwoSided()
        let model = level(source)

        await model.load()
        #expect(ids(model) == ["a", "b"])

        await model.loadMore()
        #expect(ids(model) == ["a", "b", "c"])
        #expect(source.asked.map(\.next) == [nil, "@2"])

        // No marker any more, no fetch any more.
        await model.loadMore()
        #expect(source.asked.count == 2)
    }

    @Test("Rating goes to the source as the sort order — for every page")
    func askedSorted() async {
        let source = TwoSided()
        let model = level(source)

        await model.choose(.rating)
        await model.loadMore()

        #expect(source.asked.map(\.sortBy) == [.rating, .rating])
        // After loading, no preparation is left standing.
        #expect(model.preparedCount == nil)
    }

    @Test("Behind parental controls it still asks page by page")
    func behindTheFilter() {
        let filtered = ProtectionRule.pending.about(TwoSided())
        #expect(filtered is any PageSource)
        let strict = FilteredSource(source: TwoSided(), rule: .pending)
        #expect((strict as any ContentSource) is any PageSource)
    }
}
