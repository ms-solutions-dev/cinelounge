import Core
import Flows
import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Favorites on the phone are ordered as on the TV** (AP58 R6, St3).
struct FavoritesOrderPhoneTests {

    struct Remembered: ContentSource {
        let title: [MediaItem]
        var displayName: String { "Probe" }
        nonisolated var canStartAtOffset: Bool { true }
        nonisolated var tracksStateItself: Bool { true }
        func libraries() async throws -> [Library] { [] }
        func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { title[0] }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func collections() async throws -> [MediaItem] { [] }
        func favorites() async throws -> [MediaItem] { title }
        func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] { [] }
        func episodes(of seriesID: String) async throws -> [MediaItem] { [] }
        func similarItem(to itemID: String) async throws -> MediaItem? { nil }
        func nextEpisode(after itemID: String) async throws -> MediaItem? { nil }
        func trailer(for itemID: String) async throws -> MediaItem? { nil }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            URL(string: "https://probe.invalid")!
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    @Test("The media server splits into movies and series, by title, episodes under the series")
    func shared() async {
        let source = Remembered(title: [
            MediaItem(id: "m2", kind: .movie, title: "Zimtwald"),
            MediaItem(id: "e1", kind: .episode, title: "Folge", seriesID: "s1"),
            MediaItem(id: "s1", kind: .series, title: "Dunmere"),
            MediaItem(id: "m1", kind: .movie, title: "Aldersee"),
        ])
        let bundles = await CatalogFavorites(
            source: source, origin: .jellyfin, headline: .key("stock.mediaServer"),
            width: 100, isShared: true
        ).segments()

        #expect(bundles.map(\.section) == [.movies, .allSeries])
        #expect(bundles[0].title.map(\.id) == ["m1", "m2"])
        #expect(bundles[1].title.map(\.id) == ["s1"])
        #expect(Set(bundles.map(\.id)).count == 2)
    }

    /// **The provider catalog was missing with an outdated reason** — the still-frame wrapper
    /// carries its marks.
    @Test("The favorites source list names the provider when there is one")
    func providerInSourceText() throws {
        let sourceText = try SourceText.read("SourceAssembly.swift", in: .featuresPhone)
        #expect(sourceText.contains("origin: .provider"))
    }
}
