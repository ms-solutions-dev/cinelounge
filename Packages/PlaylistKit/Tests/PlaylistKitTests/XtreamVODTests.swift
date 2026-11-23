import Core
import Foundation
import Testing

@testable import PlaylistKit

/// Checked against what Xtream panels actually answer.
///
/// The examples are built in and are not fetches: this parsing runs on every build,
/// and a test that depends on the network fails for no reason sooner or later — then
/// nobody believes it any more.
///
/// Each case below stands for a notation that really exists in these panels: numbers
/// as strings, missing file extensions, `0` as "unknown", empty lists where objects
/// should be.
@Suite("Xtream: parsing movies and series")
struct XtreamVODTests {

    let account = XtreamEndpoint(
        server: URL(string: "http://panel.example:8080")!,
        username: "benutzer",
        password: "geheim"
    )

    func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    // MARK: - Sparten

    @Test("Categories are read with identifier and name")
    func categories() throws {
        let data = json(
            """
            [{"category_id":"12","category_name":"Action"},
             {"category_id":13,"category_name":"Doku"}]
            """
        )

        let categories = try XtreamVOD.categories(from: data)

        // The second section carries its identifier as a number instead of a string — the
        // same panel, the same response, two notations.
        #expect(categories.map(\.id) == ["12", "13"])
        #expect(categories.map(\.name) == ["Action", "Doku"])
    }

    @Test("A rejected sign-in counts as an error, not as an empty library")
    func rejectedLogin() {
        // With a wrong password the panels answer with an object instead of the list.
        // Letting that pass as "no films available" would send the viewer looking for a
        // fault on their own side.
        let data = json(#"{"user_info":{"auth":0},"server_info":{}}"#)

        #expect(throws: XtreamVOD.Failure.unexpectedShape) {
            try XtreamVOD.movies(from: data)
        }
    }

