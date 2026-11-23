import Foundation

/// An entry of the library — series, film, episode or home video.
///
/// Deliberately one common type instead of four separate ones: Home, search and
/// Continue Watching show everything mixed, and having each view keep separate
/// types apart quickly leads to duplicate work.
///
/// `Codable`, because the lists survive on disk as a snapshot: at the next start
/// each view immediately shows the last state while the server is queried in the
/// background. Without this capability every cold start reloads the whole library —
/// on a connection with seconds to the first byte that is a wait in front of an
/// empty screen every time.
public struct MediaItem: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case sortTitle
        case parentTitle
        case seriesID
        case seasonNumber
        case episodeNumber
        case overview
        case year
        case genres
        case languages = "sprachen"
        case studio
        case ageRating
        case runtime
        case chapters
        case seasonCount
        case episodeCount
        case unplayedCount
        case recordedAt
        case addedAt
        case lastWatched = "zuletztGesehen"
        case ratings
        case artwork
        case progress
        case isFavorite
        case hasNoEpisodes
        case source
        case cast
        case directors
        case seriesClearanceChecked = "serienfreigabeGeprueft"
        case seriesClearance = "serienfreigabe"
    }

    public enum Kind: String, Sendable, Equatable, Codable {
        case series
        case season
        case episode
        case movie
        case homeVideo
        case channel
        /// A collection (Jellyfin: BoxSet) — the film series as its own entry.
        ///
        /// Its own case instead of misusing `movie`: selecting a collection opens a grid of
        /// its parts and no playback page, and this switch is made on the kind of entry.
        /// Old snapshots do not know the case — they simply never contain it, so they are
        /// still read.
        case collection
        /// A folder: leads to another list, is not a title itself.
        ///
        /// **Needed since hierarchical sources exist** (AP20). A portal delivers levels
        /// halfway that are not titles — "Popular series" at Serieshub are thirty
        /// genres. Without this case they appeared as posters, as if they were series, and
        /// a press opened a detail page for a genre.
        ///
        /// A surface that claims structure it does not have is worse than a plain one.
        case folder
        /// A subheading in a list — not an entry.
        ///
        /// Not thrown away although it is not a title: "Hidden gems" and "The most popular"
        /// structure the Discover list, and without them there would be eighteen series
        /// with no recognizable connection. Not selectable.
        case separator
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// The title under which the server sorts — without the article at the start.
    ///
    /// Taken from the server and not computed ourselves: it knows its own rules
    /// ("The Prouklaus" is filed under M), and since the libraries are fetched in one piece
    /// and sorted **here**, the order has to stay the same as before, when the server
    /// sorted. If the field is missing, it falls back to the title without a leading
    /// article.
    public var sortTitle: String?

    /// For episodes the series name, otherwise empty.
    public var parentTitle: String?
    /// For episodes and seasons the identifier of the series they belong to.
    ///
    /// Needed to recognize "belongs to the same title" without comparing names: the
    /// header area of Home should not flip back and forth between a started episode and
    /// the series itself — for the viewer that is one title.
    public var seriesID: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?

    public var overview: String?
    public var year: Int?
    public var genres: [String]
    /// The audio languages that the portal lists for this title — `DE`, `EN`, `Ger-Sub` (AP84).
    ///
    /// **`nil` means "unknown", never "German".** The CL-Server fills the field from its
    /// language book and only catches up on missing entries in the background; until
    /// then nothing is here. The corner of the poster (``Flows/PosterCorner/audioBadge(_:)``)
    /// then shows nothing.
    public var languages: [String]?
    public var studio: String?
    public var ageRating: String?
    public var runtime: TimeInterval?
    /// Chapter marks of the title, as far as the server has them.
    ///
    /// Optional instead of empty so that older snapshots on disk stay readable: a
    /// missing key becomes `nil` on reading, a mandatory empty list would be a read
    /// error — and the list cache would be completely empty after the update.
    public var chapters: [Chapter]?
    /// How many seasons, how many episodes, how many still unwatched.
    ///
    /// For series it comes along in the same query as everything else — so the
    /// information column in the grid needs **no reloading** on every focus change,
    /// which would be a flood of requests when browsing.
    public var seasonCount: Int?
    public var episodeCount: Int?
    public var unplayedCount: Int?

    /// When recorded — for home videos the only usable order.
    ///
    /// The server keeps two dates: the recording date, which is only set if the camera
    /// wrote it into the file, and the date on which the file was created. The first is
    /// correct, the second always present — so the first is preferred and the second is
    /// the fallback.
    public var recordedAt: Date?
    /// When the title came into the library.
    ///
    /// Needed for "Recently added": since the library is fetched in one go and ordered
    /// on the client, this date has to be on the title itself — before, the server
    /// sorted by it, and it was never carried along.
    public var addedAt: Date?
    /// When this title last played — **regardless of which source.**
    ///
    /// **The finding (on-device, 2026-09-28):** just watched, and in "Continue Watching"
    /// the title was further back. The row chained the sources together — channels,
    /// Jellyfin, IPTV, CL-Server —, each in its own order, and nobody sorted by time
    /// because the title did not carry it. Jellyfin delivers it (`LastPlayedDate`), the
    /// CL-Server (`changed`), the profile state for IPTV and the channel history as well.
    public var lastWatched: Date?

    public var ratings: Ratings
    public var artwork: Artwork
    public var progress: PlaybackProgress?

    /// Whether the title is marked as a favorite.
    ///
    /// **Kept by the server and not by the app.** The mark is the same one that the web
    /// interface and the phone set; a separate list next to it would drift apart as soon
    /// as someone marks something elsewhere. For channels from a channel list this does
    /// not apply — there is no server that could keep them, and the mark lies with us.
    public var isFavorite: Bool

    /// Whether the provider **demonstrably** has no episode for this series.
    ///
    /// **Three states, not two** — hence optional: `nil` means "not checked", and only
    /// `true` is a statement. That is the whole purpose of the field: at the provider
    /// iptvhost, 958 of 4974 series (19.3 %) have no episode anywhere, and an empty poster
    /// cannot be told apart from an app error. If the field were a plain `Bool`, every
    /// unchecked series would mean "has episodes" — a claim for which there is no basis.
    ///
    /// Whoever derives anything from it may only check `== true`, **never** `!= true`.
    /// The directory behind it is a snapshot: it can be outdated, incomplete or not
    /// there at all, and in all these cases the title must stay untouched.
    public var hasNoEpisodes: Bool?

    /// Filled only on opening — the overviews do not need it.
    public var source: MediaSource?
    /// Likewise only on the detail page: the cast would be unnecessary ballast in lists
    /// with every entry.
    public var cast: [Person]
    /// The names of the director, separate from the cast.
    ///
    /// Separate because ``cast`` is deliberately filtered to contributors **with a
    /// picture** — right for a picture strip, wrong for the details line: directors
    /// rarely have a picture on file and would simply drop out there. Optional instead
    /// of empty for the same reason as ``chapters``: a missing key in old snapshots has
    /// to yield `nil`, not a read error.
    public var directors: [String]?

    /// Whether the rating of the **series** was looked up — for episodes and seasons
    /// (strand K, 2026-09-25).
    ///
    /// **Jellyfin keeps no `OfficialRating` on episodes and seasons,** not even in the
    /// single query; the rating hangs only on the series. Measured on our own server in
    /// Continue Watching: 19 films with a rating, 11 episodes without. Without a lookup
    /// a child saw every episode of an FSK-16 series as soon as it appeared anywhere as
    /// an episode — "no rating" gets through. ``SeriesClearances`` therefore writes the
    /// series' rating into ``ageRating`` and sets this field to `true`.
    ///
    /// **Why ``ageRating`` and not a separate field for the series rating:** everything
    /// that reads a rating — the filter in list, search, detail page, Top Shelf and on
    /// the phone, the display, the collection of the not-understood — reads
    /// ``ageRating``. A second field would have required each of these places to be
    /// extended by one line, and the one forgotten would be the gap from before. This
    /// field carries only **whether** it was asked; the rule needs that to separate
    /// "series without rating" (let through) from "series not determinable" (block in
    /// child mode) — see ``awaitsSeriesClearance``.
    ///
    /// **Not in the initializer**, so that the shared interface does not get another
    /// default parameter; it is set only by ``SeriesClearances``. Optional, so that old
    /// snapshots stay readable.
    public var seriesClearanceChecked: Bool?

    /// The rating of the **series** — only on an episode or season that carries **its
    /// own** (check 2026-09-25, finding 6).
    ///
    /// **The stricter of the two applies.** Until then an episode with its own
    /// `OfficialRating` was completely decoupled from the series: a hand-maintained
    /// "FSK 0" on an episode of an FSK-16 series let it through for a child. Which
    /// rating is the stricter one only parental controls know (mappings, not-understood)
    /// — `Core` interprets nothing. Therefore the second one sits here next to
    /// ``ageRating`` and not in its place; ``SeriesClearances`` sets it,
    /// `ParentalControls.ProtectionRule.shows(_:)` asks both.
    ///
    /// **For an episode without its own rating it stays `nil`** — there the series'
    /// rating is in ``ageRating`` as before. Not in the initializer and optional, for
    /// the same reasons as ``seriesClearanceChecked``.
    public var seriesClearance: String?

    public init(
        id: String,
        kind: Kind,
        title: String,
        sortTitle: String? = nil,
        parentTitle: String? = nil,
        seriesID: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        overview: String? = nil,
        year: Int? = nil,
        genres: [String] = [],
        studio: String? = nil,
        ageRating: String? = nil,
        runtime: TimeInterval? = nil,
        chapters: [Chapter]? = nil,
        recordedAt: Date? = nil,
        addedAt: Date? = nil,
        seasonCount: Int? = nil,
        episodeCount: Int? = nil,
        unplayedCount: Int? = nil,
        ratings: Ratings = .init(),
        artwork: Artwork = .init(),
        progress: PlaybackProgress? = nil,
        isFavorite: Bool = false,
        hasNoEpisodes: Bool? = nil,
        source: MediaSource? = nil,
        cast: [Person] = [],
        directors: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sortTitle = sortTitle
        self.parentTitle = parentTitle
        self.seriesID = seriesID
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.overview = overview
        self.year = year
        self.genres = genres
        self.studio = studio
        self.ageRating = ageRating
        self.runtime = runtime
        self.chapters = chapters
        self.recordedAt = recordedAt
        self.addedAt = addedAt
        self.seasonCount = seasonCount
        self.episodeCount = episodeCount
        self.unplayedCount = unplayedCount
        self.ratings = ratings
        self.artwork = artwork
        self.progress = progress
        self.isFavorite = isFavorite
        self.hasNoEpisodes = hasNoEpisodes
        self.source = source
        self.cast = cast
        self.directors = directors
    }
}

