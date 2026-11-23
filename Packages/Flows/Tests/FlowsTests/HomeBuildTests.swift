import Core
import Flows
import Foundation
import Testing

/// **The Home rules in one place** (AP58 R6, St1 and St2).
///
/// Both programs ask ``HomeLayout`` and ``Core/ContinueWatching``; the counter-check is to
/// falsify a rule here and see both test suites (`HomeModelTests`, `HeroSelectionTests`,
/// `HomeScreenTests`) go red.
struct HomeBuildTests {

    static func title(
        _ id: String, kind: MediaItem.Kind = .movie, series: String? = nil, image: Bool = true,
        fresh: TimeInterval? = nil, season: Int? = nil, state: PlaybackProgress? = nil
    ) -> MediaItem {
        var artwork = Artwork()
        artwork.backdropID = image ? "b-\(id)" : nil
        return MediaItem(
            id: id, kind: kind, title: id, seriesID: series, seasonNumber: season,
            addedAt: fresh.map { Date(timeIntervalSince1970: $0) }, artwork: artwork,
            progress: state)
    }

    @Test("Heroes: round robin, without image-less titles, home videos and duplicates")
    func heroes() {
        let movies = [Self.title("f1"), Self.title("f2"), Self.title("f3", image: false)]
        let allSeries = [
            Self.title("s1", kind: .series), Self.title("e1", kind: .episode, series: "s1"),
            Self.title("h1", kind: .homeVideo),
        ]
        let chosen = HomeLayout.heroes(libraries: [movies, allSeries], shuffle: false)
        #expect(chosen.map(\.id) == ["f1", "s1", "f2"])

        let short = HomeLayout.heroes(libraries: [movies, allSeries], shuffle: false, atMost: 2)
        #expect(short.map(\.id) == ["f1", "s1"])
    }

    /// **Decision 25:** The header area promotes nothing that is in progress — on no device. A
    /// title with progress appears where its library has it.
    @Test("Heroes: a started title does not move to the front")
    func startedNotInFront() {
        let half = PlaybackProgress(position: 600, duration: 3600)
        let movies = [Self.title("f1"), Self.title("f2", state: half)]
        let allSeries = [Self.title("s1", kind: .series), Self.title("s2", kind: .series)]
        let chosen = HomeLayout.heroes(libraries: [movies, allSeries], shuffle: false)
        #expect(chosen.map(\.id) == ["f1", "s1", "f2", "s2"])
    }

    @Test("Recently added: by date, undated at the end, without duplicates, capped")
    func recent() {
        let a = [Self.title("alt", fresh: 1), Self.title("ohne"), Self.title("neu", fresh: 9)]
        let b = [Self.title("mitte", fresh: 5), Self.title("neu", fresh: 9)]
        #expect(HomeLayout.recent(from: [a, b]).map(\.id) == ["neu", "mitte", "alt", "ohne"])
        #expect(HomeLayout.recent(from: [a, b], atMost: 2).map(\.id) == ["neu", "mitte"])
        #expect(HomeLayout.maxRecent == HomeLayout.titlesPerShelf)
    }

    @Test("Continue Watching: the first mention wins, the content comes from the replacement")
    func mix() {
        let mixed = ContinueWatching.mix(
            [["a", "b"], ["b", "c", "a"]], identifier: { $0 }, ersetze: { $0.uppercased() })
        #expect(mixed == ["A", "B", "C"])
    }

    @Test("Start season: the running one, the last if everything is watched, the first without a count")
    func startSeason() {
        #expect(
            ContinueWatching.startSeason(in: [1, 2, 3], number: { $0 }, pending: { [1: 0, 2: 4, 3: 9][$0] })
                == 2)
        #expect(ContinueWatching.startSeason(in: [1, 2, 3], number: { $0 }, pending: { _ in 0 }) == 3)
        #expect(ContinueWatching.startSeason(in: [1, 2, 3], number: { $0 }, pending: { _ in nil }) == 1)
        #expect(ContinueWatching.startSeason(in: [Int](), number: { $0 }, pending: { _ in 0 }) == nil)
    }

    @Test("Start season: specials (season 0, without number) do not open the series")
    func startSeasonWithoutSpecials() {
        let pending = [0: 3, 1: 0, 2: 5]
        #expect(ContinueWatching.startSeason(in: [0, 1, 2], number: { $0 }, pending: { pending[$0] }) == 2)
        #expect(
            ContinueWatching.startSeason(in: [0, 1, 2], number: { $0 }, pending: { $0 == 0 ? 3 : 0 }) == 2)
        #expect(ContinueWatching.startSeason(in: [0], number: { $0 }, pending: { _ in 3 }) == 0)
        let withoutNumber: [Int?] = [nil, 1]
        #expect(
            ContinueWatching.startSeason(in: withoutNumber, number: { $0 }, pending: { $0 == nil ? 2 : 1 })
                == 1)
    }

    @Test("Next episode: started per isResumable, otherwise unwatched, otherwise the first")
    func nextEpisode() {
        let seen = PlaybackProgress(position: 100, duration: 100, isWatched: true)
        let almostFinished = PlaybackProgress(position: 97, duration: 100)
        let half = PlaybackProgress(position: 50, duration: 100)
        let episodes = [
            Self.title("1", state: seen), Self.title("2", state: almostFinished),
            Self.title("3", state: half),
        ]
        #expect(ContinueWatching.nextEpisode(from: episodes)?.id == "3")
        #expect(ContinueWatching.nextEpisode(from: Array(episodes.prefix(2)))?.id == "2")
        #expect(ContinueWatching.nextEpisode(from: [episodes[0]])?.id == "1")
    }

    @Test("The overview kinds are a board")
    func kinds() {
        #expect(Library.Kind.series.overviewKinds == [.series])
        #expect(Library.Kind.mixed.overviewKinds == [.series, .movie])
        #expect(Library.Kind.portalLevel.overviewKinds.isEmpty)
    }
}
