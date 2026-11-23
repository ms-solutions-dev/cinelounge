import Core
import Foundation

/// Fetches ratings from IMDb, Rotten Tomatoes and Metacritic.
///
/// The path goes via OMDb, because there all three are in a single response
/// — with the IMDb identifier as key, and the Jellyfin server already
/// supplies that. This leaves its metadata sources untouched: The
/// descriptions keep coming from there, the ratings additionally from here.
///
/// **The quota is the limiting factor**: 1000 queries a day on the
/// free tier. For a library with a few hundred titles that would be
/// used up after two passes if every opening asked anew.
/// That is why every response is kept — ratings change in days, not
/// in minutes.
public actor OMDbClient {

    public enum Failure: Error, Equatable {
        case noKey
        case notFound
        case quotaExceeded
        /// OMDb does not know the key — copied wrongly or never activated.
        case invalidKey
        case unreachable

        public var messageKey: String {
            switch self {
            case .noKey: "error.omdbNoKey"
            case .notFound: "error.omdbNotFound"
            case .quotaExceeded: "error.omdbQuota"
            case .invalidKey: "error.omdbInvalidKey"
            case .unreachable: "error.unreachable"
            }
        }
    }

    private let apiKey: String
    private let session: URLSession
    private let store: any KeyValueStore

    /// Ratings already fetched, by IMDb identifier.
    private var cache: [String: ExternalRatings] = [:]

    public init(apiKey: String, store: any KeyValueStore = InMemoryStore()) {
        self.apiKey = apiKey
        self.store = store

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        // Also cache at system level: A restart of the app should
        // not eat into the daily quota.
        config.urlCache = URLCache(
            memoryCapacity: 2 * 1024 * 1024,
            diskCapacity: 20 * 1024 * 1024,
            diskPath: "cinelounge.ratings"
        )
        self.session = URLSession(configuration: config)

        self.cache = Self.loadCache(from: store)
    }

    public func ratings(forIMDbID id: String) async throws -> ExternalRatings {
        if let cached = cache[id] {
            return cached
        }

        var components = URLComponents(string: "https://www.omdbapi.com/")
        components?.queryItems = [
            URLQueryItem(name: "i", value: id),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        guard let url = components?.url else { throw Failure.unreachable }

        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ratings = try Self.evaluate(status: status, data: data)
            cache[id] = ratings
            saveCache()
            return ratings
        } catch let failure as Failure {
            throw failure
        } catch {
            Diagnostics.failure(url, step: "Fetch ratings", error: error)
            throw Failure.unreachable
        }
    }

    /// How many titles have already been queried — for the display in
    /// Settings, so the quota stays traceable.
    public var cachedCount: Int { cache.count }

    public func clearCache() {
        cache.removeAll()
        try? store.remove(Self.cacheKey)
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    // MARK: - Evaluation

    /// Ratings are derived from the status and body of a response — **or the reason why not.**
    ///
    /// **The body is also read for 401 and 403** (check 2026-09-27, D7). OMDb
    /// reports "Request limit reached!" and "Invalid API key!" with HTTP 401 and
    /// `Response: False`. Before, every status except 200 became ``Failure/unreachable``,
    /// **before** the wording was read — an exhausted quota then meant "No
    /// response", and the viewer looked for the error in the network. The mapping rests on
    /// the service's known practice; it is not measured.
    static func evaluate(status: Int, data: Data) throws -> ExternalRatings {
        let readable = status == 200 || status == 401 || status == 403
        guard readable, let payload = try? JSONDecoder().decode(Response.self, from: data) else {
            throw Failure.unreachable
        }
        guard payload.response == "True" else {
            let report = payload.error?.lowercased() ?? ""
            if report.contains("limit") { throw Failure.quotaExceeded }
            if report.contains("api key") { throw Failure.invalidKey }
            throw status == 200 ? Failure.notFound : Failure.unreachable
        }
        return parse(payload)
    }

    static func parse(_ payload: Response) -> ExternalRatings {
        var result = ExternalRatings()

        // The own field is more reliable than the entry in the list: For
        // series the latter is sometimes missing.
        result.imdb = Double(payload.imdbRating?.replacingOccurrences(of: ",", with: ".") ?? "")

        for entry in payload.ratings ?? [] {
            switch entry.source {
            case "Internet Movie Database":
                if result.imdb == nil {
                    result.imdb = Double(entry.value.split(separator: "/").first ?? "")
                }
            case "Rotten Tomatoes":
                // Kommt als „85%".
                result.rottenTomatoes = Int(entry.value.replacingOccurrences(of: "%", with: ""))
            case "Metacritic":
                // Kommt als „67/100".
                result.metacritic = Int(entry.value.split(separator: "/").first ?? "")
            default:
                break
            }
        }

        // Awards come as free text in the same response. They cost
        // no further query and no further service — only a parser
        // that claims nothing when in doubt. See ``Awards``.
        result.awards = Awards.parse(payload.awards)

        return result
    }

    // MARK: - Store

    /// The store key **carries a version number**, and that is no decoration.
    ///
    /// If a field is added — here it was the awards —, old entries can still
    /// be read. They are just incomplete: `awards` in them is
    /// `nil`, forever. And because the cache hits, OMDb is never asked
    /// again. The badge would stay invisible permanently, and one would look for the error
    /// in the parser, which is fine. That is exactly how it occurred.
    ///
    /// A new number discards the old data once. That costs one query per title
    /// — with a thousand allowed per day that is nothing.
    static let cacheKey = "omdb.ratings.v2"

    private static func loadCache(from store: any KeyValueStore) -> [String: ExternalRatings] {
        guard let json = try? store.value(for: cacheKey),
            let data = json.data(using: .utf8)
        else { return [:] }

        if let decoded = try? JSONDecoder().decode([String: ExternalRatings].self, from: data) {
            return decoded
        }

        // Second attempt, entry by entry. Before, a single
        // unusable entry would have discarded the whole store — after an
        // extension of the fields all ratings would have vanished at once
        // and the daily quota would have been due again.
        guard let lenient = try? JSONDecoder().decode([String: Lenient].self, from: data) else {
            return [:]
        }
        return lenient.compactMapValues(\.value)
    }

    /// A store entry that is allowed to fail individually.
    private struct Lenient: Decodable {
        let value: ExternalRatings?

        init(from decoder: any Decoder) throws {
            value = try? ExternalRatings(from: decoder)
        }
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(cache),
            let json = String(data: data, encoding: .utf8)
        else { return }
        try? store.set(json, for: Self.cacheKey)
    }

    // MARK: - Response shape

    struct Response: Decodable {
        let response: String
        let error: String?
        let imdbRating: String?
        let ratings: [Entry]?
        /// Free text, see ``Awards``. Missing entirely from some responses — for example
        /// from the title search, which returns only identifier, year and poster.
        let awards: String?

        enum CodingKeys: String, CodingKey {
            case response = "Response"
            case error = "Error"
            case imdbRating
            case ratings = "Ratings"
            case awards = "Awards"
        }

        struct Entry: Decodable {
            let source: String
            let value: String

            enum CodingKeys: String, CodingKey {
                case source = "Source"
                case value = "Value"
            }
        }
    }
}

/// Ratings from third-party sources, as OMDb supplies them.
public struct ExternalRatings: Sendable, Equatable, Hashable, Codable {

    /// Zehnerskala.
    public var imdb: Double?
    /// Prozent.
    public var rottenTomatoes: Int?
    /// Von hundert.
    public var metacritic: Int?
    /// Ten-point scale, from a different source than the other fields: MyAnimeList covers
    /// anime where critic portals have nothing (AP68 — before, the AniList rating).
    public var mal: Double?
    /// Oscars, Emmys and the totals — not a rating, but information
    /// about what the title has won. `nil` if OMDb says nothing about it.
    public var awards: Awards?

    public init(
        imdb: Double? = nil,
        rottenTomatoes: Int? = nil,
        metacritic: Int? = nil,
        mal: Double? = nil,
        awards: Awards? = nil
    ) {
        self.imdb = imdb
        self.rottenTomatoes = rottenTomatoes
        self.metacritic = metacritic
        self.mal = mal
        self.awards = awards
    }

    /// Whether a rating is present.
    ///
    /// Awards explicitly do **not** count here: The condition
    /// decides in several places whether the row with the
    /// rating badges is built at all, and the new field should
    /// change nothing about that. Whoever wants to show the badge additionally asks
    /// ``hasAwards``.
    public var isEmpty: Bool {
        imdb == nil && rottenTomatoes == nil && metacritic == nil && mal == nil
    }

    public var hasAwards: Bool { awards?.isEmpty == false }
}