/// Ratings from different sources.
///
/// Jellyfin keeps only two fields, the display is nevertheless designed for more:
/// what stays empty is not shown at all, instead of occupying space with a dash.
public struct Ratings: Sendable, Equatable, Hashable, Codable {
    /// Audience rating, from TMDb or IMDb depending on the server configuration.
    public var community: Double?
    /// Critic rating in percent — in Jellyfin the Rotten Tomatoes field.
    public var critic: Int?
    public var imdb: Double?
    public var imdbID: String?
    /// Identifier at AniList — only present for anime, and only if the server has the
    /// corresponding plugin.
    ///
    /// Without it only the search by title would remain, and for series that is
    /// unreliable: "Blibiagraik" finds three entries with 79, 88 and 86 points. Showing the
    /// wrong number is worse than showing none.
    public var anilistID: String?
    /// Identifier at TMDb **including kind** — `movie/603` or `tv/1399`, the way TMDb
    /// forms its paths (2026-09-29).
    ///
    /// IPTV providers and the CL-Server know it, an IMDb identifier mostly not. Without
    /// it the detail view of these titles stayed thin: OMDb queries only via the IMDb
    /// identifier, and that can be looked up via TMDb (`RatingsKit/Kennungsbruecke`).
    public var tmdbID: String?
    /// Identifier at TheTVDB — Jellyfin almost always brings it along for series (19 of 22).
    /// Through it ``RatingsKit/AnimeMapping`` finds the season at MAL (AP68).
    public var tvdbID: String?

