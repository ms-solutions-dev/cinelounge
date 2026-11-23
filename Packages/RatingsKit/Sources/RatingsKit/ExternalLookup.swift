import Foundation

/// What the external services know about a title — **asked once, for both programs**
/// (AP58 R6, St5).
///
/// **Before, rebuilt per program** (report A): The TV's detail page asked
/// OMDb, AniList rating and German voices side by side, the phone
/// (`ExternalRatingsSource`) did the same again with branches of its own. Both fetched the TMDb
/// portraits with the same cap and the same window, written twice.
///
/// **The errors come back too** and are not swallowed: The phone writes them
/// to the error log, the TV to the trace. This package knows neither.
public enum ExternalLookup {

    /// What a search at TMDb needs when the title carries no identifier.
    public struct TitleSearch: Sendable, Equatable {
        public let title: String
        public let year: Int
        public let series: Bool

        public init(title: String, year: Int, series: Bool) {
            self.title = title
            self.year = year
            self.series = series
        }
    }

    /// What was fetched. `nil` means "not asked" (no identifier, no access).
    public struct State: Sendable {
        public var omdb: Result<ExternalRatings, any Error>?
        /// The MAL rating — `nil` means not asked (no anime, no access), `.success(nil)`
        /// asked, but without a rating.
        public var mal: Result<MALClient.Rating?, any Error>?
        public var voices: Result<GermanVoices, any Error>?
        /// What TMDb knows about the title — only if it carries a TMDb identifier (2026-09-29).
        public var tmdb: Result<TitleInfo, any Error>? = nil

        /// The German voices — empty if not asked or failed.
        public var voicesOrEmpty: GermanVoices {
            (try? voices?.get()) ?? GermanVoices(byCharacter: [:])
        }

        /// All errors, with the service in front — for the log.
        public var error: [(service: String, error: any Error)] {
            var list: [(String, any Error)] = []
            if case .failure(let f) = omdb { list.append(("OMDb", f)) }
            if case .failure(let f) = mal { list.append(("MAL", f)) }
            if case .failure(let f) = tmdb { list.append(("TMDb", f)) }
            if case .failure(let f) = voices { list.append(("AniList-Stimmen", f)) }
            return list
        }
    }

    /// **Side by side** — three different counterparts, none knows about the others.
    ///
    /// **Anime via the mapping** (AP68, 2026-10-07): If ``AnimeMapping`` knows the title,
    /// the season's MAL rating comes, and the mapping's AniList number beats the
    /// one brought along — Jellyfin's plugin guesses wrong for eight of eleven series, and the
    /// German voices then came from the wrong title. Nobody asks for the AniList rating any more.
    ///
    /// **If the IMDb identifier is missing but a TMDb identifier is there** (2026-09-29), it is
    /// looked up at TMDb first — IPTV and CL-Server titles mostly carry only that.
    /// The information goes back with it (``State/tmdb``), so the detail view can take image and
    /// description where the title has none.
    public static func fetch(
        imdb: String?, anilist: String?, omdb omdbClient: OMDbClient?,
        anilistClient: AniListClient?, tmdb: String? = nil, tmdbClient: TMDbClient? = nil,
        search: TitleSearch? = nil, tvdb: String? = nil, season: Int = 1,
        anime: AnimeRating? = nil
    ) async -> State {
        // **Without an IMDb and TMDb identifier a search is made** (2026-09-29) — by title and year,
        // and only an unambiguous hit counts (``TMDbClient/search(title:year:series:)``).
        var tmdb = tmdb
        if tmdb == nil, imdb == nil, let tmdbClient, let search {
            tmdb = try? await tmdbClient.search(title: search.title, year: search.year, series: search.series)
        }
        let info: Result<TitleInfo, any Error>? = await { [tmdb] in
            guard let tmdbClient, let tmdb else { return nil }
            do { return .success(try await tmdbClient.title(tmdb)) } catch { return .failure(error) }
        }()
        let imdb = imdb ?? (try? info?.get())?.imdbID
        let entry = await anime?.assignment.entry(tvdb: tvdb, tmdb: tmdb, imdb: imdb, season: season)
        let anilist = entry?.anilist.map(String.init) ?? anilist
        let malClient = await anime?.mal()
        async let omdb: Result<ExternalRatings, any Error>? = {
            guard let omdbClient, let imdb else { return nil }
            do { return .success(try await omdbClient.ratings(forIMDbID: imdb)) } catch {
                return .failure(error)
            }
        }()
        async let note: Result<MALClient.Rating?, any Error>? = {
            guard let malClient, let id = entry?.mal else { return nil }
            do { return .success(try await malClient.rating(forItem: id)) } catch { return .failure(error) }
        }()
        async let voices: Result<GermanVoices, any Error>? = {
            guard let anilistClient, let anilist else { return nil }
            do { return .success(try await anilistClient.germanVoices(forAniListID: anilist)) } catch {
                return .failure(error)
            }
        }()
        return State(omdb: await omdb, mal: await note, voices: await voices, tmdb: info)
    }

    /// At most this many portraits are fetched — **the front of the cast.** Whoever
    /// stands further back rarely comes into view in a horizontal row.
    public static let maxPortraits = 12

    /// This many queries run at once — fast enough, without overrunning TMDb with twelve at a
    /// time.
    public static let concurrentPortraits = 4

    /// Portraits **by name**, for sources without person images of their own.
    public static func portraits(
        zu names: [String], from tmdb: TMDbClient,
        atMost: Int = maxPortraits, concurrently: Int = concurrentPortraits
    ) async -> [String: URL] {
        let pending = Array(names.prefix(atMost))
        var found: [String: URL] = [:]
        await withTaskGroup(of: (String, URL?).self) { group in
            var next = 0
            func configure() {
                guard next < pending.count else { return }
                let name = pending[next]
                next += 1
                group.addTask { (name, try? await tmdb.portraitURL(forPersonNamed: name)) }
            }
            for _ in 0..<min(concurrently, pending.count) { configure() }
            for await (name, address) in group {
                if let address { found[name] = address }
                configure()
            }
        }
        return found
    }
}
