import Core
import Foundation

/// Fetches a person's career from TMDb.
///
/// **Why TMDb and not the Jellyfin server** (decision of 2026-08-08):
/// Jellyfin knows only its own catalog. To the question "where has this person
/// acted" exactly that would come back — and the attribute "is in my
/// library" would be meaningless, because then everything shown is in it. Only a
/// movie database can supply the complete career.
///
/// **Why TMDb and not OMDb**, where the ratings come from: OMDb keeps
/// titles, not people. AniList keeps people, but only in anime. TMDb is
/// the only one of the three that can answer the question at all — and it
/// answers it in **one** request: `combined_credits` returns films and
/// series together, with role, date, rating and poster.
///
/// **The path via the name is the weaker mapping, and that is accepted
/// deliberately:** The Jellyfin server keeps no TMDb identifier on an actor,
/// so there is nothing better. When names coincide, prominence decides
/// — TMDb orders its hits by it anyway, and the more famous bearer of a name
/// is by a wide margin the more likely one.
public actor TMDbClient: FilmographySource {

    public enum Failure: Error, Equatable {
        case noKey
        case notFound
        case unreachable

        public var messageKey: String {
            switch self {
            case .noKey: "error.tmdbNoKey"
            case .notFound: "error.tmdbNoPerson"
            case .unreachable: "error.unreachable"
            }
        }
    }

    /// The width at which posters are fetched.
    ///
    /// TMDb supplies fixed steps, not a free width. `w342` is the smallest
    /// that does not look soft on a TV; the next step (`w500`)
    /// would weigh double for a tile that is not 200 points wide.
    static let posterSize = "w342"

    /// TMDb's language code for the app language (`de` → `de-DE`); without a choice German, as before.
    public static func language(_ app: String?) -> String {
        switch app?.lowercased() {
        case "en": "en-US"
        case "tr": "tr-TR"
        default: "de-DE"
        }
    }

    private let apiKey: String
    private let language: String
    /// The app language as ISO 639-1 (`de` from `de-DE`) — for the videos in the trailer choice.
    public let languageCode: String
    private let session: URLSession
    private let store: any KeyValueStore

    /// Careers already fetched, by name.
    ///
    /// **Kept beyond the program run**, as with the ratings: A
    /// filmography changes in months. Whoever jumps back and
    /// forth in the cast row should not trigger two requests with every jump.
    private var cache: [String: Filmography] = [:]
    private var titleCache: [String: TitleInfo] = [:]
    /// **A file instead of the Keychain** for the title information (2026-09-29): The
    /// filmographies are few, titles will be hundreds — and none of them is secret.
    private let titleStore: any KeyValueStore

    public init(
        apiKey: String,
        language: String = "de-DE",
        store: any KeyValueStore = InMemoryStore(),
        titleStore: any KeyValueStore = FileStore()
    ) {
        self.apiKey = apiKey
        self.language = language
        self.languageCode = String(language.split(separator: "-").first ?? "de").lowercased()
        self.store = store
        self.titleStore = titleStore

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.urlCache = URLCache(
            memoryCapacity: 2 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024,
            diskPath: "cinelounge.filmography"
        )
        self.session = URLSession(configuration: config)
    }

    public func filmography(forPersonNamed name: String) async throws -> Filmography {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.notFound }
        guard !apiKey.isEmpty else { throw Failure.noKey }

        if let cached = cache[trimmed] { return cached }

        let personID = try await findPerson(named: trimmed)
        let result = try await credits(forPersonID: personID)

        cache[trimmed] = result
        return result
    }

    // MARK: - The two requests

    /// A person's portrait, searched by their **name**.
    ///
    /// **What for:** An Xtream provider supplies only cast *names* for its films and series,
    /// no images — the circles on the detail page stayed
    /// empty, while the same page shows faces with the Jellyfin server
    /// (user finding 2026-08-22). The name is enough, because this client already searches by it
    /// for the filmography anyway.
    ///
    /// **One request per person, and it is cached afterwards.** The same
    /// search also serves the filmography; whoever fetches the image first and the
    /// filmography later asks TMDb only once.
    public func portraitURL(forPersonNamed name: String, width: Int = 300) async throws -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.notFound }
        guard !apiKey.isEmpty else { throw Failure.noKey }

        if let cached = portraits[trimmed] { return cached }

        let match = try await bestMatch(for: trimmed)
        let url =
            match.profilePath.map { path in
                URL(string: Self.imageBase + "w\(width)" + path)
            } ?? nil

        portraits[trimmed] = url
        return url
    }

    /// Also remembers **not finding** — otherwise every focus movement asks again
    /// for a person TMDb does not know.
    private var portraits: [String: URL?] = [:]

    private func findPerson(named name: String) async throws -> Int {
        try await bestMatch(for: name).id
    }

    /// The one person search, used by both paths.
    private func bestMatch(for name: String) async throws -> PersonSearch.Match {
        let payload: PersonSearch = try await get(
            "search/person", query: [URLQueryItem(name: "query", value: name)])

        // **The more famous one wins.** TMDb orders by that anyway, but the
        // order is not guaranteed — and with "Slukli Wigle" (actor
        // and British presenter) it depends on whether the list is right.
        guard
            let best = payload.results.max(by: { ($0.popularity ?? 0) < ($1.popularity ?? 0) })
        else { throw Failure.notFound }

        return best
    }

    private func credits(forPersonID id: Int) async throws -> Filmography {
        let payload: CombinedCredits = try await get("person/\(id)/combined_credits")

        var movies: [FilmographyEntry] = []
        var series: [FilmographyEntry] = []

        // Only the cast entries. `crew` contains direction, camera, editing and
        // a dozen more trades — for an actor who produced once,
        // the list would be full of titles in which he is not
        // seen.
        for entry in payload.cast {
            guard let mapped = Self.entry(from: entry, posterBase: Self.imageBase) else { continue }
            switch mapped.kind {
            case .movie: movies.append(mapped)
            case .series: series.append(mapped)
            }
        }

        return Filmography(
            movies: Filmography.sorted(movies),
            series: Filmography.sorted(series)
        )
    }

    static let imageBase = "https://image.tmdb.org/t/p/"

    /// A row from an entry of the response — or nothing.
    ///
    /// What has no title is skipped: TMDb occasionally keeps
    /// records without names, and an empty row in the list looks like
    /// an app error.
    static func entry(from dto: CreditEntry, posterBase: String) -> FilmographyEntry? {
        let kind: FilmographyEntry.Kind = dto.mediaType == "tv" ? .series : .movie
        let title = (kind == .series ? dto.name : dto.title) ?? dto.title ?? dto.name
        guard let title, !title.isEmpty else { return nil }

        let dateText = (kind == .series ? dto.firstAirDate : dto.releaseDate) ?? ""
        // "2010-07-16" — the year is the first four characters. An empty field
        // means "date still open" and yields `nil`, not a zero.
        let year = Int(dateText.prefix(4))

        return FilmographyEntry(
            id: "\(kind == .series ? "tv" : "movie")-\(dto.id)",
            kind: kind,
            title: title,
            year: year,
            role: dto.character?.isEmpty == false ? dto.character : nil,
            // A rating without votes is none — TMDb then returns 0.0,
            // and that would stand as a devastating verdict where merely nobody
            // voted.
            rating: (dto.voteCount ?? 0) > 0 ? dto.voteAverage : nil,
            posterURL: dto.posterPath.flatMap {
                URL(string: posterBase + posterSize + $0)
            }
        )
    }

    // MARK: - Network path

    /// The short profile for an entry — one request, cast included.
    ///
    /// **`append_to_response=credits` instead of two retrievals.** The cast lies
    /// on a path of its own at TMDb; appended it costs no second
    /// request and no second wait. With a provider that has a counter this
    /// is no fine-tuning but half the quota.
    ///
    /// The identifier carries its kind in the name (`movie-603`, `tv-1399`) — it
    /// is created in ``entry(from:posterBase:)`` and taken apart again here.
    /// Two fields would be more honest; they would then stand in every row of the list,
    /// which does not need them.
    public func profile(for entry: FilmographyEntry) async throws -> TitleProfile? {
        guard let (kind, id) = Self.split(entry.id) else { return nil }
        // The videos come along (AP78): For a title that is not in the catalog, the
        // trailer is the only thing that can be played here.
        let payload: TitleDetail = try await get(
            "\(kind)/\(id)",
            query: [
                URLQueryItem(name: "append_to_response", value: "credits,videos"),
                URLQueryItem(name: "include_video_language", value: languageCode + ",en,null"),
            ])
        var videos = Self.videos(from: payload.videos)
        if let original = TrailerRule.missingOriginal(
            file: nil, videos: videos, appLanguage: languageCode, original: payload.originalLanguage),
            let more = try? await self.videos("\(kind)/\(id)", language: original)
        {
            videos += more
        }
        let trailer = TrailerRule.choice(
            file: nil, videos: videos, appLanguage: languageCode, original: payload.originalLanguage)
        return Self.profile(
            from: payload, fallback: entry, posterBase: Self.imageBase, trailer: trailer)
    }

    /// Splits `movie-603` into path and number. `nil` for anything else.
    static func split(_ id: String) -> (kind: String, number: Int)? {
        let parts = id.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let number = Int(parts[1]),
            parts[0] == "movie" || parts[0] == "tv"
        else { return nil }
        return (String(parts[0]), number)
    }

    static func profile(
        from dto: TitleDetail, fallback: FilmographyEntry, posterBase: String,
        trailer: TrailerChoice? = nil
    ) -> TitleProfile {
        let dateText = dto.releaseDate ?? dto.firstAirDate ?? ""
        return TitleProfile(
            // The row's title remains authoritative: It comes from the same
            // response as the list, and a differing name in the profile would look
            // as if something else had been opened.
            title: fallback.title,
            year: fallback.year ?? Int(dateText.prefix(4)),
            genres: (dto.genres ?? []).map(\.name),
            overview: dto.overview ?? "",
            // Six names: That many fit side by side, and whoever wants more
            // is looking for the detail page anyway, which does not exist here.
            cast: (dto.credits?.cast ?? []).prefix(6).map(\.name),
            posterURL: fallback.posterURL
                ?? dto.posterPath.flatMap { URL(string: posterBase + posterSize + $0) },
            rating: (dto.voteCount ?? 0) > 0 ? dto.voteAverage : fallback.rating,
            trailer: trailer
        )
    }

    /// `language` overrides the client's language — for the videos in a
    /// title's original language (``videos(_:language:)``).
    private func get<T: Decodable>(
        _ path: String, query: [URLQueryItem] = [], language languageCode: String? = nil
    ) async throws -> T {
        var components = URLComponents(string: "https://api.themoviedb.org/3/" + path)
        components?.queryItems =
            [
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "language", value: languageCode ?? language),
            ] + query
        guard let url = components?.url else { throw Failure.unreachable }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
            // 401 always means the same thing here: The key is no good. Reported as
            // "unreachable" it would send the user to the
            // connection although they need to check their entry.
            if http.statusCode == 401 { throw Failure.noKey }
            if http.statusCode == 404 { throw Failure.notFound }
            guard http.statusCode == 200 else { throw Failure.unreachable }

            return try JSONDecoder().decode(T.self, from: data)
        } catch let failure as Failure {
            throw failure
        } catch {
            Diagnostics.failure(url, step: "Fetch filmography", error: error)
            throw Failure.unreachable
        }
    }

    // MARK: - Response shapes

    struct PersonSearch: Decodable {
        let results: [Match]

        struct Match: Decodable {
            let id: Int
            let popularity: Double?
            /// The path to the portrait — **was thrown away until 2026-08-22**
            /// It comes with every person search anyway; fetching it
            /// costs no additional request.
            let profilePath: String?

            // **Spelled out, and here that is no decoration** (finding
            // 2026-08-22): This client decodes with a bare
            // `JSONDecoder` — **without** snake-case conversion. TMDb
            // writes `profile_path`; without this mapping the field stayed `nil`
            // for every person, and the diagnostics said "access present,
            // but the query returns nothing". The neighbouring structures list
            // their keys individually for the same reason.
            enum CodingKeys: String, CodingKey {
                case id
                case popularity
                case profilePath = "profile_path"
            }
        }
    }

    struct TitleDetail: Decodable {
        let overview: String?
        let posterPath: String?
        let releaseDate: String?
        let firstAirDate: String?
        let voteAverage: Double?
        let voteCount: Int?
        let genres: [Genre]?
        let credits: Credits?
        let originalLanguage: String?
        let videos: VideoListDTO?

        struct Genre: Decodable { let name: String }
        struct Credits: Decodable {
            let cast: [Member]
            struct Member: Decodable { let name: String }
        }

        enum CodingKeys: String, CodingKey {
            case overview
            case posterPath = "poster_path"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case voteAverage = "vote_average"
            case voteCount = "vote_count"
            case genres
            case credits
            case originalLanguage = "original_language"
            case videos
        }
    }

    struct CombinedCredits: Decodable {
        let cast: [CreditEntry]
    }

    struct CreditEntry: Decodable {
        let id: Int
        let mediaType: String?
        /// Set for films.
        let title: String?
        /// Set for series — TMDb names the same thing differently.
        let name: String?
        let releaseDate: String?
        let firstAirDate: String?
        let character: String?
        let voteAverage: Double?
        let voteCount: Int?
        let posterPath: String?

        enum CodingKeys: String, CodingKey {
            case id
            case mediaType = "media_type"
            case title
            case name
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case character
            case voteAverage = "vote_average"
            case voteCount = "vote_count"
            case posterPath = "poster_path"
        }
    }
}

