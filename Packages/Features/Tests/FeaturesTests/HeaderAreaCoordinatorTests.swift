import Core
import Foundation
import Testing

@testable import Features

/// **The hero area without a media server** (decision 27, C4).
///
/// Until 2026-09-26 the box on the TV stayed empty as soon as there was no movie and no
/// series with a background image. In that case the phone asked the provider catalog for
/// titles with a background image (step 2 of the ``Flows/HeroLadder``) — now both do.
@MainActor
struct HeaderAreaCoordinatorTests {

    /// A provider catalog with one category: The list carries no background images, only the
    /// individual query (`get_vod_info`) brings them.
    final class ContentCatalog: ContentSource, @unchecked Sendable {
        nonisolated var displayName: String { "Katalog-Doppel" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }

        private(set) var queried: [String] = []
        let withImage: Set<String>

        init(withImage: Set<String>) { self.withImage = withImage }

        nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? {
            nil
        }

        func libraries() async throws -> [Core.Library] {
            [Core.Library(id: "liste|vod|1", name: "DE| KINO", kind: .movies)]
        }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            (1...4).map { MediaItem(id: "liste#movie#\($0)", kind: .movie, title: "Film \($0)") }
        }
        func item(id: String) async throws -> MediaItem {
            queried.append(id)
            var title = MediaItem(id: id, kind: .movie, title: id)
            if withImage.contains(id) { title.artwork.backdropID = "b-\(id)" }
            return title
        }
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

    @Test("Without a Jellyfin server the provider catalog fills the header area — only with an image")
    func providerFillsHeader() async {
        await ProfilePointer.als(nil) {
            let store = InMemoryStore()
            let source = ContentCatalog(withImage: ["liste#movie#2", "liste#movie#4"])
            let model = HomeModel(source: source, store: store, shelfStore: store)
            await model.load()

            guard case .ready(let heroes, _) = model.state else {
                Issue.record("Home not ready: \(model.state)")
                return
            }
            #expect(Set(heroes.map(\.id)) == ["liste#movie#2", "liste#movie#4"])
            #expect(!source.queried.isEmpty)
        }
    }
}
