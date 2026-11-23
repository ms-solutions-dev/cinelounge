import Core
import DesignSystem
import Foundation
import Testing

@testable import Features

/// Whether the image prefetch of the detail page is of any use at all.
///
/// **The trap being checked against here is silent.** A prefetch only works if it stores
/// under the same key the view later looks up — that is, **the same address at the same
/// width**. If even just the width differs, the image is fetched, stored and never found:
/// It loads twice and still seems as if there were no prefetch. Nothing fails, nothing is
/// reported. That is exactly how the list prefetch once ran into the void.
///
/// So what is checked is not *that* prefetching happens but that both routes lead to the
/// **same address**: the prefetch's route (without a model, only with title and source)
/// and the view's route.
@Suite("Image prefetch of the detail page")
@MainActor
struct DetailPrefetchTests {

    /// The width of the background image is the one the detail page draws with.
    ///
    /// It was wrong here once before — 1920 requested for a surface drawn at 3840 pixels. It
    /// therefore lives in exactly one place, and this check holds it there.
    @Test("Backdrop: prefetch and display ask the same address")
    func backdropAddressesMatch() {
        let source = SourceDouble()
        var item = MediaItem(id: "film-1", kind: .movie, title: "Zirkel der Uhrmacher")
        item.artwork.backdropID = "film-1"
        item.artwork.backdropTag = "abc123"

        let fromPrefetch = DetailModel.backdropURL(for: item, from: source)
        let fromView = DetailModel.backdropURL(
            for: item, from: source, width: ImageSizing.backdropWidth(points: 1920))

        #expect(fromPrefetch != nil)
        #expect(fromPrefetch == fromView)
        // The width must really be in the address — otherwise this test would compare two routes
        // that both distinguish nothing.
        #expect(fromPrefetch?.absoluteString.contains("maxWidth=") == true)
        #expect(fromPrefetch?.absoluteString.contains("tag=abc123") == true)
    }

    @Test("Cast photo: the same address as in the row")
    func personAddressesMatch() {
        let source = SourceDouble()
        let person = Person(id: "p-1", name: "Konrad L. Wester", role: .actor)

        let fromPrefetch = DetailModel.personURL(for: person, from: source)
        let expectedWidth = ImageSizing.requestWidth(points: MetricsBoard.tv.person)

        #expect(fromPrefetch?.absoluteString.contains("maxWidth=\(expectedWidth)") == true)
    }

    @Test("Episode still frame: the same address as on the card")
    func stillAddressesMatch() {
        let source = SourceDouble()
        let episode = MediaItem(id: "e-1", kind: .episode, title: "Pilot")

        let fromPrefetch = DetailModel.stillURL(for: episode, from: source)

        #expect(fromPrefetch?.absoluteString.contains("maxWidth=840") == true)
    }

    /// A title without a background image must not yield an address — otherwise the prefetch
    /// would fetch an error message from the server for every such title.
    @Test("Without a backdrop nothing is fetched")
    func noBackdropMeansNoAddress() {
        let item = MediaItem(id: "film-2", kind: .movie, title: "Ohne Bild")
        #expect(DetailModel.backdropURL(for: item, from: SourceDouble()) == nil)
    }
}

/// A source that builds the address like Jellyfin — width and tag are in it, and the key
/// is decided exactly by that.
final class SourceDouble: ContentSource {

    /// No background sync — test doubles report nothing afterwards. Written out because the
    /// contract no longer has a default for it; why is at ``ContentSource/listChanges()``.
    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    nonisolated var displayName: String { "Doppel" }
    nonisolated var canStartAtOffset: Bool { true }
    /// **A test double tracks its own state** — nobody should wrap it.
    nonisolated var tracksStateItself: Bool { true }

    nonisolated func imageURL(
        itemID: String, kind: ImageKind, width: Int, tag: String?
    ) -> URL? {
        var address = "https://server/Items/\(itemID)/Images/\(kind)?maxWidth=\(width)"
        if let tag { address += "&tag=\(tag)" }
        return URL(string: address)
    }

    func libraries() async throws -> [Core.Library] { [] }
    func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
        []
    }
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