// MARK: - A title

/// What TMDb knows about a film or series — **for titles without an IMDb identifier**
/// (2026-09-29).
///
/// IPTV providers and the CL-Server know the TMDb number, an IMDb identifier mostly not; OMDb
/// asks only via it, though. The detail view of these titles therefore stayed thin: no
/// IMDb, Rotten Tomatoes or Metacritic values, often no background image. One request
/// to TMDb supplies both — the IMDb identifier (for series via `external_ids`) and what
/// the title otherwise lacks.
public struct TitleInfo: Sendable, Equatable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case imdbID
        case backdrop = "hintergrund"
        case poster = "plakat"
        case description = "beschreibung"
        case genres
        case rating = "bewertung"
        case cast = "besetzung"
        case originalLang = "originalsprache"
        case videos
    }

    public let imdbID: String?
    public let backdrop: URL?
    public let poster: URL?
    public let description: String?
    public let genres: [String]
    public let rating: Double?
    /// Actors in TMDb's order, plus the director — **with image**, so the
    /// detail view needs no name search per person (2026-09-29).
    public let cast: [Contributor]
    /// The title's original language as ISO 639-1 — second step of the ``Core/TrailerRule``.
    public let originalLang: String?
    /// YouTube videos in app language and English, fetched along with the information (AP78). The
    /// original language is asked for separately by ``TrailerSource`` when it can decide.
    public let videos: [TrailerVideo]

    public init(
        imdbID: String?, backdrop: URL?, poster: URL?, description: String?,
        genres: [String], rating: Double?, cast: [Contributor] = [],
        originalLang: String? = nil, videos: [TrailerVideo] = []
    ) {
        self.imdbID = imdbID
        self.backdrop = backdrop
        self.poster = poster
        self.description = description
        self.genres = genres
        self.rating = rating
        self.cast = cast
        self.originalLang = originalLang
        self.videos = videos
    }
}

