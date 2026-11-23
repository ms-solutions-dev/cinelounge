import Core
import Foundation
import Testing

@testable import Features

/// **"On Home and Favorites" per portal on the TV as well** (decision 27, C12).
///
/// A portal in its own area is not in "Continue Watching" and not in
/// Favorites — the same rule and the same store as on the phone (``Core/PortalPreferences``).
@MainActor
struct PortalPreferencesTVTests {

    final class Started: ContentSource, @unchecked Sendable {
        nonisolated var displayName: String { "Doppel" }
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
            ["adult|s|/a", "animehub|s|/b", "a1b2c3"].map {
                MediaItem(id: $0, kind: .movie, title: $0)
            }
        }
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

    @Test("A portal in its own section is missing from Continue Watching")
    func continueWatching() async throws {
        try await ProfilePointer.als(nil) {
            let store = InMemoryStore()
            var preferences = PortalPreferences()
            preferences.countTogether("adult", false)
            preferences.save(to: store)

            let model = HomeModel(source: Started(), store: store, shelfStore: store)
            await model.load()
            guard case .ready(_, let shelves) = model.state else {
                Issue.record("Home not ready: \(model.state)")
                return
            }
            let next = try #require(shelves.first { $0.id == ShelfPreferences.resumeID })
            #expect(
                next.items.map(\.id).sorted() == ["a1b2c3", "animehub|s|/b"], "\(next.items.map(\.id))")
        }
    }

    @Test("A portal in its own section is missing from Favorites")
    func favorites() async {
        var preferences = PortalPreferences()
        preferences.countTogether("adult", false)
        let remembered = preferences
        let model = FavoritesModel(
            loadItems: { [] }, loadChannels: { [] },
            loadPortals: {
                ["adult|s|/a", "animehub|s|/b"].map { MediaItem(id: $0, kind: .series, title: $0) }
            },
            portalPreferences: { remembered })
        await model.load()
        let identifiers = model.sections.flatMap { $0.items.map(\.id) }
        #expect(identifiers.contains("animehub|s|/b"))
        #expect(!identifiers.contains("adult|s|/a"))
    }
}
