import Core
import Foundation

/// The anime rating from one hand: mapping per season and MAL query (AP68).
///
/// **One object instead of two pass-throughs.** Home, library and detail page of both
/// programs need the same pair; before, every place passed the AniList client through.
/// The client ID is read on every query — whoever enters it in Settings or
/// deletes it needs no restart and no callback of their own.
public actor AnimeRating {

    public let assignment: AnimeMapping
    private let key: @Sendable () -> String?
    private let store: any KeyValueStore
    private var client: (id: String, client: MALClient)?

    public init(
        assignment: AnimeMapping = AnimeMapping(),
        store: any KeyValueStore = InMemoryStore(),
        key: @escaping @Sendable () -> String?
    ) {
        self.assignment = assignment
        self.store = store
        self.key = key
    }

    /// The MAL client for the entered client ID — `nil` without one.
    public func mal() -> MALClient? {
        guard let id = key(), !id.isEmpty else {
            client = nil
            return nil
        }
        if let client, client.id == id { return client.client }
        let fresh = MALClient(clientID: id, store: store)
        client = (id, fresh)
        return fresh
    }

    /// A title's MAL rating, ten-point scale — `nil` if it is not an anime, no
    /// client ID is entered or MAL has no rating.
    public func rating(tvdb: String?, tmdb: String?, imdb: String?, season: Int = 1) async -> Double? {
        guard let mal = mal(),
            let id = await assignment.entry(tvdb: tvdb, tmdb: tmdb, imdb: imdb, season: season)?.mal
        else { return nil }
        return try? await mal.rating(forItem: id)?.score
    }
}

extension AnimeRating {

    /// A title's TVDB number, **as far as it is usable for the mapping**: Only series and
    /// film carry their own. A Jellyfin episode carries the episode's number, and that
    /// would hit an unrelated series in the list by chance.
    public static func tvdb(_ title: MediaItem) -> String? {
        switch title.kind {
        case .series, .movie: title.ratings.tvdbID
        default: nil
        }
    }

    /// The rating for a title. For an episode or season the caller passes the series
    /// along — then its identifier and the episode's season count.
    public func rating(forItem title: MediaItem, series: MediaItem? = nil) async -> Double? {
        let carrier = series ?? title
        return await rating(
            tvdb: Self.tvdb(carrier), tmdb: carrier.ratings.tmdbID, imdb: carrier.ratings.imdbID,
            season: series == nil ? 1 : max(title.seasonNumber ?? 1, 1))
    }
}