/// A person from the TMDb cast.
public struct Contributor: Sendable, Equatable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case name
        case role = "rolle"
        case characterName = "figur"
        case image = "bild"
    }

    public let name: String
    public let role: Person.Role
    /// The character — only for actors.
    public let characterName: String?
    public let image: URL?

    public init(name: String, role: Person.Role, characterName: String?, image: URL?) {
        self.name = name
        self.role = role
        self.characterName = characterName
        self.image = image
    }
}

extension TMDbClient {

    /// How long information stays valid in the store — identifiers and images rarely change.
    static let titleShelfLife: TimeInterval = 14 * 24 * 3600

    /// The information for `movie/603` or `tv/1399` — **one request**, afterwards from the cache.
    public func title(_ identifier: String) async throws -> TitleInfo {
        guard Self.isTitleID(identifier) else { throw Failure.notFound }
        if let known = titleCache[identifier] { return known }
        // With the language in the key: The information's videos depend on it, and a
        // language switch should not read a German cache as English.
        let storeKey =
            "tmdb.titel." + languageCode + "." + identifier.replacingOccurrences(of: "/", with: ".")
        if let raw = try? titleStore.value(for: storeKey),
            let remembered = try? JSONDecoder().decode(RememberedInfo.self, from: Data(raw.utf8)),
            Date().timeIntervalSince(remembered.fetched) < Self.titleShelfLife
        {
            titleCache[identifier] = remembered.info
            return remembered.info
        }
        // `videos` is appended — one request instead of two; `include_video_language` is
        // needed because TMDb otherwise supplies only videos in `language` and the English
        // fallback would be missing. `null` are videos without a language value.
        let dto: TitleDTO = try await get(
            identifier,
            query: [
                URLQueryItem(name: "append_to_response", value: "external_ids,credits,videos"),
                URLQueryItem(name: "include_video_language", value: languageCode + ",en,null"),
            ])
        let info = Self.info(from: dto)
        titleCache[identifier] = info
        if let data = try? JSONEncoder().encode(RememberedInfo(info: info, fetched: Date())) {
            try? titleStore.set(String(decoding: data, as: UTF8.self), for: storeKey)
        }
        return info
    }

