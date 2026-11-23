import Core
import Foundation
import Observation

/// What a poster needs to ask for its MAL rating — a title's identifiers,
/// without the title itself (AP68, 2026-10-07).
///
/// **A small value of its own**, because the phone's tile no longer knows the title,
/// only its finished content. As a key it also serves to ask about the same series on two
/// shelves only once.
public struct AnimeQuery: Hashable, Sendable {
    public let tvdb: String?
    public let tmdb: String?
    public let imdb: String?

    public init(tvdb: String?, tmdb: String?, imdb: String?) {
        self.tvdb = tvdb
        self.tmdb = tmdb
        self.imdb = imdb
    }

    /// Only series and film, and only with an identifier. An episode carries its own
    /// TVDB number, and that would hit an unrelated series in the list.
    public static func from(_ title: MediaItem) -> AnimeQuery? {
        guard title.kind == .series || title.kind == .movie else { return nil }
        let request = AnimeQuery(
            tvdb: title.ratings.tvdbID, tmdb: title.ratings.tmdbID, imdb: title.ratings.imdbID)
        return request.tvdb == nil && request.tmdb == nil && request.imdb == nil ? nil : request
    }
}

/// The posters' MAL ratings, **asked only when a poster is visible.**
///
/// **Why on the poster and not only on the detail page** (product decision 2026-10-07): In
/// Animehub's "Popular series", 20 of 45 anime carried a TMDb rating — almost all new
/// series, which hardly anyone votes on at TMDb —, at MAL 37 of 45. And where TMDb had
/// one, it was flattered by few votes: "Gudond Glaskiam Norern" 8.6 against 6.78 with
/// 18,912 votes.
///
/// **At most four requests at a time.** A shelf with 45 posters would otherwise be a flood
/// of 45 requests at once. What is not anime does not ask at all: The mapping does not know
/// the title, and ``AnimeRating`` returns `nil` before it asks MAL.
@MainActor
@Observable
public final class AnimeScores {

    public private(set) var scores: [AnimeQuery: Double] = [:]

    @ObservationIgnored private let rating: AnimeRating
    @ObservationIgnored private var asked: Set<AnimeQuery> = []
    @ObservationIgnored private var waiting: [AnimeQuery] = []
    @ObservationIgnored private var running = 0

    /// How many requests run at the same time.
    public static let concurrently = 4

    public init(rating: AnimeRating) {
        self.rating = rating
    }

    /// The rating, if it is already there.
    public func note(_ request: AnimeQuery) -> Double? {
        scores[request]
    }

    /// Asks the question once per title; the answer arrives via ``scores``.
    public func query(_ request: AnimeQuery) {
        guard asked.insert(request).inserted else { return }
        waiting.append(request)
        next()
    }

    private func next() {
        while running < Self.concurrently, !waiting.isEmpty {
            let request = waiting.removeFirst()
            running += 1
            let rating = rating
            Task {
                let score = await rating.rating(tvdb: request.tvdb, tmdb: request.tmdb, imdb: request.imdb)
                if let score { scores[request] = score }
                running -= 1
                next()
            }
        }
    }
}
