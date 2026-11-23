import Foundation

/// What stands in the header area.
///
/// **A type of its own next to ``TileContent`` and not an extended one.** The header area
/// is not a big shelf: It shows a description, an attribute line and a rating, and it
/// shows them for at most eight titles. Carrying the same fields on each of the twenty
/// tiles per shelf would mean fetching and holding for eighty tiles what eight need.
public struct HeroContent: Sendable, Equatable, Identifiable {

    public let tile: TileContent

    /// The title's wordmark as an image, if the server carries one.
    ///
    /// A drawn logo is different for every title and carries the film's handwriting; set
    /// system type never does. If it is missing, the title stands as text — that is why it is
    /// an extra here and not a condition.
    public let logo: URL?

    /// The synopsis. Two lines in the box, the rest on the detail page.
    public let description: String?

    /// Year, age rating, genres — already separate, so that the view sets the separator dots
    /// and does not have to take apart a composed string.
    public let attributes: [String]

    /// **All that exist — not the best.**
    ///
    /// On a tile there is room for one, on the detail page for four. On the TV, IMDb, TMDb,
    /// Rotten Tomatoes, Metacritic and AniList stand side by side, and that is no pile-up: For
    /// an anime AniList has 40.000 votes and Rotten Tomatoes none at all — whoever shows only
    /// one number shows, depending on the title, a different kind of information without
    /// saying so.
    public let ratings: [Rating]

    /// The one that fits on a tile.
    public var rating: Rating? { Rating.best(from: ratings) }

    /// What a rating service uses to recognise the title.
    public let identifier: RatingID

    /// The age rating **in the server's wording** (`MediaItem.ageRating`) — `nil` where there
    /// is none.
    ///
    /// **Why it stands next to ``attributes``** (strand G, 2026-09-25): The downloads read the
    /// rating back from the attribute line up to here, and there it can only be guessed
    /// (``DownloadDescriber``: "the first entry with a digit"). "TV-MA", "R" and "NR" have
    /// none and ended up as genre — for the filter in the downloads that would mean "no
    /// information", so let it through, where on the TV "not understood" blocks.
    public let approval: String?

    public var id: String { tile.id }

    public init(
        tile: TileContent,
        logo: URL? = nil,
        description: String? = nil,
        attributes: [String] = [],
        ratings: [Rating] = [],
        identifier: RatingID = RatingID(),
        approval: String? = nil
    ) {
        self.approval = approval
        self.tile = tile
        self.logo = logo
        self.description = description
        self.attributes = attributes
        self.ratings = ratings
        self.identifier = identifier
    }

    /// The same hero with ratings supplied later.
    ///
    /// The Home screen stands immediately with what the server delivers along; what comes in
    /// from the network is added later. A header area that waits for a foreign request would be
    /// a header area that does not appear at all when the network is off.
    ///
    /// **Merged, not replaced — with one exception.** Until 2026-09-05 the supplement threw away
    /// the server's number, because it and the one from IMDb are both "the audience rating".
    /// The reasoning is right, the rule was too broad: If only an AniList number came back from
    /// outside, the server number vanished for nothing — and on the detail page, where there is
    /// room for four badges, **one** stood afterwards.
    ///
    /// Now the community rating yields exactly when an **IMDb number** arrives: Then two
    /// numbers for the same thing would really stand next to each other, differing by a
    /// tenth. Otherwise it stays.
    /// What TMDb knows, **only where the title has nothing** (2026-09-29): description,
    /// genres, background image. Nothing is overwritten.
    public func completed(um info: ExternalInfo) -> HeroContent {
        var tile = tile
        if tile.backdrop == nil { tile.backdrop = info.backdrop }
        let text = description.flatMap { $0.isEmpty ? nil : $0 } ?? info.description
        return HeroContent(
            tile: tile, logo: logo, description: text,
            attributes: attributes.isEmpty ? info.genres : attributes,
            ratings: ratings, identifier: identifier, approval: approval)
    }

    public func using(ratings incoming: [Rating]) -> HeroContent {
        guard !incoming.isEmpty else { return self }
        let own =
            incoming.contains { $0.origin == .imdb }
            ? [] : ratings.filter { $0.origin == .community }
        return HeroContent(
            tile: tile, logo: logo, description: description, attributes: attributes,
            ratings: incoming + own, identifier: identifier, approval: approval)
    }
}

/// What a title is listed under at a rating service.
///
/// **Via the identifier and never via the title.** A title search for "Blibiagraik" finds three
/// entries at AniList with 79, 88 and 86 points — showing the wrong number is worse than
/// showing none.
public struct RatingID: Sendable, Equatable {

    public let imdb: String?
    public let anilist: String?

    /// TMDb including kind (`movie/603`) — for titles without an IMDb identifier (2026-09-29).
    public let tmdb: String?
    /// TVDB — only from series and film; through it the anime mapping finds the season (AP68).
    public let tvdb: String?
    /// Title, year and kind for the search at TMDb — for titles with **no** identifier at all
    /// (Filmhub and others). Only with a year; otherwise `nil`.
    public let search: SearchDetail?

    public struct SearchDetail: Sendable, Equatable {
        public let title: String
        public let year: Int
        public let series: Bool

        public init(title: String, year: Int, series: Bool) {
            self.title = title
            self.year = year
            self.series = series
        }
    }

    public init(
        imdb: String? = nil, anilist: String? = nil, tmdb: String? = nil, tvdb: String? = nil,
        search: SearchDetail? = nil
    ) {
        self.imdb = imdb
        self.tvdb = tvdb
        self.anilist = anilist
        self.tmdb = tmdb
        self.search = search
    }

    public var isEmpty: Bool { imdb == nil && anilist == nil && tmdb == nil && search == nil }
}