    @Test("An error page instead of JSON is reported as such")
    func htmlInsteadOfJSON() {
        let data = json("<html><body>502 Bad Gateway</body></html>")

        #expect(throws: XtreamVOD.Failure.notJSON) {
            try XtreamVOD.movies(from: data)
        }
    }

    // MARK: - Filme

    @Test("An ordinary movie is read completely")
    func standardMovie() throws {
        let data = json(
            """
            [{"num":1,"name":"Lattice","stream_id":1234,
              "stream_icon":"http://bilder.example/lattice.jpg",
              "rating":"8.7","rating_5based":4.35,
              "added":"1583280000","category_id":"12",
              "container_extension":"mkv","releasedate":"1999-03-30",
              "genre":"Action, Science-Fiction","plot":"Die Welt ist eine Simulation."}]
            """
        )

        let movies = try XtreamVOD.movies(from: data, playlistID: "zugang")
        let film = try #require(movies.first)

        #expect(film.kind == .movie)
        #expect(film.title == "Lattice")
        #expect(film.year == 1999)
        #expect(film.genres == ["Action", "Science-Fiction"])
        #expect(film.overview == "Die Welt ist eine Simulation.")
        #expect(film.ratings.community == 8.7)
        #expect(film.artwork.posterID == "http://bilder.example/lattice.jpg")
        #expect(film.recordedAt == Date(timeIntervalSince1970: 1_583_280_000))

        // The container belongs to complete reading because without it playback fails and
        // not merely a piece of information is missing: MKV **raw** on the system player
        // means a black picture. At the checked provider 22900 of 27558 films are MKV —
        // since 2026-08-10 the app repackages them itself, but for that too the container has to
        // be known.
        let source = try #require(film.source)
        #expect(source.container == .mkv)
        #expect(PlaybackEngineSelector.decide(for: source).delivery == .remuxInApp)
    }

    @Test("An entry without stream_id is skipped, the others stay")
    func entryWithoutStreamID() throws {
        // Occurs with aborted entries in the panel. Without an identifier there is no
        // address — the entry is worthless, but the list is not.
        let data = json(
            """
            [{"name":"Ohne Kennung","container_extension":"mp4"},
             {"name":"Mit Kennung","stream_id":7,"container_extension":"mp4"},
             {"stream_id":8,"container_extension":"mp4"}]
            """
        )

        let movies = try XtreamVOD.movies(from: data, playlistID: "z")

        // The third drops out as well: a nameless film cannot be found again in a list of ten
        // thousand.
        #expect(movies.map(\.title) == ["Mit Kennung"])
    }

    @Test("A rating is read as text as well as a number")
    func ratingAsTextAndNumber() throws {
        let data = json(
            """
            [{"name":"Als Text","stream_id":1,"rating":"7.5"},
             {"name":"Als Zahl","stream_id":2,"rating":7.5},
             {"name":"Mit Komma","stream_id":3,"rating":"7,5"}]
            """
        )

        let movies = try XtreamVOD.movies(from: data)

        #expect(movies.map(\.ratings.community) == [7.5, 7.5, 7.5])
    }

    @Test("A rating of zero means unrated and not zero points")
    func zeroRating() throws {
        // `0` is the panels' default value. Shown as a rating it would claim something the
        // data do not give.
        let data = json(
            """
            [{"name":"A","stream_id":1,"rating":0},
             {"name":"B","stream_id":2,"rating":""},
             {"name":"C","stream_id":3,"rating":"N/A"}]
            """
        )

        let movies = try XtreamVOD.movies(from: data)

        #expect(movies.allSatisfy { $0.ratings.community == nil })
    }

    @Test("If a panel carries only five points it is scaled to ten")
    func fivePointScale() throws {
        let data = json(#"[{"name":"A","stream_id":1,"rating":"","rating_5based":4.25}]"#)

        #expect(try XtreamVOD.movies(from: data).first?.ratings.community == 8.5)
    }

    @Test("The release year is also read from a full date")
    func yearFromDate() throws {
        let data = json(
            """
            [{"name":"A","stream_id":1,"releasedate":"2014-11-05"},
             {"name":"B","stream_id":2,"releasedate":"2014"},
             {"name":"C","stream_id":3,"releasedate":""}]
            """
        )

        #expect(try XtreamVOD.movies(from: data).map(\.year) == [2014, 2014, nil])
    }

    @Test("An unusable image value yields no poster")
    func unusableArtwork() throws {
        // Empty strings and placeholders without a scheme occur constantly. Used as an
        // address they would produce an empty tile instead of the fallback.
        let data = json(
            """
            [{"name":"A","stream_id":1,"stream_icon":""},
             {"name":"B","stream_id":2,"stream_icon":"kein-bild.png"},
             {"name":"C","stream_id":3,"stream_icon":"https://b.example/c.png"}]
            """
        )

        let posters = try XtreamVOD.movies(from: data).map(\.artwork.posterID)

        #expect(posters == [nil, nil, "https://b.example/c.png"])
    }

    @Test("The same movie from two accesses stays two entries")
    func playlistIDInIdentifier() throws {
        let data = json(#"[{"name":"Lattice","stream_id":1234,"container_extension":"mkv"}]"#)

        let first = try #require(XtreamVOD.movies(from: data, playlistID: "a").first)
        let second = try #require(XtreamVOD.movies(from: data, playlistID: "b").first)

        #expect(first.id != second.id)
    }

    // MARK: - Adressen

    @Test("The movie address contains identifier and file extension")
    func movieAddress() throws {
        let data = json(#"[{"name":"Lattice","stream_id":1234,"container_extension":"mkv"}]"#)
        let film = try #require(XtreamVOD.movies(from: data, playlistID: "z").first)

        let url = XtreamVOD.playbackURL(for: film.id, account: account)

        #expect(
            url?.absoluteString == "http://panel.example:8080/movie/benutzer/geheim/1234.mkv"
        )
    }

    @Test("Without container_extension mp4 is assumed")
    func missingContainerExtension() throws {
        // Quite a few panels leave the field out or write it empty. Omitting the extension
        // altogether would be the worse way — some panels answer that with 404.
        let data = json(
            """
            [{"name":"Ohne Feld","stream_id":1},
             {"name":"Leeres Feld","stream_id":2,"container_extension":""}]
            """
        )

        let movies = try XtreamVOD.movies(from: data)
        let urls = movies.map {
            XtreamVOD.playbackURL(for: $0.id, account: account)?.lastPathComponent
        }

        #expect(urls == ["1.mp4", "2.mp4"])

        // The address guesses `mp4`, the container nevertheless stays unknown — and that is
        // intentional: a wrongly guessed container would be a promise to the engine that
        // nobody keeps. Since the VLC removal (2026-08-16) the system engine decides for the
        // unknown as well.
        #expect(movies.allSatisfy { $0.source?.container == .unknown })
        // **And the delivery path is the statement, not the engine.** Since the VLC removal
        // there is only one engine; "goes to the native one" has been true from then on,
        // whatever is in the list (AP8, added 2026-09-02).
        #expect(
            movies.allSatisfy {
                guard let source = $0.source else { return false }
                return PlaybackEngineSelector.decide(for: source).delivery == .directPlay
            }
        )
    }

    @Test("An extension with a dot and in upper case is normalized")
    func normalizedExtension() throws {
        let data = json(#"[{"name":"A","stream_id":9,"container_extension":".MKV"}]"#)
        let film = try #require(XtreamVOD.movies(from: data).first)

        #expect(XtreamVOD.playbackURL(for: film.id, account: account)?.lastPathComponent == "9.mkv")
    }

    @Test("A special character in the password does not cut the address")
    func passwordWithSpecialCharacter() {
        // A `#` in the password turned everything after it into an anchor — the address
        // pointed to the user's directory instead of the film.
        let account = XtreamEndpoint(
            server: URL(string: "http://panel.example:8080")!,
            username: "u",
            password: "pa#ss"
        )

        let url = XtreamVOD.movieURL(streamID: "5", containerExtension: "mp4", account: account)

        #expect(url?.absoluteString == "http://panel.example:8080/movie/u/pa%23ss/5.mp4")
        #expect(url?.fragment == nil)
    }

    @Test("A series itself has no playback address")
    func seriesHasNoAddress() throws {
        let data = json(#"[{"series_id":42,"name":"Nachtfalter"}]"#)
        let series = try #require(XtreamVOD.series(from: data, playlistID: "z").first)

        #expect(XtreamVOD.playbackURL(for: series.id, account: account) == nil)
    }

    @Test("An entry identifier can be taken apart again")
    func referenceRoundTrip() throws {
        // Even when the list identifier itself contains a hash sign: the split looks for the
        // kind from the back.
        let reference = XtreamVOD.Reference(
            playlistID: "liste#mit#kreuz",
            role: .episode,
            id: "3311",
            containerExtension: "MP4"
        )

        let restored = try #require(XtreamVOD.Reference(itemID: reference.itemID))

        #expect(restored == reference)
        #expect(restored.playlistID == "liste#mit#kreuz")
        #expect(restored.containerExtension == "mp4")
    }

    @Test("A foreign identifier yields no address")
    func foreignIdentifier() {
        #expect(XtreamVOD.Reference(itemID: "irgendein-jellyfin-titel") == nil)
        #expect(XtreamVOD.playbackURL(for: "irgendein-jellyfin-titel", account: account) == nil)
    }

    // MARK: - Filmdetails

    @Test("The detail response fills plot, runtime and cast")
    func movieDetail() throws {
        let data = json(
            """
            {"info":{"tmdb_id":"8603","name":"Lattice",
                     "plot":"Orrin erfährt die Wahrheit.",
                     "cast":"Darian Kell, Mara-Lynn Holt",
                     "director":"Rhea Tallis / Ione Tallis",
                     "genre":"Action, Science-Fiction",
                     "releasedate":"1999-03-30","duration_secs":"8160",
                     "duration":"02:16:00","rating":"8.7",
                     "movie_image":"http://bilder.example/lattice.jpg"},
             "movie_data":{"stream_id":1234,"name":"Lattice",
                           "container_extension":"mkv","added":"1583280000"}}
            """
        )

        let detail = try XtreamVOD.movieDetail(from: data, playlistID: "z")
        let film = try #require(detail)

        #expect(film.title == "Lattice")
        #expect(film.overview == "Orrin erfährt die Wahrheit.")
        #expect(film.runtime == 8160)
        #expect(film.ratings.community == 8.7)
        // Director first, then the cast in the panel's order — there the leads come first.
        #expect(
            film.cast.map(\.name) == [
                "Rhea Tallis", "Ione Tallis", "Darian Kell", "Mara-Lynn Holt",
            ])
        #expect(film.cast.first?.role == .director)
        // The identifier contains the file extension so that the address can later be built
        // from it alone.
        #expect(
            XtreamVOD.playbackURL(for: film.id, account: account)?.lastPathComponent == "1234.mkv"
        )
    }

    /// 2026-09-29: the identifiers stay — ``Core/Ratings/tmdbID`` has existed since then,
    /// and through it the detail view finds IMDb, Rotten Tomatoes and Metacritic values.
    @Test("The detail response keeps the TMDb and IMDb identifier")
    func tmdbStays() throws {
        let data = json(
            #"{"info":{"tmdb_id":"8603","imdb_id":"tt3660047"},"movie_data":{"stream_id":1}}"#
        )

        let detail = try XtreamVOD.movieDetail(from: data)
        let film = try #require(detail)

        #expect(film.ratings.tmdbID == "movie/8603")
        #expect(film.ratings.imdbID == "tt3660047")
        #expect(film.ratings.isEmpty, "identifiers are not a rating")
    }

    @Test("“0” and empty are no TMDb identifier")
    func tmdbEmpty() {
        #expect(Ratings.tmdbIdentifier("0", series: false) == nil)
        #expect(Ratings.tmdbIdentifier("", series: true) == nil)
        #expect(Ratings.tmdbIdentifier(" 7399 ", series: true) == "tv/7399")
    }

    @Test("If the panel does not know the movie nothing comes back")
    func unknownMovie() throws {
        // Instead of an error the panels answer with empty **lists** at places where objects
        // otherwise stand. Whoever expects an object there crashes or fails on the whole
        // response.
        let data = json(#"{"info":[],"movie_data":[]}"#)

        #expect(try XtreamVOD.movieDetail(from: data) == nil)
    }

    @Test("If duration_secs is missing the clock notation is read")
    func durationFromClock() throws {
        let data = json(
            #"{"info":{"duration_secs":0,"duration":"01:59:30"},"movie_data":{"stream_id":1}}"#
        )

        #expect(try XtreamVOD.movieDetail(from: data)?.runtime == 7170)
    }

    @Test("If both durations contradict each other the clock time applies")
    func durationClockBeatsSeconds() throws {
        // Measured at the real provider: `duration_secs` carries **minutes** there, in the
        // same response in which `duration` gives a time of day — `"90"` next to
        // `"01:30:00"`. Whoever believes the field name shows "1 min" for every film, and the
        // progress bar is at its end after one second.
        //
        // Giving the time of day priority costs nothing where both are right: for the series
        // episodes of the same provider 2707 and 00:45:07 stand side by side.
        let data = json(
            #"{"info":{"duration_secs":"90","duration":"01:30:00"},"movie_data":{"stream_id":1}}"#
        )

        #expect(try XtreamVOD.movieDetail(from: data)?.runtime == 5400)
    }

    // MARK: - Serien

    @Test("A series is carried as a series and without a file extension")
    func standardSeries() throws {
        let data = json(
            """
            [{"series_id":"42","name":"Nachtfalter","cover":"http://bilder.example/nachtfalter.jpg",
              "plot":"Vier Familien.","genre":"Mystery, Drama","rating":"8.8",
              "releaseDate":"2017-12-01","backdrop_path":["http://bilder.example/dark-bg.jpg"]}]
            """
        )

        let series = try #require(XtreamVOD.series(from: data, playlistID: "z").first)

        #expect(series.kind == .series)
        #expect(series.title == "Nachtfalter")
        #expect(series.year == 2017)
        #expect(series.genres == ["Mystery", "Drama"])
        #expect(series.ratings.community == 8.8)
        #expect(series.artwork.posterID == "http://bilder.example/nachtfalter.jpg")
        // `backdrop_path` is a list, the other image fields are single addresses. Both occur
        // in the same response.
        #expect(series.artwork.backdropID == "http://bilder.example/dark-bg.jpg")
    }

    @Test("Series with several seasons keep the broadcast order")
    func seasonOrder() throws {
        // The classic mistake: sorting by the key as text. Then season 10 sits between 1 and
        // 2, and the episode list is unusable.
        let data = json(
            """
            {"info":{"name":"Nachtfalter"},
             "episodes":{
               "2":[{"id":"21","episode_num":1,"title":"S2E1"}],
               "10":[{"id":"101","episode_num":1,"title":"S10E1"}],
               "1":[{"id":"11","episode_num":1,"title":"S1E1"}]}}
            """
        )

        let episodes = try XtreamVOD.episodes(from: data, seriesID: "42", playlistID: "z")

        #expect(episodes.map(\.title) == ["S1E1", "S2E1", "S10E1"])
        #expect(episodes.map(\.seasonNumber) == [1, 2, 10])
    }

    @Test("Within a season the episode number decides")
    func episodeOrderWithinSeason() throws {
        // The panels deliver sorted by identifier, and the identifiers follow the order of
        // ingestion — not that of broadcast. The numbers arrive either as a number or as a
        // string.
        let data = json(
            """
            {"episodes":{"1":[
               {"id":"3","episode_num":"10","title":"Zehn"},
               {"id":"1","episode_num":2,"title":"Zwei"},
               {"id":"2","episode_num":"1","title":"Eins"}]}}
            """
        )

        let episodes = try XtreamVOD.episodes(from: data, seriesID: "42")

        #expect(episodes.map(\.title) == ["Eins", "Zwei", "Zehn"])
        #expect(episodes.map(\.episodeNumber) == [1, 2, 10])
    }

    @Test("An empty episodes object yields an empty list, no error")
    func emptyEpisodes() throws {
        #expect(try XtreamVOD.episodes(from: json(#"{"episodes":{}}"#), seriesID: "1").isEmpty)
        // Without episodes PHP writes an empty list instead of the empty object.
        #expect(try XtreamVOD.episodes(from: json(#"{"episodes":[]}"#), seriesID: "1").isEmpty)
        // And some panels leave the field out entirely.
        #expect(try XtreamVOD.episodes(from: json(#"{"info":{}}"#), seriesID: "1").isEmpty)
    }

    @Test("Every episode knows its series, its season and its runtime")
    func episodeDetails() throws {
        let data = json(
            """
            {"info":{"name":"Nachtfalter"},
             "episodes":{"2":[
               {"id":"3311","episode_num":4,"title":"Doppelleben",
                "container_extension":"mp4",
                "info":{"duration_secs":"2820","plot":"Jonas sucht.",
                        "movie_image":"http://bilder.example/s2e4.jpg"}}]}}
            """
        )

        let episode = try #require(
            XtreamVOD.episodes(from: data, seriesID: "42", playlistID: "z").first
        )

        #expect(episode.kind == .episode)
        #expect(episode.parentTitle == "Nachtfalter")
        #expect(episode.seasonNumber == 2)
        #expect(episode.episodeNumber == 4)
        #expect(episode.runtime == 2820)
        #expect(episode.overview == "Jonas sucht.")
        #expect(episode.artwork.posterID == "http://bilder.example/s2e4.jpg")
        // The episode must be traceable to its series without comparing names — otherwise
        // the Home screen flips back and forth between the two.
        #expect(episode.seriesID == "z#series#42")
    }

    @Test("The address of an episode lies under series, not under episode")
    func episodeAddress() throws {
        // The procedure's notation: the episodes live under `/series/`.
        let data = json(
            #"{"episodes":{"1":[{"id":"3311","episode_num":1,"container_extension":"mkv"}]}}"#
        )
        let episode = try #require(XtreamVOD.episodes(from: data, seriesID: "42").first)

        let url = XtreamVOD.playbackURL(for: episode.id, account: account)

        #expect(
            url?.absoluteString == "http://panel.example:8080/series/benutzer/geheim/3311.mkv"
        )
    }

    @Test("The season key beats a wrong season field in the entry")
    func seasonKeyWins() throws {
        // Quite a few panels write `"season":0` throughout in the entry. After that every
        // episode would lie in a season 0.
        let data = json(
            #"{"episodes":{"3":[{"id":"1","episode_num":1,"season":0,"title":"A"}]}}"#
        )

        #expect(try XtreamVOD.episodes(from: data, seriesID: "42").first?.seasonNumber == 3)
    }

    @Test("An episode without an identifier is skipped, the others stay")
    func episodeWithoutIdentifier() throws {
        let data = json(
            """
            {"episodes":{"1":[
               {"episode_num":1,"title":"Ohne Kennung"},
               {"id":"2","episode_num":2,"title":"Mit Kennung"}]}}
            """
        )

        #expect(try XtreamVOD.episodes(from: data, seriesID: "42").map(\.title) == ["Mit Kennung"])
    }

    @Test("An episode without a title is kept")
    func episodeWithoutTitle() throws {
        // Unlike with films: an episode is named by season and number and is playable.
        // Dropping it would tear a gap into the count.
        let data = json(#"{"episodes":{"1":[{"id":"2","episode_num":7}]}}"#)

        let episodes = try XtreamVOD.episodes(from: data, seriesID: "42")

        #expect(episodes.count == 1)
        #expect(episodes.first?.episodeNumber == 7)
    }

    // MARK: - Umfang

    @Test("An empty response yields an empty list")
    func emptyResponses() throws {
        #expect(try XtreamVOD.movies(from: json("[]")).isEmpty)
        #expect(try XtreamVOD.series(from: json("[]")).isEmpty)
        #expect(try XtreamVOD.categories(from: json("[]")).isEmpty)
    }

    @Test("A library with ten thousand movies is read completely")
    func largeCatalogue() throws {
        // The order of magnitude is usual for these providers. The test establishes that
        // nothing is lost on the way and every identifier stays unique.
        let entries = (1...10000).map { index in
            """
            {"name":"Film \(index)","stream_id":\(index),"container_extension":"mp4",
             "rating":"\(Double(index % 100) / 10)"}
            """
        }
        let data = json("[\(entries.joined(separator: ","))]")

        let movies = try XtreamVOD.movies(from: data, playlistID: "gross")

        #expect(movies.count == 10000)
        #expect(Set(movies.map(\.id)).count == 10000)
    }

    /// **The path of progress** (user request 2026-08-15): remembered when reported, enriched
    /// when read, deleted through the unwatched mark — the same way back that the long
    /// press "Reset progress" takes.
    @Test("The state is remembered, applied and deleted via Unwatched")
    func positionSurvivesAndResets() async {
        let memory = VODMemory(store: InMemoryStore())
        let film = MediaItem(id: "vod#1", kind: .movie, title: "Hollowmark — Folge 1")

        await memory.setPosition(754, of: 1420, for: film.id)
        let resumed = await memory.enrich([film])
        #expect(resumed[0].progress?.position == 754)
        #expect(resumed[0].progress?.isResumable == true)

        // The way back: unwatched also means "from the start".
        await memory.setWatched(false, for: film.id)
        let cleared = await memory.enrich([film])
        #expect(cleared[0].progress == nil)
    }
}