    /// Only `movie/<number>` and `tv/<number>` — an identifier would otherwise travel unchecked into a path.
    static func isTitleID(_ identifier: String) -> Bool {
        let split = identifier.split(separator: "/")
        guard split.count == 2, split[0] == "movie" || split[0] == "tv" else { return false }
        return Int(split[1]).map { $0 > 0 } ?? false
    }

    static func info(from dto: TitleDTO) -> TitleInfo {
        let imdb = [dto.imdbID, dto.externalIDs?.imdbID]
            .compactMap { $0 }.first { $0.hasPrefix("tt") }
        return TitleInfo(
            imdbID: imdb,
            backdrop: dto.backdropPath.flatMap { URL(string: imageBase + "w1280" + $0) },
            poster: dto.posterFilePath.flatMap { URL(string: imageBase + "w500" + $0) },
            description: dto.description.flatMap { $0.isEmpty ? nil : $0 },
            genres: dto.genres?.map(\.name) ?? [],
            rating: (dto.voices ?? 0) > 0 ? dto.cut : nil,
            cast: cast(from: dto.contributors),
            originalLang: dto.originalLang,
            videos: videos(from: dto.videos))
    }

    /// YouTube only — only that is resolved by the app. TMDb carries the date as
    /// `2013-11-25T14:30:00.000Z`; the first ten characters suffice for "newest first".
    static func videos(from list: VideoListDTO?) -> [TrailerVideo] {
        (list?.results ?? []).compactMap { v in
            guard v.site?.lowercased() == "youtube", let key = v.key, !key.isEmpty else {
                return nil
            }
            return TrailerVideo(
                youtubeID: key, language: v.language?.lowercased(),
                kind: TrailerVideo.Kind(tmdb: v.contentType), official: v.official ?? false,
                name: v.name ?? "", published: datum(v.published))
        }
    }

