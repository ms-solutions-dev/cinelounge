import Foundation

/// What lies next to the file — **so that the downloads are more than a list without network.**
///
/// **The product owner's requirement of 2026-09-09:** *"even if I only download 1 episode,
/// the navigation should be like this when I am in Downloads: poster → detail view
/// with downloaded episodes … the whole thing should be stored with OMDb, TMDb etc.
/// ratings, roughly like Jellyfin content, posters and images directly from TMDb/OMDb/IMDb."*
///
/// **The root of the finding is that nothing was stored alongside the download so far.** The
/// download list knew a title and a size; everything else — poster, year,
/// description, rating, cast — the detail page fetched from its source. Without network
/// there is no source, and that is exactly when you are in the downloads. What is not
/// written down here cannot be made up for later.
///
/// **That is why it is fetched when queueing and not when viewing.** At the time of queueing
/// there is network (otherwise there would be no download), the detail page has the details
/// in hand anyway, and a second fetch later would be exactly the one that fails on the plane.
///
/// **Images are files and not addresses.** A remembered TMDb address is an
/// empty frame without network — the same trap as above, just prettier. The fields ``poster``,
/// ``backdrop`` and ``Person/image`` therefore carry **file names in the downloads folder**, not
/// URLs; whoever reads them appends them to ``Store/folder()``.
///
/// **One description per download job, even for a series.** The summary of the
/// series is attached to each of its episodes: ten episodes then carry the same poster ten times
/// as a file name — the same file, no tenfold space. The price is a few hundred bytes of
/// JSON; the return is that a single deleted episode breaks nothing that another one
/// needs.
public struct DownloadDescription: Codable, Sendable, Equatable, Identifiable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case id
        case title = "titel"
        case beside = "neben"
        case year = "jahr"
        case description = "beschreibung"
        case series = "serie"
        case seriesTitle = "serientitel"
        case season = "staffel"
        case episode = "folge"
        case duration = "dauer"
        case ratings = "bewertungen"
        case ageRating = "altersfreigabe"
        case seriesClearance = "serienfreigabe"
        case seriesClearanceChecked = "serienfreigabeGeprueft"
        case genres = "gattungen"
        case poster = "plakat"
        case backdrop = "hintergrund"
        case cast = "besetzung"
        case ratingShares = "bewertungsanteile"
        case logo
        case seriesDescription = "serienbeschreibung"
        case episodeImage = "folgenbild"
        case storedAt = "gelegtAm"
    }

    /// The identifier of the download job this belongs to.
    public var id: String

    public var title: String
    /// The second line — "S1 E3" for an episode, the year for a film.
    public var beside: String?
    public var year: Int?
    public var description: String?

    /// Which series this belongs to — `nil` for a film.
    ///
    /// **The grouping on the downloads screen hangs on this.** "Poster → detail view with
    /// downloaded episodes" means: five episodes of a series are **one** poster, and
    /// only behind it lies the episode list. Without this identifier there would be five posters.
    public var series: String?
    public var seriesTitle: String?
    public var season: Int?
    public var episode: Int?

    public var duration: TimeInterval?

    /// The ratings as the detail page shows them — **already computed and not raw.**
    ///
    /// One value per provider (`imdb`, `tmdb`, `omdb`, `anilist`, …) as text, the way it
    /// appears on screen. **As text and not as a number:** "8,1" and "92 %" are two
    /// notations, and which one applies is known by the provider that supplies it — not by the downloads.
    public var ratings: [String: String]

    public var ageRating: String?
    /// The rating of the **series**, where an episode carries its own — the same meaning as
    /// `Core.MediaItem.seriesClearance` (check 2026-09-25, finding 6). `nil` for an episode
    /// without its own rating: there the series' rating is in ``ageRating``.
    public var seriesClearance: String?
    /// Whether the series' rating was **looked up** — `Core.MediaItem.seriesClearanceChecked`.
    ///
    /// **If it is missing on an episode, the episode counts as locked in kids mode**, as on the
    /// TV for open episodes. That affects all episodes queued before 2026-09-25:
    /// they lack the information, and a dead spot in coverage while queueing must not switch off
    /// the parental controls.
    public var seriesClearanceChecked: Bool?
    public var genres: [String]

    /// File name of the poster in the downloads folder — **not the address it was at.**
    public var poster: String?
    public var backdrop: String?

    public var cast: [Person]

    /// The share per provider, 0 to 1 — **next to ``ratings`` and not instead of it.**
    ///
    /// **Added on 2026-09-09, because the text alone is too little.** ``Rating``
    /// carries both: "8,1" for the badge and the share for the bar in the
    /// rating sheet and for the "Best first" sorting. Calculating the share back from "8,1"
    /// would mean guessing the scale — "88 %" and "8,8" look like the same
    /// value and are only so by coincidence.
    ///
    /// **The same keys as ``ratings``.** Two dictionaries each holding a part of
    /// the same number belong together via the same key; where one is missing, half the rating is missing
    /// and not a wrong one.
    public var ratingShares: [String: Double]

    /// File name of the title logo — **the header line of the screenshot.**
    ///
    /// **The product owner sent the Jellyfin detail page as the benchmark**, and there
    /// above "2007 · FSK-12 · Comedy" there is no set title but the drawn
    /// logo of the title. If it is missing, the title appears as text — it is an extra and not
    /// a requirement; see ``HeroContent/logo``.
    public var logo: String?

    /// The synopsis of the **series** — next to that of the episode and not instead of it.
    ///
    /// **Two texts, because the page has two places for them** (2026-09-09). Above it says
    /// what the series is about; in the episode list below, each row says what
    /// that episode is about. With a single field, the head of the series would show the text of
    /// episode 3 — stored correctly and yet displayed wrongly.
    ///
    /// `nil` for a film: there ``description`` is already the title's text.
    public var seriesDescription: String?

    /// File name of the episode image — **only for an episode, and not the same as
    /// ``poster``.**
    ///
    /// **Three images and not two, because an episode has three roles to fill.** The
    /// poster belongs to the **series** (it carries the tile on the downloads screen), the
    /// background too (it carries the head of the detail page) — the episode list
    /// below needs the image of the individual episode. Without this field, ten
    /// episodes would stand one under the other with the same series poster ten times.
    public var episodeImage: String?

    /// When this was stored.
    ///
    /// **For the honesty of the page and not for an expiry date.** A rating
    /// from three months ago is not false information, but it is an old one — and whoever
    /// has network again may refresh it. What expires is not decided by this file.
    public var storedAt: Date

    public struct Person: Codable, Sendable, Equatable, Identifiable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case role = "rolle"
            case image = "bild"
        }

        public var id: String
        public var name: String
        public var role: String?
        /// File name in the downloads folder — `nil` if no image was loaded.
        public var image: String?

        public init(id: String, name: String, role: String? = nil, image: String? = nil) {
            self.id = id
            self.name = name
            self.role = role
            self.image = image
        }
    }

    public init(
        id: String, title: String, beside: String? = nil, year: Int? = nil,
        description: String? = nil, series: String? = nil, seriesTitle: String? = nil,
        season: Int? = nil, episode: Int? = nil, duration: TimeInterval? = nil,
        ratings: [String: String] = [:], ageRating: String? = nil,
        genres: [String] = [], poster: String? = nil, backdrop: String? = nil,
        cast: [Person] = [], storedAt: Date = Date(),
        ratingShares: [String: Double] = [:], logo: String? = nil,
        seriesDescription: String? = nil, episodeImage: String? = nil,
        seriesClearance: String? = nil, seriesClearanceChecked: Bool? = nil
    ) {
        self.seriesClearance = seriesClearance
        self.seriesClearanceChecked = seriesClearanceChecked
        self.id = id
        self.title = title
        self.beside = beside
        self.year = year
        self.description = description
        self.series = series
        self.seriesTitle = seriesTitle
        self.season = season
        self.episode = episode
        self.duration = duration
        self.ratings = ratings
        self.ageRating = ageRating
        self.genres = genres
        self.poster = poster
        self.backdrop = backdrop
        self.cast = cast
        self.storedAt = storedAt
        self.ratingShares = ratingShares
        self.logo = logo
        self.seriesDescription = seriesDescription
        self.episodeImage = episodeImage
    }

    /// Reads older ledgers that lack the fields from 2026-09-09.
    ///
    /// **Without this path every previously stored description would be unreadable** — and because
    /// ``DescriptionLedger/read()`` decodes a **list**, not row by row,
    /// a single old row would take all the others with it. The same lesson is written down verbatim
    /// at `RatingsKit/Awards.init(from:)`, and there it saved a daily quota.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        beside = try container.decodeIfPresent(String.self, forKey: .beside)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        series = try container.decodeIfPresent(String.self, forKey: .series)
        seriesTitle = try container.decodeIfPresent(String.self, forKey: .seriesTitle)
        season = try container.decodeIfPresent(Int.self, forKey: .season)
        episode = try container.decodeIfPresent(Int.self, forKey: .episode)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        ratings = try container.decodeIfPresent([String: String].self, forKey: .ratings) ?? [:]
        ageRating = try container.decodeIfPresent(String.self, forKey: .ageRating)
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        poster = try container.decodeIfPresent(String.self, forKey: .poster)
        backdrop = try container.decodeIfPresent(String.self, forKey: .backdrop)
        cast = try container.decodeIfPresent([Person].self, forKey: .cast) ?? []
        storedAt = try container.decodeIfPresent(Date.self, forKey: .storedAt) ?? Date()
        ratingShares =
            try container.decodeIfPresent([String: Double].self, forKey: .ratingShares) ?? [:]
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        seriesDescription = try container.decodeIfPresent(
            String.self, forKey: .seriesDescription)
        episodeImage = try container.decodeIfPresent(String.self, forKey: .episodeImage)
        seriesClearance = try container.decodeIfPresent(String.self, forKey: .seriesClearance)
        seriesClearanceChecked = try container.decodeIfPresent(
            Bool.self, forKey: .seriesClearanceChecked)
    }

    /// All image files this description needs.
    ///
    /// **In one place, because cleanup needs them to be complete.** Whoever forgets one kind
    /// when deleting — today the episode image, tomorrow the logo — leaves behind files
    /// that no ledger knows any more; afterwards they are only found by
    /// ``Cleanup/orphaned(files:known:)`` and never assigned again.
    public var imageNames: [String] {
        ([poster, backdrop, logo, episodeImage] + cast.map(\.image)).compactMap { $0 }
    }
}
