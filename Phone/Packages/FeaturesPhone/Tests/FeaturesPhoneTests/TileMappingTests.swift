import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// Five rules that are not obvious — and are therefore checked.
@Suite("Tile mapping")
struct TileMappingTests {

    private func film(progress: PlaybackProgress? = nil) -> MediaItem {
        var title = MediaItem(id: "1", kind: .movie, title: "Kriosf", year: 1993)
        title.progress = progress
        return title
    }

    private func series(unplayed: Int?, episodes: Int?) -> MediaItem {
        var title = MediaItem(id: "2", kind: .series, title: "Siege on Corvane", year: 2011)
        title.unplayedCount = unplayed
        title.episodeCount = episodes
        return title
    }

    /// `progress` is set even for a title that has been watched completely, and for one
    /// that stands at zero. A bar at 0 % says "something has been started here", and that
    /// is then not true.
    @Test("A progress bar only when there is progress")
    func progress() {
        #expect(TileArtwork.progress(film()) == nil)
        #expect(TileArtwork.progress(film(progress: .init(position: 0, duration: 100))) == nil)
        #expect(
            TileArtwork.progress(
                film(progress: .init(position: 100, duration: 100, isWatched: true))) == nil)
        #expect(
            TileArtwork.progress(film(progress: .init(position: 42, duration: 100))) != nil)
        // Almost finished is not started: a bar at 99.5 % is a full bar.
        #expect(
            TileArtwork.progress(film(progress: .init(position: 99.6, duration: 100))) == nil)
    }

    /// **The finding from 2026-09-05** "269 new" stood on a series from 2007 in which nothing was
    /// new: `unplayedCount` is the unwatched episodes, and for a series
    /// never started that is its length. It becomes information only once one is
    /// inside.
    @Test("The counter counts only for a series that has been started")
    func counter() {
        // A film has no episodes that could be open.
        #expect(TileArtwork.counter(film()) == nil)
        // Alles gesehen.
        #expect(TileArtwork.counter(series(unplayed: 0, episodes: 87)) == nil)
        // Never started — the number would be the series length.
        #expect(TileArtwork.counter(series(unplayed: 279, episodes: 279)) == nil)
        // Without an episode count "started" cannot be determined.
        #expect(TileArtwork.counter(series(unplayed: 17, episodes: nil)) == nil)
    }

    /// A bare number on a tile is a question and not information.
    @Test("The counter carries its unit")
    func counterUnit() {
        let text = TileArtwork.counter(series(unplayed: 1, episodes: 87))
        #expect(text?.contains("1") == true)
        #expect(text != "1")
    }

    /// The spot at the top right carries exactly one piece of information. Whoever is in the middle of a series
    /// wants to see the open episodes — the rating has long since become irrelevant.
    @Test("Counter and rating never appear on one tile at the same time")
    func counterSupersedesRating() {
        var started = series(unplayed: 17, episodes: 18)
        started.ratings.imdb = 9.0
        #expect(TileArtwork.counter(started) != nil)
        #expect(TileArtwork.rating(started) != nil)

        var untouched = series(unplayed: 18, episodes: 18)
        untouched.ratings.imdb = 9.0
        #expect(TileArtwork.counter(untouched) == nil)
    }

    /// All four services return a zero for a title without votes. Xtream sends
    /// it with every second entry — displayed, it would look like a devastating
    /// verdict.
    @Test("Zero is not a rating")
    func zeroIsNoRating() {
        var withoutVotes = film()
        withoutVotes.ratings.community = 0
        withoutVotes.ratings.imdb = 0
        #expect(TileArtwork.rating(withoutVotes) == nil)
    }

    /// Seven genres fill the row and push year and rating out of the picture — the
    /// two details that anybody searches for at all.
    @Test("The attributes line takes at most two genres")
    func attributes() {
        var title = film()
        title.ageRating = "FSK 16"
        title.genres = ["Thriller", "Krimi", "Drama", "Mystery"]
        #expect(TileArtwork.attributes(title) == ["1993", "FSK 16", "Thriller", "Krimi"])

        var sparse = MediaItem(id: "3", kind: .movie, title: "Ohne alles")
        sparse.ageRating = ""
        // What is missing leaves no gap — otherwise the row would begin with a separator.
        #expect(TileArtwork.attributes(sparse).isEmpty)
    }

    /// In a "Continue Watching" shelf one looks for the series and not the fourth episode.
    @Test("For an episode the series is shown on top")
    func episodeCaption() {
        var episode = MediaItem(id: "2", kind: .episode, title: "Der Anfang")
        episode.parentTitle = "Kobe Runaways"
        episode.seasonNumber = 1
        episode.episodeNumber = 21

        #expect(TileArtwork.label(episode) == "Kobe Runaways")
        #expect(TileArtwork.secondaryLine(episode) == EpisodeIdentifier.text(season: 1, episode: 21))
    }

    @Test("For a film the year is shown below")
    func movieCaption() {
        #expect(TileArtwork.label(film()) == "Kriosf")
        #expect(TileArtwork.secondaryLine(film()) == "1993")
    }
}

