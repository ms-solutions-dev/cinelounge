import Core
import Foundation

/// The audience rating from MyAnimeList (AP68, 2026-10-07).
///
/// **Replaces the AniList rating.** Two anime ratings side by side say nothing that one
/// does not say; MAL is the number viewers know and on which most votes
/// collect (Ceitfrougrai: 941,947). AniList remains only for the German voices
/// (``AniListClient/germanVoices(forAniListID:)``) — the MAL interface knows no
/// voice actors.
///
/// **With access:** MAL requires a client ID (`X-MAL-CLIENT-ID`) that the user enters in
/// Settings, like the OMDb key. Without it there is no client and
/// no anime rating.
///
/// The query goes only by the **number** that ``AnimeMapping`` supplies per season — a
/// title search for "Ceitfrougrai" returns the first, second and third season.
public actor MALClient {

    /// What MAL says about an entry.
    public struct Rating: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case score = "wert"
            case voices = "stimmen"
            case rank = "rang"
        }

        /// Ten-point scale, two decimal places.
        public let score: Double
        public let voices: Int?
        public let rank: Int?

        public init(score: Double, voices: Int? = nil, rank: Int? = nil) {
            self.score = score
            self.voices = voices
            self.rank = rank
        }
    }

    public enum Failure: Error, Equatable {
        case notFound
        case unauthorized
        case unreachable
    }

    static let endpoint = URL(string: "https://api.myanimelist.net/v2/anime/")!
    static let fields = "mean,num_scoring_users,rank"

    /// How long a rating is valid — it changes in days, not in minutes.
    static let isValid: TimeInterval = 3 * 24 * 3600

    private let clientID: String
    private let session: URLSession
    private let store: any KeyValueStore
    private var cache: [Int: Remembered] = [:]

    struct Remembered: Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case rating = "wertung"
            case on = "am"
        }

        let rating: Rating?
        let on: Date
    }

    public init(clientID: String, store: any KeyValueStore = InMemoryStore()) {
        self.clientID = clientID
        self.store = store
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
        self.cache = Self.loadCache(from: store)
    }

    /// An entry's rating. **No rating is not an error** — an entry with too
    /// few votes has none, and then there is nothing to display.
    public func rating(forItem id: Int) async throws -> Rating? {
        if let remembered = cache[id], Date().timeIntervalSince(remembered.on) < Self.isValid {
            return remembered.rating
        }
        var request = URLRequest(url: Self.address(forItem: id))
        request.setValue(clientID, forHTTPHeaderField: "X-MAL-CLIENT-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Diagnostics.attempt(Self.endpoint, step: "MAL rating for \(id)")

        let reply: (Data, URLResponse)
        do {
            reply = try await session.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        guard let http = reply.1 as? HTTPURLResponse else { throw Failure.unreachable }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw Failure.unauthorized
        case 404: throw Failure.notFound
        default:
            Diagnostics.network.error("MAL: status \(http.statusCode, privacy: .public)")
            throw Failure.unreachable
        }
        let rating = try Self.parse(reply.0)
        cache[id] = Remembered(rating: rating, on: Date())
        save()
        Diagnostics.success(
            Self.endpoint, step: "MAL rating", detail: rating.map { "\($0.score)" } ?? "none")
        return rating
    }

    static func address(forItem id: Int) -> URL {
        var split = URLComponents(url: endpoint.appending(path: String(id)), resolvingAgainstBaseURL: false)!
        split.queryItems = [URLQueryItem(name: "fields", value: fields)]
        return split.url!
    }

    /// From the response. `mean` is missing for entries without enough votes — or for
    /// announced ones that are not yet running.
    static func parse(_ data: Data) throws -> Rating? {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let score = reply.mean, score > 0 else { return nil }
        return Rating(score: score, voices: reply.voices, rank: reply.rank)
    }

    struct Reply: Decodable {
        let mean: Double?
        let voices: Int?
        let rank: Int?

        enum CodingKeys: String, CodingKey {
            case mean
            case voices = "num_scoring_users"
            case rank
        }
    }

    // MARK: - Store

    private static let cacheKey = "mal.wertungen"

    private static func loadCache(from store: any KeyValueStore) -> [Int: Remembered] {
        guard let json = try? store.value(for: cacheKey),
            let data = json.data(using: .utf8),
            let read = try? JSONDecoder().decode([Int: Remembered].self, from: data)
        else { return [:] }
        return read
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cache),
            let json = String(data: data, encoding: .utf8)
        else { return }
        try? store.set(json, for: Self.cacheKey)
    }
}
