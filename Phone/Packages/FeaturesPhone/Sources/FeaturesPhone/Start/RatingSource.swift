import Core
import Foundation
import RatingsKit

/// Where the information comes from that the media server does not supply.
///
/// **A protocol, so that Home and the detail page stay testable without a network.** The
/// actual implementation talks to two third-party services and a daily quota; a test that
/// goes along with that tests the services and not us.
public protocol RatingSource: Sendable {

    /// Everything that can be fetched in **one** pass.
    ///
    /// - Returns: an empty result if there was nothing to fetch — **not an error**. A missing
    ///   rating is the normal case (no key, no identifier, no entry) and must never trigger a
    ///   state block anywhere. What goes wrong goes into the error log, not onto the screen.
    func info(zu identifier: RatingID) async -> ExternalInfo

    /// The trailer according to the ``Core/TrailerRule`` (AP78): own file and TMDb videos,
    /// app language before original before English. The default knows no TMDb and sticks to
    /// the file.
    func trailer(zu identifier: RatingID, file: TrailerFile?) async -> TrailerChoice?
}

extension RatingSource {

    public func trailer(zu identifier: RatingID, file: TrailerFile?) async -> TrailerChoice? {
        file.map { .file(language: $0.language) }
    }
}

extension RatingSource {

    /// Only the numbers — what Home needs.
    ///
    /// Home fetches for eight heroes; it does not show awards and voices. They come along
    /// anyway because they are in the **same** OMDb response: a second query for them would be
    /// a second grab at the daily quota for something that is already there.
    public func ratings(zu identifier: RatingID) async -> [Rating] {
        await info(zu: identifier).ratings
    }
}

/// What can be learned about a title from outside.
///
/// **Three things in one value, because they come from two responses and not from
/// three.** Ratings and awards are both in the OMDb response, the German voices in the
/// same AniList query as the AniList rating. Fetching them individually would mean making
/// the same two requests twice.
public struct ExternalInfo: Sendable, Equatable {

    public var ratings: [Rating]

    /// The strongest statement the evaluator provides — or none.
    public var award: Accolade?

    /// The German voice actors, searchable by role.
    ///
    /// They exist only for anime, and that is not a gap: the media server holds no dubbing
    /// voices, and the film database holds the **original** cast, the same in every language.
    /// AniList holds them per role and language — and only there.
    public var voices: GermanVoices

    /// Whether an OMDb access is entered at all.
    ///
    /// **The difference you otherwise do not see.** "No rating found" and "no access
    /// configured" look the same on the screen, namely like nothing — and only one of the two
    /// cases can be remedied. The rating sheet therefore says which of the two applies.
    public var isAccessConfigured: Bool

    /// From TMDb (2026-09-29) — only for titles that otherwise have none
    /// (``HeroContent/completed(um:)``).
    public var backdrop: URL?
    public var description: String?
    public var genres: [String]
    /// The cast from TMDb, with images — for titles whose source carries none.
    public var cast: [PersonDetail] = []
    /// MyAnimeList carries the title but did not respond (AP68) — then the missing number is
    /// a disruption and not information about the title.
    public var hasMuteMark = false

    public init(
        ratings: [Rating] = [], award: Accolade? = nil,
        voices: GermanVoices = GermanVoices(byCharacter: [:]),
        isAccessConfigured: Bool = false,
        backdrop: URL? = nil, description: String? = nil, genres: [String] = [],
        cast: [PersonDetail] = [], hasMuteMark: Bool = false
    ) {
        self.ratings = ratings
        self.award = award
        self.voices = voices
        self.isAccessConfigured = isAccessConfigured
        self.backdrop = backdrop
        self.description = description
        self.genres = genres
        self.cast = cast
        self.hasMuteMark = hasMuteMark
    }

    public static let empty = ExternalInfo()

    /// Whether there is anything to show.
    ///
    /// **The award counts too.** On the TV this was the trap because of which a badge never
    /// appeared: the condition only asked for ratings, and a film with four Oscars but no
    /// rating got no row at all. One would have looked for the bug in the evaluator, which
    /// works flawlessly.
    public var hasContent: Bool {
        !ratings.isEmpty || award != nil || backdrop != nil || description != nil
            || !genres.isEmpty || !cast.isEmpty
    }
}