/// Which picture an episode carries in a mixed shelf — **finding from 2026-09-09**
///
/// Seen in the simulator: in the "Continue Watching" shelf films stood as a
/// portrait poster, series as a small landscape image on a black surface. On an episode
/// `Artwork.posterID` is the identifier of the **episode**, and behind it lies the
/// episode screenshot in 16 : 9 format.
///
/// **Two things must be right together**, and that is why both stand in every check: the
/// address **and** ``TileContent/wide``. If the format stayed at "wide", ``PosterTile``
/// would again fit the right poster too — the same black surface, only
/// with the right picture in it.
@Suite("Series poster on the episode tile")
struct SeriesPosterTests {

    private func episode(seriesImage: Bool, wide: Bool? = true) -> MediaItem {
        var frames = Artwork(
            posterID: "episode-1", posterTag: "tag-episode", isWide: wide)
        if seriesImage {
            frames.seriesPosterID = "series-9"
            frames.seriesPosterTag = "tag-series"
        }
        var title = MediaItem(id: "episode-1", kind: .episode, title: "Der Anfang")
        title.artwork = frames
        title.parentTitle = "Blono"
        title.seriesID = "series-9"
        return title
    }

    @Test("An episode with a series poster shows the series poster — and no longer wide")
    func withSeriesPoster() {
        let built = TileArtwork.tile(episode(seriesImage: true), source: ImageSource(), width: 110)
        #expect(built.image?.absoluteString.contains("series-9") == true)
        #expect(built.image?.absoluteString.contains("tag-series") == true)
        #expect(built.wide == false)
    }

    /// **Without a series poster everything stays as before.** Not every series carries one; the
    /// episode screenshot is then better information than an empty frame — and with
    /// it its format information stays too.
    @Test("Without a series poster the episode image stays, including its format")
    func withoutSeriesPoster() {
        let built = TileArtwork.tile(episode(seriesImage: false), source: ImageSource(), width: 110)
        #expect(built.image?.absoluteString.contains("episode-1") == true)
        #expect(built.wide == true)
    }

    /// **A film has no series.** The switch hangs on the kind and not on whether
    /// something happens to be there — the same reasoning as for ``TileArtwork/series(_:)``.
    @Test("A film stays untouched")
    func film() {
        var frames = Artwork(posterID: "film-1", posterTag: "tag-film", isWide: false)
        // Filled on purpose: the value must not reach a film.
        frames.seriesPosterID = "series-9"
        var title = MediaItem(id: "film-1", kind: .movie, title: "Kriosf", year: 1993)
        title.artwork = frames

        let built = TileArtwork.tile(title, source: ImageSource(), width: 110)
        #expect(built.image?.absoluteString.contains("film-1") == true)
        #expect(built.wide == false)
    }
}