    public init(
        community: Double? = nil,
        critic: Int? = nil,
        imdb: Double? = nil,
        imdbID: String? = nil,
        anilistID: String? = nil,
        tmdbID: String? = nil,
        tvdbID: String? = nil
    ) {
        self.community = community
        self.critic = critic
        self.imdb = imdb
        self.imdbID = imdbID
        self.anilistID = anilistID
        self.tmdbID = tmdbID
        self.tvdbID = tvdbID
    }

    /// `movie/603` or `tv/1399` from a bare number — `nil` for everything that is not a
    /// positive integer (panels write `"0"` or `""` for "unknown").
    public static func tmdbIdentifier(_ number: String?, series: Bool) -> String? {
        guard let number = number?.trimmingCharacters(in: .whitespaces), let value = Int(number),
            value > 0
        else { return nil }
        return (series ? "tv/" : "movie/") + String(value)
    }

    public var isEmpty: Bool {
        community == nil && critic == nil && imdb == nil
    }
}

extension MediaItem {

    /// Whether this title **sits under a series** — an episode or season with a series
    /// identifier, with or without its own rating. ``SeriesClearances`` looks such
    /// titles up so that the stricter rating applies (``seriesClearance``).
    public var belongsToSeries: Bool {
        guard kind == .episode || kind == .season, let seriesID else { return false }
        return !seriesID.isEmpty
    }

