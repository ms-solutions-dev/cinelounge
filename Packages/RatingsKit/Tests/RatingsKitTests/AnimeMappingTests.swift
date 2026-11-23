import Core
import Foundation
import Synchronization
import Testing

@testable import RatingsKit

/// The mapping series + season → MAL/AniList (AP68) — on the cases where Jellyfin's
/// plugin was wrong on 2026-10-06, with excerpts from the real list.
@Suite("Anime mapping")
struct AnimeMappingTests {

    /// Excerpt from `anime-list-full.json`, field shapes as in the original.
    static let list = Data(
        #"""
        [
          {"type":"TV","mal_id":27,"anilist_id":27,"tvdb_id":61493,"themoviedb_id":{"tv":47258}},
          {"type":"MOVIE","mal_id":563,"anilist_id":563,"tvdb_id":61493,"themoviedb_id":{"movie":[29371]},"season":{"tvdb":0}},
          {"type":"TV","mal_id":48317,"anilist_id":112457,"tvdb_id":468193,"themoviedb_id":{"tv":77912},"season":{"tvdb":1,"tmdb":1}},
          {"type":"TV","mal_id":58291,"anilist_id":145329,"tvdb_id":468193,"themoviedb_id":{"tv":77912},"season":{"tvdb":2,"tmdb":2}},
          {"type":"TV","mal_id":53168,"anilist_id":131247,"tvdb_id":482369,"themoviedb_id":{"tv":116328},"season":{"tvdb":1,"tmdb":1}},
          {"type":"TV","mal_id":65827,"anilist_id":174238,"tvdb_id":482369,"themoviedb_id":{"tv":116328},"season":{"tvdb":3,"tmdb":1}},
          {"type":"MOVIE","mal_id":43172,"anilist_id":32428,"themoviedb_id":{"movie":[483169]},"imdb_id":["tt1824008"]},
          {"type":"TV","anidb_id":1},
          {"type":"TV","mal_id":99999}
        ]
        """#.utf8)

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "animezuordnung-\(UUID().uuidString)")
    }

    private func index() throws -> AnimeMapping.Index {
        try AnimeMapping.Index(raw: Self.list, asOf: Date())
    }

    @Test("Northmark Saga: season 1 is MAL 48317 — Jellyfin carried the number of the second")
    func seasonOne() throws {
        let i = try index()
        #expect(
            i.search(tvdb: "468193", tmdb: nil, imdb: nil, season: 1) == .init(mal: 48317, anilist: 112457))
        #expect(
            i.search(tvdb: "468193", tmdb: nil, imdb: nil, season: 2) == .init(mal: 58291, anilist: 145329))
        // Control test: the number that Jellyfin brought along is the second season.
        #expect(i.search(tvdb: "468193", tmdb: nil, imdb: nil, season: 1)?.anilist != 145329)
    }

    @Test("Salt Compass: the series, never the movie with the same TVDB number")
    func movieNeverStandsInForSeries() throws {
        let i = try index()
        #expect(i.search(tvdb: "61493", tmdb: nil, imdb: nil, season: 1)?.mal == 27)
        // Long series without a season value apply to every season.
        #expect(i.search(tvdb: "61493", tmdb: nil, imdb: nil, season: 14)?.mal == 27)
    }

    @Test("Via TMDb: IPTV and CL-Server titles, series by season, movies directly")
    func tmdb() throws {
        let i = try index()
        #expect(i.search(tvdb: nil, tmdb: "tv/77912", imdb: nil, season: 1)?.mal == 48317)
        #expect(i.search(tvdb: nil, tmdb: "movie/483169", imdb: nil, season: 1)?.mal == 43172)
        // The same number as a series is a different title — TMDb counts both separately.
        #expect(i.search(tvdb: nil, tmdb: "tv/483169", imdb: nil, season: 1) == nil)
        // TVDB beats TMDb: for Kobe Runaways TMDb merges three seasons into one.
        #expect(i.search(tvdb: "482369", tmdb: "tv/116328", imdb: nil, season: 1)?.mal == 53168)
    }

    @Test("IMDb only for movies and series with a single entry")
    func imdb() throws {
        let i = try index()
        #expect(i.search(tvdb: nil, tmdb: nil, imdb: "tt1824008", season: 1)?.mal == 43172)
        #expect(i.search(tvdb: nil, tmdb: nil, imdb: "tt0000000", season: 1) == nil)
    }

    @Test("Without MAL and AniList number an entry drops out; an empty list is an error")
    func condensed() throws {
        #expect(try index().tvdb.count == 3)
        #expect(throws: (any Error).self) { try AnimeMapping.Index(raw: Data("[]".utf8), asOf: Date()) }
    }

    @Test("First time: the query waits for loading; afterwards the list is on disk")
    func firstLoad() async throws {
        let location = folder()
        let fetches = Mutex(0)
        let z = AnimeMapping(
            folder: location,
            fetch: { _ in
                fetches.withLock { $0 += 1 }
                return Self.list
            })
        #expect(await z.entry(tvdb: "468193", tmdb: nil, imdb: nil)?.mal == 48317)
        // A second program reads from disk without fetching.
        let second = AnimeMapping(
            folder: location,
            fetch: { _ in
                Issue.record("geholt"); return Data()
            })
        #expect(await second.entry(tvdb: "61493", tmdb: nil, imdb: nil)?.mal == 27)
        #expect(fetches.withLock { $0 } == 1)
    }

    @Test("Stale: the old list keeps answering while the new one loads — and stays if that fails")
    func oldOneStays() async throws {
        let location = folder()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await AnimeMapping(folder: location, fetch: { _ in Self.list }, now: { start })
            .entry(tvdb: "61493", tmdb: nil, imdb: nil)

        // Eight days later, and the network is gone.
        let later = start.addingTimeInterval(8 * 24 * 3600)
        let attempted = Mutex(0)
        let z = AnimeMapping(
            folder: location,
            fetch: { _ in
                attempted.withLock { $0 += 1 }
                throw URLError(.notConnectedToInternet)
            }, now: { later })
        #expect(await z.entry(tvdb: "468193", tmdb: nil, imdb: nil)?.mal == 48317)
        try await Task.sleep(for: .milliseconds(100))
        // After the failed fetch: the same answer, and no new attempt immediately.
        #expect(await z.entry(tvdb: "468193", tmdb: nil, imdb: nil)?.mal == 48317)
        try await Task.sleep(for: .milliseconds(100))
        #expect(attempted.withLock { $0 } == 1)
    }

    @Test("Stale and the network is there: the new list replaces the old one only once it is read")
    func newOneReplaces() async throws {
        let location = folder()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await AnimeMapping(folder: location, fetch: { _ in Self.list }, now: { start })
            .entry(tvdb: "61493", tmdb: nil, imdb: nil)

        let fresh = Data(
            #"[{"type":"TV","mal_id":1,"anilist_id":1,"tvdb_id":468193,"season":{"tvdb":1}}]"#.utf8)
        let z = AnimeMapping(
            folder: location, fetch: { _ in fresh }, now: { start.addingTimeInterval(8 * 24 * 3600) })
        // The first query is answered by the old list.
        #expect(await z.entry(tvdb: "468193", tmdb: nil, imdb: nil)?.mal == 48317)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await z.entry(tvdb: "468193", tmdb: nil, imdb: nil)?.mal == 1)
    }
}

@Suite("MAL rating")
struct MALClientTests {

    @Test("Rating, votes and rank from the response")
    func reads() throws {
        let json = #"{"id":41882,"mean":8.73,"num_scoring_users":853214,"rank":4}"#
        #expect(try MALClient.parse(Data(json.utf8)) == .init(score: 8.73, voices: 853214, rank: 4))
    }

    @Test("Without `mean` — announced or too few votes — no rating, no error")
    func withoutRating() throws {
        #expect(try MALClient.parse(Data(#"{"id":74925,"num_scoring_users":1}"#.utf8)) == nil)
        #expect(try MALClient.parse(Data(#"{"id":1,"mean":0}"#.utf8)) == nil)
    }

    @Test("Only the three fields are asked for")
    func address() {
        let url = MALClient.address(forItem: 41882).absoluteString
        #expect(url == "https://api.myanimelist.net/v2/anime/41882?fields=mean,num_scoring_users,rank")
    }
}

@Suite("Anime request")
struct AnimeQueryTests {

    @Test("Series and movie ask, an episode never — it carries the episode's TVDB number")
    func onlySeriesAndMovie() {
        var series = MediaItem(id: "s", kind: .series, title: "Northmark Saga")
        series.ratings.tvdbID = "468193"
        #expect(AnimeQuery.from(series) == AnimeQuery(tvdb: "468193", tmdb: nil, imdb: nil))

        var episode = MediaItem(id: "f", kind: .episode, title: "Episode 1")
        episode.ratings.tvdbID = "8232417"
        #expect(AnimeQuery.from(episode) == nil)

        // Without any identifier there is nothing to ask.
        #expect(AnimeQuery.from(MediaItem(id: "x", kind: .series, title: "Filmhub")) == nil)
    }
}
