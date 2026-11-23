import Core
import Foundation
import Testing

@testable import Features

/// **The address of a tile image — and when there is none** (AP29, 2026-09-11).
///
/// At this point the roadmap demanded "series posters on the Continue Watching shelf", with
/// the justification that an episode image is "a dark 16:9 snapshot **without a title**,
/// not attributable to any series from three meters". **On the TV this justification does
/// not hold:** "Continue Watching" draws wide cards, a 16:9 image sits right in them, and
/// ``EpisodeCard`` writes the series name with "S2 F5" beneath it. The finding comes from
/// the phone, where the shelf carries posters in 2:3 format.
///
/// **The real error stood next to it**, and it has a name: `?? item.id`.
struct TileImageTests {

    /// A source that translates every request into a traceable address.
    struct ImageSource: ContentSource {
        nonisolated var displayName: String { "Doppel" }
        nonisolated var canStartAtOffset: Bool { false }
        /// **A test double tracks its own state** — nobody should wrap it.
        nonisolated var tracksStateItself: Bool { true }

        nonisolated func imageURL(
            itemID: String, kind: ImageKind, width: Int, tag: String?
        )
            -> URL?
        {
            URL(string: "https://server/\(itemID)?tag=\(tag ?? "-")")
        }

        func libraries() async throws -> [Core.Library] { [] }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            []
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

    static func episode(_ frames: Artwork) -> MediaItem {
        MediaItem(id: "folge-1", kind: .episode, title: "Folge", artwork: frames)
    }

    /// **An image known to be missing is not requested.**
    ///
    /// Here stood `?? item.id`, and that is exactly the instruction ``PosterAddress`` was built
    /// against on 2026-08-22. ``ItemMapping`` sets `posterID` only if the server carries an image;
    /// without one that was a certain 404 per tile — and in the end a black rectangle instead
    /// of the placeholder that ``RemoteImage`` can show immediately.
    @Test("Without any image there is no address")
    func noAddressWithoutImage() {
        #expect(HomeModel.stillURL(for: Self.episode(Artwork()), from: ImageSource()) == nil)
    }

    /// **The order: own thumbnail, own poster, series poster.**
    @Test("The own preview image comes first")
    func order() throws {
        var frames = Artwork()
        frames.thumbID = "thumb"
        frames.thumbTag = "t1"
        frames.posterID = "folge-1"
        frames.posterTag = "p1"
        frames.seriesPosterID = "serie"
        frames.seriesPosterTag = "s1"

        let address = try #require(HomeModel.stillURL(for: Self.episode(frames), from: ImageSource()))
        #expect(address.absoluteString == "https://server/thumb?tag=t1")
    }

    /// **The series poster as the last resort** — and with its **own** tag.
    ///
    /// An address with a foreign tag is correct but untenable: The server uses the tag for
    /// caching, and a foreign one points at an image that never existed under this identifier.
    @Test("If both are missing the series poster carries — with its own marker")
    func seriesPosterAsFallback() throws {
        var frames = Artwork()
        frames.seriesPosterID = "serie"
        frames.seriesPosterTag = "s1"

        let address = try #require(HomeModel.stillURL(for: Self.episode(frames), from: ImageSource()))
        #expect(address.absoluteString == "https://server/serie?tag=s1")
    }

    /// **And the episode comes before the series.**
    ///
    /// The series poster is the stopgap, not the rule: Whoever looks at an episode has already
    /// seen its image and recognizes it.
    @Test("The own poster beats the series' one")
    func ownBeforeSeries() throws {
        var frames = Artwork()
        frames.posterID = "folge-1"
        frames.posterTag = "p1"
        frames.seriesPosterID = "serie"
        frames.seriesPosterTag = "s1"

        let address = try #require(HomeModel.stillURL(for: Self.episode(frames), from: ImageSource()))
        #expect(address.absoluteString == "https://server/folge-1?tag=p1")
    }

    // MARK: - The chain that never crops (01.10.2026)

    static let file = URL(fileURLWithPath: "/tmp/standbild.jpg#1")

    @Test("An Xtream movie brings a poster — it is shown whole")
    func moviePosterIsTall() throws {
        var frames = Artwork()
        frames.posterID = "plakat"
        let film = MediaItem(id: "x#movie#1", kind: .movie, title: "Kumlu Fincan 5.Bölüm", artwork: frames)
        let image = try #require(
            HomeModel.tileImage(for: film, from: ImageSource(), stillFrame: { _ in nil }))
        #expect(image.up)
    }

    @Test("The still frame comes before everything else — also before the episode image")
    func stillFrameInTheChain() throws {
        var frames = Artwork()
        frames.posterID = "plakat"
        frames.backdropID = "hinten"
        let film = MediaItem(id: "x#movie#1", kind: .movie, title: "Film", artwork: frames)
        let using = try #require(
            HomeModel.tileImage(for: film, from: ImageSource(), stillFrame: { _ in Self.file }))
        #expect(using == .init(url: Self.file, up: false))
        let without = try #require(
            HomeModel.tileImage(for: film, from: ImageSource(), stillFrame: { _ in nil }))
        #expect(without.url.absoluteString.hasPrefix("https://server/hinten") && !without.up)

        var episodeImages = Artwork()
        episodeImages.posterID = "folgenbild"
        let episode = MediaItem(id: "f", kind: .episode, title: "Folge", artwork: episodeImages)
        let own = try #require(
            HomeModel.tileImage(for: episode, from: ImageSource(), stillFrame: { _ in Self.file }))
        #expect(own.url == Self.file)
    }

    @Test("A portal image verified as tall is not an episode image")
    func checkedTallStaysTall() throws {
        var frames = Artwork()
        frames.posterID = "plakat"
        frames.isWide = false
        let episode = MediaItem(id: "f", kind: .episode, title: "Folge", artwork: frames)
        let image = try #require(
            HomeModel.tileImage(for: episode, from: ImageSource(), stillFrame: { _ in nil }))
        #expect(image.up)
    }
}