/// A source that builds a readable address from identifier and tag.
///
/// **No re-creation of Jellyfin.** What is checked is **which** identifier the mapping chooses —
/// an address in which identifier and tag appear is enough for that.
private struct ImageSource: ContentSource {
    var displayName: String { "Probe" }
    nonisolated var canStartAtOffset: Bool { false }
    nonisolated var tracksStateItself: Bool { true }
    func libraries() async throws -> [Library] { [] }
    func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { MediaItem(id: id, kind: .movie, title: "") }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func resumable(limit: Int) async throws -> [MediaItem] { [] }
    func segments(for itemID: String) async throws -> [MediaSegment] { [] }
    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        URL(string: "https://example.invalid")!
    }
    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
    func favorites() async throws -> [MediaItem] { [] }
    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? {
        URL(string: "https://example.invalid/\(itemID)/\(kind.rawValue)?tag=\(tag ?? "none")")
    }
}

/// Where one stands with a title — and why two yes/no fields do not answer that.
@Suite("Watch state")
struct WatchStateTests {

    private func series(pending: Int?, episodes: Int?) -> MediaItem {
        var title = MediaItem(id: "s", kind: .series, title: "Kobe Runaways")
        title.unplayedCount = pending
        title.episodeCount = episodes
        return title
    }

    private func film(_ state: PlaybackProgress?) -> MediaItem {
        var title = MediaItem(id: "f", kind: .movie, title: "Kriosf")
        title.progress = state
        return title
    }

    /// **The finding from 2026-09-05:** the library filter "Started" returned an empty list
    /// for twenty-three series, because Jellyfin carries `PlayedPercentage` only on
    /// episodes and films. A series states its progress via its episode counts.
    @Test("A series computes its state from its episodes")
    func seriesState() {
        #expect(TileArtwork.state(series(pending: 50, episodes: 50)) == .untouched)
        #expect(TileArtwork.state(series(pending: 17, episodes: 50)) == .started)
        #expect(TileArtwork.state(series(pending: 0, episodes: 50)) == .finished)
    }

    /// **Without both numbers nothing is claimed.** "I have looked in here before"
    /// is the stronger statement — guessing it would be the costlier error.
    @Test("Without numbers a series counts as untouched")
    func withoutNumbers() {
        #expect(TileArtwork.state(series(pending: nil, episodes: nil)) == .untouched)
        #expect(TileArtwork.state(series(pending: 3, episodes: nil)) == .untouched)
        #expect(TileArtwork.state(series(pending: 3, episodes: 0)) == .untouched)
    }

    /// For a film the progress decides — and a bar at 0 % or 100 %
    /// is none.
    @Test("A film computes its state from its progress")
    func movieState() {
        #expect(TileArtwork.state(film(nil)) == .untouched)
        #expect(TileArtwork.state(film(.init(position: 0, duration: 100))) == .untouched)
        #expect(TileArtwork.state(film(.init(position: 42, duration: 100))) == .started)
        #expect(
            TileArtwork.state(film(.init(position: 100, duration: 100, isWatched: true)))
                == .finished)
    }
}

/// All episodes carry a text or none — the height of the rows is the information
/// that the entries are of the same kind.
@Suite("Episode descriptions")
struct EpisodeDescriptionTests {

    private func season(_ texts: [String?]) -> Season {
        Season(
            id: 1,
            episodes: texts.enumerated().map { location, text in
                EpisodeInfo(
                    id: "f\(location)", number: location + 1, title: "Folge \(location + 1)",
                    description: text)
            })
    }

    /// **The finding from 2026-09-05** (*Baykuş Geçidi*, season 1): one of twelve episodes
    /// carried a text. The row was twice as tall as its neighbors, and the list
    /// looked as if something had gone wrong while loading — although every row was
    /// correct on its own.
    @Test("A single gap removes the texts from the whole season")
    func allOrNone() {
        #expect(season(["Eins", "Zwei", "Drei"]).showsDescriptions)
        #expect(!season(["Eins", nil, "Drei"]).showsDescriptions)
        #expect(!season([nil, nil, nil]).showsDescriptions)
    }

    /// A season without episodes shows nothing — and does not claim that it does.
    @Test("Without episodes there is nothing to show")
    func empty() {
        #expect(!Season(id: 1, episodes: []).showsDescriptions)
    }
}
