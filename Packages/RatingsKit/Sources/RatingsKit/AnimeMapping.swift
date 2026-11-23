import Core
import Foundation

/// Which entry at MyAnimeList and AniList belongs to a series **and season**.
///
/// **Why a list and not the identifier from the Jellyfin server** (AP68, 2026-10-06): MAL and
/// AniList keep each season as its own entry, Jellyfin and TMDb one series with
/// seasons. Jellyfin's AniList plugin therefore often guesses wrong — of eleven
/// anime series, eight pointed to the wrong entry: Hisvei Weprir to the 2000 film,
/// Kliasou Magla to the "Rewrite" special, Ciokrou Liklo to the second season. Rating and
/// German voices then came from the wrong title.
///
/// **The list is `Fribb/anime-lists`** (`anime-list-full.json`, 7.5 MB, maintained daily):
/// TVDB, TMDb and IMDb number plus season → MAL and AniList number. The app fetches it
/// itself — it has to manage without the CL-Server (product decision 2026-10-07) — and keeps only
/// what carries an identifier to the outside: around 8,500 of almost 40,000 entries.
///
/// **The old list stays until the new one is there** (requirement 2026-10-07: ratings must not
/// all vanish while the new list is loading). If the list is older than
/// ``maxAge``, it is fetched again in the background; until then the old one answers, and
/// if fetching fails, it simply stays. Only the very first time is there nothing
/// to fall back on — then the first query waits for the load.
public actor AnimeMapping {

    /// What the mapping knows about a title.
    public struct ContentEntryRecord: Sendable, Equatable, Codable {
        public let mal: Int?
        public let anilist: Int?

        public init(mal: Int?, anilist: Int?) {
            self.mal = mal
            self.anilist = anilist
        }
    }

    /// Where the list comes from.
    public static let source = URL(
        string: "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json")!

    /// How old the list may get before it is fetched again in the background.
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    /// How long after a failed fetch no new attempt starts — otherwise, without network, every
    /// detail page would try to pull 7.5 MB again.
    public static let pause: TimeInterval = 10 * 60

    /// Fetches the raw data — replaceable for checks.
    public typealias Fetcher = @Sendable (URL) async throws -> Data

    private let file: URL
    private let fetch: Fetcher
    private let now: @Sendable () -> Date

    private var index: Index?
    private var read = false
    private var running: Task<Index?, Never>?
    private var failed: Date?

    /// - Parameters:
    ///   - folder: where the condensed list lies — the default is the cache, because
    ///     it can be fetched again at any time
    ///   - fetch: the retrieval of the raw data
    ///   - now: the clock, replaceable for checks
    public init(
        folder: URL? = nil,
        fetch: Fetcher? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let base =
            folder
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "cinelounge.animezuordnung")
        self.file = base.appending(path: "zuordnung.json")
        self.fetch = fetch ?? { address in try await URLSession.shared.data(from: address).0 }
        self.now = now
    }

    /// The entry for a series season — via TVDB, otherwise TMDb.
    ///
    /// - Parameters:
    ///   - tvdb: the series' TVDB number (Jellyfin)
    ///   - tmdb: the TMDb identifier including kind, `tv/88803` or `movie/372058` (IPTV, CL-Server)
    ///   - imdb: the IMDb identifier — reliable only for films, series rarely carry it
    ///   - staffel: which season; a series as a whole shows the first
    public func entry(
        tvdb: String?, tmdb: String?, imdb: String?, season: Int = 1
    ) async -> ContentEntryRecord? {
        guard let index = await current() else { return nil }
        return index.search(tvdb: tvdb, tmdb: tmdb, imdb: imdb, season: season)
    }

    /// The list used to answer — and the trigger for refreshing.
    private func current() async -> Index? {
        if !read {
            read = true
            index = loadIndex()
        }
        if let index {
            if now().timeIntervalSince(index.asOf) > Self.maxAge { fresh() }
            return index
        }
        fresh()
        return await running?.value
    }

    /// Fetches the list again unless a fetch is already running. The old one stays until the swap.
    private func fresh() {
        guard running == nil else { return }
        if let failed, now().timeIntervalSince(failed) < Self.pause { return }
        let fetch = fetch
        let asOf = now()
        running = Task.detached(priority: .utility) {
            do {
                let raw = try await fetch(AnimeMapping.source)
                let fresh = try Index(raw: raw, asOf: asOf)
                return fresh
            } catch {
                Diagnostics.network.error(
                    "Anime mapping: list not fetched — \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        Task { await adopt() }
    }

    private func adopt() async {
        guard let fresh = await running?.value else {
            running = nil
            failed = now()
            return
        }
        index = fresh
        running = nil
        failed = nil
        write(fresh)
        Diagnostics.step(
            "Anime mapping: \(fresh.count) entries adopted", since: nil, area: "Bewertung")
    }

    private func loadIndex() -> Index? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Index.self, from: data)
    }

    private func write(_ index: Index) {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(index).write(to: file, options: .atomic)
        } catch {
            Diagnostics.network.error(
                "Anime mapping: not saved — \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - The index

extension AnimeMapping {

    /// One row of the condensed list.
    struct Row: Sendable, Codable, Equatable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case kind = "art"
            case tvdbSeason = "tvdbStaffel"
            case tmdbSeason = "tmdbStaffel"
            case mal
            case anilist
        }

        let kind: String?
        let tvdbSeason: Int?
        let tmdbSeason: Int?
        let mal: Int?
        let anilist: Int?

        var entry: ContentEntryRecord { ContentEntryRecord(mal: mal, anilist: anilist) }
        var series: Bool { kind == "TV" || kind == "ONA" }
    }

    /// The condensed list, ordered by identifier.
    struct Index: Sendable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case asOf = "stand"
            case tvdb
            case tmdbSeries = "tmdbSerie"
            case tmdbFilm
            case imdb
        }

        var asOf: Date
        var tvdb: [Int: [Row]] = [:]
        var tmdbSeries: [Int: [Row]] = [:]
        var tmdbFilm: [Int: [Row]] = [:]
        var imdb: [String: [Row]] = [:]

        var count: Int { tvdb.count + tmdbSeries.count + tmdbFilm.count + imdb.count }

        /// From the raw list — whatever neither MAL nor AniList knows or that carries no identifier to
        /// the outside is dropped.
        init(raw: Data, asOf: Date) throws {
            self.asOf = asOf
            let list = try JSONDecoder().decode([Raw].self, from: raw)
            for raw in list where raw.mal != nil || raw.anilist != nil {
                let row = Row(
                    kind: raw.kind, tvdbSeason: raw.season?.tvdb, tmdbSeason: raw.season?.tmdb,
                    mal: raw.mal, anilist: raw.anilist)
                if let id = raw.tvdb { tvdb[id, default: []].append(row) }
                if let id = raw.tmdb?.tv { tmdbSeries[id, default: []].append(row) }
                for id in raw.tmdb?.movie ?? [] { tmdbFilm[id, default: []].append(row) }
                for id in raw.imdb ?? [] { imdb[id, default: []].append(row) }
            }
            guard count > 0 else { throw CocoaError(.coderValueNotFound) }
        }

        func search(tvdb: String?, tmdb: String?, imdb: String?, season: Int) -> ContentEntryRecord? {
            if let id = tvdb.flatMap(Int.init), let rows = self.tvdb[id],
                let match = Self.season(season, in: rows, after: \.tvdbSeason)
            {
                return match.entry
            }
            if let tmdb {
                let split = tmdb.split(separator: "/")
                if split.count == 2, let id = Int(split[1]) {
                    if split[0] == "tv", let rows = tmdbSeries[id],
                        let match = Self.season(season, in: rows, after: \.tmdbSeason)
                    {
                        return match.entry
                    }
                    if split[0] == "movie", let match = tmdbFilm[id]?.first { return match.entry }
                }
            }
            // The IMDb number carries no season: It counts only for a film or a
            // series that is a single entry at MAL.
            if let imdb, let rows = self.imdb[imdb] {
                if let film = rows.first(where: { $0.kind == "MOVIE" }) { return film.entry }
                let allSeries = rows.filter(\.series)
                if allSeries.count == 1 { return allSeries[0].entry }
            }
            return nil
        }

        /// A season's row. **Season 0 is films and specials** — the Hisvei Weprir film
        /// of 2000 hangs on the same TVDB number as the series and must never stand in for it.
        /// Long series without seasons (Hisvei Weprir, Badausjus) carry no season value; they
        /// apply to every season.
        static func season(_ season: Int, in rows: [Row], after field: KeyPath<Row, Int?>) -> Row? {
            let allSeries = rows.filter(\.series)
            return allSeries.first { $0[keyPath: field] == season }
                ?? allSeries.first { $0[keyPath: field] == nil }
                ?? allSeries.filter { ($0[keyPath: field] ?? 0) > 0 }
                .min { ($0[keyPath: field] ?? 0) < ($1[keyPath: field] ?? 0) }
        }
    }

    /// An entry of the raw list, with only the fields that are needed.
    struct Raw: Decodable {
        struct Season: Decodable {
            let tvdb: Int?
            let tmdb: Int?
        }
        /// `{"tv": 88803}` or `{"movie": [372058]}`.
        struct TMDb: Decodable {
            let tv: Int?
            let movie: [Int]?
        }
        let kind: String?
        let mal: Int?
        let anilist: Int?
        let tvdb: Int?
        let tmdb: TMDb?
        let imdb: [String]?
        let season: Season?

        enum CodingKeys: String, CodingKey {
            case kind = "type"
            case mal = "mal_id"
            case anilist = "anilist_id"
            case tvdb = "tvdb_id"
            case tmdb = "themoviedb_id"
            case imdb = "imdb_id"
            case season = "season"
        }
    }
}
