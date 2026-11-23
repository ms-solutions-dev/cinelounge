import Core
import Foundation

/// Fetches ratings for anime from AniList.
///
/// Why a source of its own next to OMDb: Critic portals practically do not cover
/// anime. Rotten Tomatoes and Metacritic stay empty there, and IMDb has few votes for
/// Japanese series. For this genre AniList is the authority viewers go by —
/// comparable to MyAnimeList, but with
/// an open interface.
///
/// **No access key needed.** Read queries are free; there is only a
/// per-minute cap. That is why every response is kept: Ratings change
/// in days, not in minutes, and browsing through a library
/// would otherwise cause a flood of requests.
///
/// The query goes by **identifier**, never by title. A title search for
/// "Blibiagraik" returns three entries with 79, 88 and 86 points — showing the wrong number
/// would be worse than showing none. The identifier comes with the
/// Jellyfin server, provided the AniList plugin is set up there.
public actor AniListClient {

    public enum Failure: Error, Equatable {
        case notFound
        case rateLimited
        case unreachable

        public var messageKey: String {
            switch self {
            case .notFound: "error.anilistNotFound"
            case .rateLimited: "error.anilistRateLimit"
            case .unreachable: "error.unreachable"
            }
        }
    }

    private static let endpoint = URL(string: "https://graphql.anilist.co")!

    private let session: URLSession
    private let store: any KeyValueStore

    /// Ratings already fetched, by AniList identifier.
    private var cache: [String: Int] = [:]

    public init(store: any KeyValueStore = InMemoryStore()) {
        self.store = store

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.urlCache = URLCache(
            memoryCapacity: 1 * 1024 * 1024,
            diskCapacity: 25 * 1024 * 1024,
            diskPath: "cinelounge.anilist"
        )
        self.session = URLSession(configuration: config)
        self.cache = Self.loadCache(from: store)
    }

    /// The German voice actors for a title's roles.
    ///
    /// **A query of its own next to the rating**, and that is deliberate: The
    /// rating appears on every tile and is fetched often, the voices only on
    /// an open detail page. Combining them would mean dragging a character list
    /// along for every tile.
    ///
    /// If nothing comes back, that is not an error but the normal case for everything
    /// that is not anime — then the second row of the cast is left out.
    public func germanVoices(forAniListID id: String) async throws -> GermanVoices {
        guard let numeric = Int(id) else { throw Failure.notFound }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": Self.voicesQuery,
            "variables": ["id": numeric],
        ])

        Diagnostics.attempt(Self.endpoint, step: "AniList votes for \(id)")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.unreachable
        }

        let payload = try JSONDecoder().decode(VoicesResponse.self, from: data)
        var byCharacter: [String: VoiceCredit] = [:]
        for edge in payload.data.media?.characters.edges ?? [] {
            guard let voiceActor = edge.voiceActors.first, let role = edge.node.name.full else {
                continue
            }
            let key = GermanVoices.normalized(role)
            // The first one wins: For long series AniList lists several
            // voice actors per role, and the first is the one who carries it.
            guard byCharacter[key] == nil else { continue }
            byCharacter[key] = VoiceCredit(
                name: voiceActor.name.full ?? "",
                imageURL: voiceActor.image?.medium.flatMap(URL.init(string:))
            )
        }
        Diagnostics.success(Self.endpoint, step: "AniList-Stimmen", detail: "\(byCharacter.count)")
        return GermanVoices(byCharacter: byCharacter.filter { !$0.value.name.isEmpty })
    }

    /// The audience rating from 0 to 100.
    public func score(forAniListID id: String) async throws -> Int {
        if let cached = cache[id] {
            return cached
        }
        guard let numeric = Int(id) else { throw Failure.notFound }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": Self.query,
            "variables": ["id": numeric],
        ])

        Diagnostics.attempt(Self.endpoint, step: "AniList rating for \(id)")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }

            // The cap is reported separately. Distinguishing it from a failure
            // matters: In one case a later attempt is worthwhile,
            // in the other it is not.
            guard http.statusCode != 429 else {
                Diagnostics.network.error("AniList: request limit reached")
                throw Failure.rateLimited
            }
            guard http.statusCode == 200 else {
                // Keep the response text: With a query language the errors are in
                // the body, not in the status code, and without it one looks
                // in one's own code for an error that lies with the service.
                let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
                Diagnostics.network.error(
                    "AniList answered with \(http.statusCode): \(body, privacy: .public)"
                )
                throw Failure.unreachable
            }

            let payload = try JSONDecoder().decode(Response.self, from: data)
            // An entry without enough votes has no rating. That is not an
            // error, but also nothing that could be displayed.
            guard let score = payload.data?.media?.averageScore else {
                let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
                Diagnostics.network.error(
                    "AniList without a rating for \(id): \(body, privacy: .public)"
                )
                throw Failure.notFound
            }

            cache[id] = score
            saveCache()
            Diagnostics.success(Self.endpoint, step: "AniList-Bewertung", detail: "\(score) %")
            return score
        } catch let failure as Failure {
            throw failure
        } catch {
            Diagnostics.failure(Self.endpoint, step: "Fetch AniList rating", error: error)
            throw Failure.unreachable
        }
    }

    public var cachedCount: Int { cache.count }

    public func clearCache() {
        cache.removeAll()
        try? store.remove(Self.cacheKey)
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    // MARK: - Query

    /// Only the one number being asked for. With a query language the scope
    /// can be specified exactly — it would be unnecessary to fetch the whole entry with
    /// descriptions and images.
    static let query = """
        query ($id: Int) {
          Media(id: $id, type: ANIME) {
            averageScore
          }
        }
        """

    /// **Limited with `perPage`**: The cast row shows a handful of
    /// names, and a series like "Hisvei Weprir" has over a thousand
    /// roles at AniList. Twenty-five cover any main cast.
    static let voicesQuery = """
        query ($id: Int) {
          Media(id: $id, type: ANIME) {
            characters(sort: ROLE, perPage: 25) {
              edges {
                node { name { full } }
                voiceActors(language: GERMAN) { name { full } image { medium } }
              }
            }
          }
        }
        """

    private struct VoicesResponse: Decodable {
        struct Data: Decodable {
            let media: Media?

            enum CodingKeys: String, CodingKey { case media = "Media" }
        }
        struct Media: Decodable { let characters: Characters }
        struct Characters: Decodable { let edges: [Edge] }
        struct Edge: Decodable {
            let node: Node
            let voiceActors: [Actor]
        }
        struct Node: Decodable { let name: Name }
        struct Actor: Decodable {
            let name: Name
            let image: Image?
        }
        struct Name: Decodable { let full: String? }
        struct Image: Decodable { let medium: String? }

        let data: Data
    }

    // MARK: - Store

    private static let cacheKey = "anilist.scores"

    private static func loadCache(from store: any KeyValueStore) -> [String: Int] {
        guard let json = try? store.value(for: cacheKey),
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(cache),
            let json = String(data: data, encoding: .utf8)
        else { return }
        try? store.set(json, for: Self.cacheKey)
    }

    // MARK: - Response shape

    struct Response: Decodable {
        let data: Payload?

        struct Payload: Decodable {
            let media: Media?

            enum CodingKeys: String, CodingKey {
                case media = "Media"
            }
        }

        struct Media: Decodable {
            let averageScore: Int?
        }
    }
}