    static func datum(_ text: String?) -> Date? {
        guard let text, text.count >= 10 else { return nil }
        return dayFormat.date(from: String(text.prefix(10)))
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A title's videos in **one** language — for the original language, when the
    /// information (app language and English) cannot decide. Without a cache: The case is
    /// rare (foreign-language title without a German trailer) and the response small.
    public func videos(_ identifier: String, language: String) async throws -> [TrailerVideo] {
        guard Self.isTitleID(identifier) else { throw Failure.notFound }
        let dto: VideoListDTO = try await get(identifier + "/videos", language: language)
        return Self.videos(from: dto)
    }

    struct VideoListDTO: Decodable {
        struct Video: Decodable {
            let key: String?
            let site: String?
            let contentType: String?
            let language: String?
            let official: Bool?
            let name: String?
            let published: String?
            enum CodingKeys: String, CodingKey {
                case key, site, name, contentType = "type", language = "iso_639_1", official = "official"
                case published = "published_at"
            }
        }
        let results: [Video]?
    }

    /// This many actors come along — the row shows the front ones anyway.
    static let maxCastMembers = 20

    static func cast(from credits: TitleDTO.Credits?) -> [Contributor] {
        guard let credits else { return [] }
        func image(_ path: String?) -> URL? {
            path.flatMap { URL(string: imageBase + "w185" + $0) }
        }
        let directors = (credits.crew ?? []).filter { $0.job == "Director" }.prefix(2).map {
            Contributor(name: $0.name, role: .director, characterName: nil, image: image($0.imagePath))
        }
        let cast = (credits.cast ?? []).sorted { ($0.row ?? .max) < ($1.row ?? .max) }
            .prefix(maxCastMembers).map {
                Contributor(
                    name: $0.name, role: .actor,
                    characterName: $0.characterName.flatMap { $0.isEmpty ? nil : $0 },
                    image: image($0.imagePath))
            }
        return Array(directors) + cast
    }

    struct RememberedInfo: Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case info = "auskunft"
            case fetched = "geholt"
        }

