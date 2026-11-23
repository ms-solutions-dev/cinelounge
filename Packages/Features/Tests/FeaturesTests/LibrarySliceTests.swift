import Core
import Flows
import Foundation
import Testing

@testable import Features

/// **"Angefangen", "Ungesehen", "Favoriten" as on the phone** (decision 27, C6).
///
/// Until 2026-09-26 the library on the TV knew only "Ungesehen", with its own rule
/// (`progress?.isWatched != true`): Started movies and every series counted as unwatched.
/// Now the same chips and the same rule as on the phone (``Flows/CatalogSlice``).
@MainActor
struct LibrarySliceTests {

    final class Catalog: ContentSource, @unchecked Sendable {
        nonisolated var displayName: String { "Bestand-Doppel" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }

        nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? {
            nil
        }

        func libraries() async throws -> [Core.Library] { [] }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            var seen = MediaItem(id: "a1", kind: .movie, title: "Gesehen")
            seen.progress = PlaybackProgress(position: 100, duration: 100, isWatched: true)
            var half = MediaItem(id: "a2", kind: .movie, title: "Halb")
            half.progress = PlaybackProgress(position: 50, duration: 100)
            var remembered = MediaItem(id: "a3", kind: .movie, title: "Gemerkt")
            remembered.isFavorite = true
            var halfSeries = MediaItem(id: "a4", kind: .series, title: "Serie halb")
            halfSeries.episodeCount = 10
            halfSeries.unplayedCount = 4
            var newSeries = MediaItem(id: "a5", kind: .series, title: "Serie neu")
            newSeries.episodeCount = 10
            newSeries.unplayedCount = 10
            return [seen, half, remembered, halfSeries, newSeries]
        }
        func item(id: String) async throws -> MediaItem { throw URLError(.badURL) }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw URLError(.badURL)
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    private func model(_ id: String = "a1b2c3", kind: Core.Library.Kind = .movies) -> LibraryModel {
        let store = InMemoryStore()
        return LibraryModel(
            source: Catalog(), library: Core.Library(id: id, name: "Filme", kind: kind),
            store: store, sortStore: store)
    }

    private func shown(_ model: LibraryModel) -> [String] {
        guard case .ready(let title) = model.state else { return [] }
        return title.map(\.id).sorted()
    }

    @Test("The three slices filter by status, a second press undoes it")
    func slices() async {
        let model = model()
        await model.load()
        #expect(model.availableSlices == [.started, .unwatched, .favorites])
        #expect(shown(model).count == 5)

        await model.select(slice: .started)
        #expect(shown(model) == ["a2", "a4"])
        await model.select(slice: .unwatched)
        #expect(shown(model) == ["a3", "a5"])
        await model.select(slice: .favorites)
        #expect(shown(model) == ["a3"])
        await model.select(slice: .favorites)
        #expect(model.slice == nil)
        #expect(shown(model).count == 5)
    }

    @Test("Provider catalog and portals carry no status — the row is dropped")
    func withoutState() {
        #expect(model("liste|vod|1").availableSlices.isEmpty)
        #expect(model("animehub|neu|", kind: .portalLevel).availableSlices.isEmpty)
        #expect(model(kind: .homeVideos).availableSlices == [.started, .favorites])
    }
}