    /// Whether this title would **need** its rating from the series — an episode or
    /// season with a series identifier and without its own rating.
    public var needsSeriesClearance: Bool {
        guard kind == .episode || kind == .season, let seriesID, !seriesID.isEmpty
        else { return false }
        return (ageRating ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the rating of this title is **open**: it would need that of the series,
    /// and it was not determined.
    ///
    /// **Open means: not looked up, for whatever reason** — the network failed, the
    /// server did not know the series, or the title arrived by a path that does not look
    /// up at all (a snapshot from before this state). Parental controls block such
    /// titles in child mode; see `ParentalControls.ProtectionRule.shows(_:)`. A series
    /// that demonstrably carries no rating is, by contrast, **not** open — for it "no
    /// rating" applies.
    public var awaitsSeriesClearance: Bool {
        needsSeriesClearance && seriesClearanceChecked != true
    }

    /// Whether a **level** is drawn in wide format.
    ///
    /// **The level decides, not the tile.** A grid of mixed frames — tall here, wide
    /// there — no longer has rows along which the eye travels; and focus jumps in such
    /// a grid in leaps that cannot be predicted. A level therefore carries **one**
    /// format.
    ///
    /// The rule in words: wide only if at least one entry reports wide **and none**
    /// reports portrait. When in doubt, tall — that is the frame in which the app draws
    /// everything anyway, and a wide picture framed upright stands completely on its
    /// plate thanks to ``PosterCard``. Conversely a poster in a wide frame would be
    /// cropped by two thirds.
    ///
    /// Only `== true` and `== false` are read — ``Artwork/isWide`` with `nil` is "not
    /// checked" and does not vote.
    public static func prefersWideArtwork(in items: [MediaItem]) -> Bool {
        if items.contains(where: { $0.artwork.isWide == false }) { return false }
        return items.contains { $0.artwork.isWide == true }
    }
}

public struct Artwork: Sendable, Equatable, Hashable, Codable {
    public var posterID: String?
    public var backdropID: String?
    public var logoID: String?
    public var thumbID: String?

    // MARK: - The identifiers of the images themselves
    //
    // **They are the difference between "sits in the cache" and "is fetched anew on
    // every start", and until now they were present and thrown away.**
    //
    // Jellyfin issues an image address as durably cacheable only if the request
    // parameter `tag` is passed along. Measured on our own server:
    //
    //     ohne tag  ->  Cache-Control: public
    //     mit  tag  ->  Cache-Control: public, max-age=31536000
    //
    // Without `max-age`, `URLCache` has no freshness information and has to request
    // every image again at the next start — the answer is then "304, unchanged", but
    // the way there is a full request over the network. With fifty tiles behind six
    // connections that is fifty round trips before even one tile is drawn. On a
    // connection on which a small request takes eight seconds to the first byte, that
    // is exactly the reported "images appear late".
    //
    // Side effect, and explicitly wanted: if an image changes on the server, its tag
    // changes and with it the address. Only through this does discarding become right
    // at all — before, a year of cacheability would have held on to an old image.

    public var posterTag: String?
    public var backdropTag: String?
    public var logoTag: String?
    public var thumbTag: String?

    /// Accent color derived from the image material, see ``AccentPalette``.
    public var palette: AccentPalette?

    /// Whether the image of this entry is **wide** (16:9) and not tall (2:3).
    ///
    /// **Three states, not two** — as with ``MediaItem/hasNoEpisodes``: `true` means
    /// wide, `false` means tall, `nil` means "not checked". Only `== true` may be used
    /// to derive anything from it; "not checked" is no statement.
    ///
    /// **The finding behind it, measured on 2026-08-27:** the images of a portal are
    /// 640 × 360 (five of five checked), so exactly 16:9. They were framed at 240 × 360
    /// and filled with `.fill` — which dropped 62.5 % of the image width.
    ///
    /// **On the entry and not on the source**, because the format follows *what* an
    /// entry is, never *where* it comes from: the same rule already carries the home
    /// videos (image from the film, so wide), the channel logos and the favorites
    /// tiles. A query on the name of the source would be a fourth, contradicting answer
    /// to the same question.
    public var isWide: Bool?

    /// The poster of the **series** this entry belongs to — filled only on an episode.
    ///
    /// **The finding of 2026-09-09, on the simulator:** in the "Continue Watching" shelf
    /// films stood as a portrait poster and series as a small landscape image in a black
    /// area. On an episode ``posterID`` is the identifier of the **episode**, and the
    /// image stored there is the episode screenshot in 16 : 9 — in the 2 : 3 frame of
    /// the mixed shelf it is fitted, and the rest stays black.
    ///
    /// **The information was there and was thrown away.** The server sends `SeriesId`
    /// and `SeriesPrimaryImageTag` in the same response from which the tile is built
    /// (proven in the test data set `resume.json`); so it costs no additional query.
    ///
    /// **Optional instead of empty, for the same reason as ``chapters``:** a missing key
    /// in older snapshots on disk has to yield `nil` and no read error — otherwise the
    /// list cache would be empty after the update.
    ///
    /// **Whoever makes something of it is decided by the tile and not by
    /// ``PosterAddress``.** The TV program deliberately shows "Continue Watching" with
    /// episode cards; a change to the address rule would override that intention. The
    /// rule "here I want the series poster" is a rule of the shelf.
    public var seriesPosterID: String?

    /// The tag for ``seriesPosterID`` — for cacheability, see ``posterTag``.
    public var seriesPosterTag: String?

    public init(
        posterID: String? = nil,
        backdropID: String? = nil,
        logoID: String? = nil,
        thumbID: String? = nil,
        posterTag: String? = nil,
        backdropTag: String? = nil,
        logoTag: String? = nil,
        thumbTag: String? = nil,
        palette: AccentPalette? = nil,
        isWide: Bool? = nil,
        seriesPosterID: String? = nil,
        seriesPosterTag: String? = nil
    ) {
        self.posterID = posterID
        self.backdropID = backdropID
        self.logoID = logoID
        self.thumbID = thumbID
        self.posterTag = posterTag
        self.backdropTag = backdropTag
        self.logoTag = logoTag
        self.thumbTag = thumbTag
        self.palette = palette
        self.isWide = isWide
        self.seriesPosterID = seriesPosterID
        self.seriesPosterTag = seriesPosterTag
    }
}