        let info: TitleInfo
        let fetched: Date
    }

    struct TitleDTO: Decodable {
        struct Genre: Decodable { let name: String }
        struct ExternalIDs: Decodable {
            let imdbID: String?
            enum CodingKeys: String, CodingKey { case imdbID = "imdb_id" }
        }
        let description: String?
        let backdropPath: String?
        let posterFilePath: String?
        let genres: [Genre]?
        let cut: Double?
        let voices: Int?
        let imdbID: String?
        let externalIDs: ExternalIDs?
        let contributors: Credits?
        let originalLang: String?
        let videos: VideoListDTO?

        struct Credits: Decodable {
            struct Cast: Decodable {
                let name: String
                let characterName: String?
                let imagePath: String?
                let row: Int?
                enum CodingKeys: String, CodingKey {
                    case name, characterName = "character", imagePath = "profile_path", row = "order"
                }
            }
            struct CrewMember: Decodable {
                let name: String
                let job: String?
                let imagePath: String?
                enum CodingKeys: String, CodingKey { case name, job, imagePath = "profile_path" }
            }
            let cast: [Cast]?
            let crew: [CrewMember]?
        }

        enum CodingKeys: String, CodingKey {
            case description = "overview"
            case backdropPath = "backdrop_path"
            case posterFilePath = "poster_path"
            case genres
            case cut = "vote_average"
            case voices = "vote_count"
            case imdbID = "imdb_id"
            case externalIDs = "external_ids"
            case contributors = "credits"
            case originalLang = "original_language"
            case videos
        }
    }
}

// MARK: - Search when no identifier is there

extension TMDbClient {

    /// The TMDb identifier for a title **without** a number of its own — Filmhub and other sources
    /// whose list has none (2026-09-29).
    ///
    /// **Only an unambiguous hit counts:** same title (case,
    /// accents and punctuation ignored) and same year, and exactly one of those. A wrong
    /// film with wrong ratings would be worse than none. Without a year no
    /// search is made. "Nothing found" is remembered too.
    public func search(title: String, year: Int, series: Bool) async throws -> String? {
        let key =
            "tmdb.suche.\(series ? "tv" : "movie").\(year)."
            + Self.comparisonForm(title).replacingOccurrences(of: " ", with: "-")
        if let raw = try? titleStore.value(for: key),
            let remembered = try? JSONDecoder().decode(RememberedSearch.self, from: Data(raw.utf8)),
            Date().timeIntervalSince(remembered.fetched) < Self.titleShelfLife
        {
            return remembered.identifier
        }
        let reply: SearchResponse = try await get(
            series ? "search/tv" : "search/movie",
            query: [
                URLQueryItem(name: "query", value: title),
                URLQueryItem(name: series ? "first_air_date_year" : "year", value: String(year)),
            ])
        let identifier = Self.unique(reply.results, title: title, year: year)
            .map { (series ? "tv/" : "movie/") + String($0) }
        if let data = try? JSONEncoder().encode(RememberedSearch(identifier: identifier, fetched: Date())) {
            try? titleStore.set(String(decoding: data, as: UTF8.self), for: key)
        }
        return identifier
    }

    static func unique(_ match: [SearchResponse.Match], title: String, year: Int) -> Int? {
        let needle = comparisonForm(title)
        let matching = match.filter { entry in
            let names = [entry.title, entry.name, entry.originalTitle, entry.originalName]
                .compactMap { $0 }.map(comparisonForm)
            let datum = entry.releaseDate ?? entry.firstAirDate ?? ""
            return names.contains(needle) && datum.hasPrefix(String(year))
        }
        return matching.count == 1 ? matching[0].id : nil
    }

    /// Lowercase, without accents, only letters and digits, spaces collapsed.
    static func comparisonForm(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let only = folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(only).split(separator: " ").joined(separator: " ")
    }

    struct RememberedSearch: Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case identifier = "kennung"
            case fetched = "geholt"
        }

        let identifier: String?
        let fetched: Date
    }

    struct SearchResponse: Decodable {
        struct Match: Decodable {
            let id: Int
            let title: String?
            let name: String?
            let originalTitle: String?
            let originalName: String?
            let releaseDate: String?
            let firstAirDate: String?
            enum CodingKeys: String, CodingKey {
                case id, title, name
                case originalTitle = "original_title"
                case originalName = "original_name"
                case releaseDate = "release_date"
                case firstAirDate = "first_air_date"
            }
        }
        let results: [Match]
    }
}