/// At TMDb the image size is in the path — and was thrown away until now.
@Suite("Xtream image sizes")
struct XtreamImageSizeTests {

    private func address(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    /// **The finding of 2026-09-05:** the requested width was silently discarded, and every
    /// poster came in 600 × 900 — for a tile 103 points wide four to five times the
    /// bytes.
    @Test("The TMDb tier follows the requested width")
    func levelIsSet() throws {
        let raw = try address(
            "https://image.tmdb.org/t/p/w600_and_h900_bestv2/abc.jpg")
        #expect(
            XtreamVODSource.toWidth(raw, width: 320).absoluteString
                == "https://image.tmdb.org/t/p/w342/abc.jpg")
        #expect(
            XtreamVODSource.toWidth(raw, width: 90).absoluteString
                == "https://image.tmdb.org/t/p/w92/abc.jpg")
    }

    /// **Rounded up.** A step that is too small you see, one that is too large only costs
    /// bytes.
    @Test("Intermediate sizes round up")
    func roundedUp() {
        #expect(XtreamVODSource.tier(forItem: 200) == "w342")
        #expect(XtreamVODSource.tier(forItem: 342) == "w342")
        #expect(XtreamVODSource.tier(forItem: 343) == "w500")
        // Above the largest step it stays at w780 — `original` would be a multiple for
        // nothing.
        #expect(XtreamVODSource.tier(forItem: 4000) == "w780")
    }

    /// **Only at TMDb.** A provider that delivers its posters itself gets its address back
    /// unchanged — there a path segment means nothing, and a guessed intervention would
    /// lead to a fetch that never answers.
    @Test("Foreign addresses stay untouched")
    func foreignOnesStay() throws {
        let foreign = try address("https://beispiel.invalid/bilder/w600/abc.jpg")
        #expect(XtreamVODSource.toWidth(foreign, width: 320) == foreign)

        // Also at TMDb: without a recognisable step nothing is rewritten.
        let unusual = try address("https://image.tmdb.org/abc.jpg")
        #expect(XtreamVODSource.toWidth(unusual, width: 320) == unusual)
    }
}
