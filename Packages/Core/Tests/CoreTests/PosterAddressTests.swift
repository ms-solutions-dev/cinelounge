import Foundation
import Testing

@testable import Core

/// **A poster that does not exist is not requested.**
///
/// Viewer finding 2026-08-22: the series "Kadim Yol" appeared in the grid as an empty
/// frame, while on the media server it looks right. Checked on the server:
/// `Images/Primary` answers with 404, `Images/Backdrop` with 200 — the series simply
/// has no poster. The poster address was built anyway.
@Suite("Poster address")
struct PosterAddressTests {

    private let source = AddressDouble()

    private func item(_ artwork: Artwork) -> MediaItem {
        MediaItem(id: "eigen", kind: .series, title: "Kadim Yol", artwork: artwork)
    }

    @Test("With a poster the poster is used, tag included")
    func prefersThePoster() throws {
        let url = try #require(
            PosterAddress.url(
                for: item(Artwork(posterID: "p", backdropID: "b", posterTag: "t1")),
                from: source, width: 240))
        #expect(url.absoluteString == "https://server/p/Primary?w=240&tag=t1")
    }

    /// The actual finding: without a poster, the background image instead of an address
    /// that is already known to lead nowhere.
    @Test("Without a poster the backdrop is used")
    func fallsBackToTheBackdrop() throws {
        let url = try #require(
            PosterAddress.url(
                for: item(Artwork(backdropID: "b", backdropTag: "t2")),
                from: source, width: 240))
        #expect(url.absoluteString == "https://server/b/Backdrop?w=240&tag=t2")
    }

    /// In between, the thumbnail: it is also wide, but kept up as a showpiece — closer to
    /// the poster than a background image.
    @Test("The thumbnail comes before the backdrop")
    func thumbBeatsBackdrop() throws {
        let url = try #require(
            PosterAddress.url(
                for: item(Artwork(backdropID: "b", thumbID: "th", thumbTag: "t3")),
                from: source, width: 240))
        #expect(url.absoluteString == "https://server/th/Thumb?w=240&tag=t3")
    }

    /// **And otherwise nothing at all.** Before, this said `posterID ?? item.id`: one
    /// request per tile that had to fail, and then an empty frame. Without an address the
    /// tile shows its placeholder immediately.
    @Test("With no image at all no address is built")
    func noImageMeansNoAddress() {
        #expect(PosterAddress.url(for: item(Artwork()), from: source, width: 240) == nil)
    }
}

/// Builds a recognizable address from identifier, kind, width and brand.
final class AddressDouble: ContentSource {

    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    nonisolated var displayName: String { "Doppel" }
    nonisolated var canStartAtOffset: Bool { false }
    /// **A test double keeps its own state** — nobody is supposed to wrap it.
    nonisolated var tracksStateItself: Bool { true }

    nonisolated func imageURL(
        itemID: String, kind: ImageKind, width: Int, tag: String?
    ) -> URL? {
        var address = "https://server/\(itemID)/\(kind.rawValue)?w=\(width)"
        if let tag { address += "&tag=\(tag)" }
        return URL(string: address)
    }

    func libraries() async throws -> [Library] { [] }
    func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { MediaItem(id: id, kind: .movie, title: "") }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
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
