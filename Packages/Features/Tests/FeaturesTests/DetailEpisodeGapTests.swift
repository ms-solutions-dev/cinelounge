import Core
import Foundation
import Testing

@testable import Features

/// **Why a series page is empty has to be stated on the page.**
///
/// Viewer finding 2026-08-22: a series area showed nothing to play when a title was selected.
/// Measured against the provider: Of 50 series across the catalog, ten have no episode at
/// all in the panel — the gap lies there, not here. Until then such a page looked exactly
/// like one whose fetch had failed: without an episode row, without a play button, without
/// a word about it.
@Suite("Missing episodes on the detail page")
@MainActor
struct DetailEpisodeGapTests {

    private func series() -> MediaItem {
        MediaItem(id: "s1", kind: .series, title: "Moth Cascade Filmreihe")
    }

    /// The fetch went through and returned nothing: That is a statement about the provider,
    /// and the page may make it.
    @Test("An empty answer reports the provider's gap")
    func providerHasNone() async {
        let model = DetailModel(source: EpisodeGapDouble(children: []), item: series())
        await model.load()
        #expect(model.episodeGap == .providerHasNone)
        #expect(model.playbackTarget == nil)
    }

    /// A failed fetch is something different and must not pass as "provider has nothing" —
    /// otherwise the page asserts something about foreign data it never saw.
    @Test("A failed fetch does not become a statement about the provider")
    func lookupFailed() async {
        let model = DetailModel(source: EpisodeGapDouble(children: nil), item: series())
        await model.load()
        #expect(model.episodeGap == .lookupFailed)
    }

    /// The counter-check: Where episodes arrive, the page stays wordless.
    @Test("With episodes no notice remains")
    func noGap() async {
        let episode = MediaItem(id: "e1", kind: .episode, title: "Folge 1")
        let model = DetailModel(source: EpisodeGapDouble(children: [episode]), item: series())
        await model.load()
        #expect(model.episodeGap == .none)
        #expect(model.playbackTarget?.id == "e1")
    }

    /// **Seasons save nothing.** "A Gathering of Herons" reports four seasons including the
    /// episode count and still lists no episode; the selected season stays empty, and exactly
    /// that needs to be said.
    @Test("Seasons without episodes also report the gap")
    func seasonsWithoutEpisodes() async {
        let season = MediaItem(id: "st1", kind: .season, title: "Staffel 1")
        let model = DetailModel(source: EpisodeGapDouble(children: [season]), item: series())
        await model.load()
        #expect(model.seasons.count == 1)
        #expect(model.episodeGap == .providerHasNone)
    }
}

/// A source that on request delivers nothing or fails.
///
/// `children == nil` means: The fetch throws. The difference these checks pin down hangs
/// on exactly that.
final class EpisodeGapDouble: ContentSource {

    private let children: [MediaItem]?

    init(children: [MediaItem]?) { self.children = children }

    struct OutageError: Error {}

    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    nonisolated var displayName: String { "Doppel" }
    nonisolated var canStartAtOffset: Bool { false }
    /// **A test double tracks its own state** — nobody should wrap it.
    nonisolated var tracksStateItself: Bool { true }

    nonisolated func imageURL(
        itemID: String, kind: ImageKind, width: Int, tag: String?
    ) -> URL? { nil }

    func libraries() async throws -> [Core.Library] { [] }
    func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        MediaItem(id: id, kind: .series, title: "Moth Cascade Filmreihe")
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        guard let children else { throw OutageError() }
        // A season in turn has no episodes — the case "A Gathering of Herons", where the season
        // data are there and nothing else.
        return itemID == "s1" ? children : []
    }
    func resumable(limit: Int) async throws -> [MediaItem] { [] }
    func segments(for itemID: String) async throws -> [MediaSegment] { [] }
    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
    func favorites() async throws -> [MediaItem] { [] }
    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        URL(string: "https://server/\(itemID)")!
    }
}
