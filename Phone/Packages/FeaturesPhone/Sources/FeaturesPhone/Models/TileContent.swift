import Flows
import Foundation
import RatingsKit

/// What stands on a tile.
///
/// Deliberately **not** `Core.MediaItem`: A tile should be able to show what it is given
/// and not know where it comes from. The same tile carries a Jellyfin title, an Xtream film
/// without an image and a portal entry — the mapping onto it belongs to the respective area
/// and not here.
public struct TileContent: Sendable, Equatable, Identifiable {

    public let id: String
    public let title: String
    /// The second line — year, season, channel.
    public let beside: String?
    public let image: URL?

    /// The background image, 16 : 9.
    ///
    /// Only the hero needs it. A tile never shows it — a 16 : 9 image in a 2 : 3 frame is
    /// cropped, and what falls away is usually the subject.
    public var backdrop: URL?

    /// How far along you are, 0 to 1. `nil` means "not started" and not "at zero".
    /// How long the title runs — **`nil` where the service does not say.**
    ///
    /// **The information was there and was thrown away** (finding of 2026-09-08, and it is the same
    /// as the day before with `bild_breit`): `MediaItem.runtime` stands in `Core`, every source
    /// fills it, and up to here it never arrived. It is needed by "For the trip": Packing is
    /// done against a **flight duration**, and without a runtime every plan is a guess.
    ///
    /// **And the remaining time is the right number, not the runtime.** Whoever stopped at
    /// minute 94 of 130 takes 36 minutes along and not 130 — see ``remaining``.
    public let duration: TimeInterval?

    /// What is still outstanding of this title.
    ///
    /// **For "Continue Watching" this is the quantity that matters.** A plan that calculates
    /// the full runtime packs for a trip that is already half behind you.
    public var remaining: TimeInterval? {
        guard let duration else { return nil }
        return duration * (1 - (progress ?? 0))
    }

    public let progress: Double?
    public let seen: Bool
    /// What the tile asks MyAnimeList for when it is visible (AP68) — only series and film with
    /// an identifier; for anime the MAL rating replaces the server's.
    public let anime: AnimeQuery?

    /// Where the title stands as a whole.
    ///
    /// **The finding of 2026-09-05, seen on the screen:** The library filter "Started" gave an
    /// empty list for 23 series. It asked for ``progress``, and Jellyfin carries that **only
    /// on episodes and films** — on a series nothing ever stands there. "Unwatched" was the
    /// same error with the opposite sign: It asked for ``seen``, and because that never
    /// stands on a series either, it would have shown **all** twenty-three — including the ones
    /// watched through.
    ///
    /// Both fields are right and stay: A bar on a tile needs a proportion, and a checkmark
    /// needs a yes. What was missing was the answer to "where do I stand with this title" — and
    /// for a series that is a calculation over its episodes.
    public let state: WatchState

    /// Marked by yourself. For the favorites excerpt of the library.
    public let favorite: Bool

    /// The number on the tile — **always with its unit**, never bare.
    public let counter: String?

    /// What others think of the title.
    ///
    /// It stands where the counter stands for a started series, and steps back behind it:
    /// Whoever is at episode 22 wants to know how many are still to come, and has long since
    /// formed a judgement of the series.
    public let rating: Rating?

    /// When the title was added — for the sort order "Newest first".
    ///
    /// **It never appears on the screen**, and still belongs here: A sort order that accesses a
    /// field the tile does not carry would have to drag the server response along a second
    /// time — and then there would be two truths about the same title.
    public let added: Date?

    /// When the running programme ends — **only for a channel.**
    ///
    /// **A point in time and no remaining time**, and that is the point: A calculated "23 min
    /// left" is wrong in ten minutes, and the Home screen stays put for minutes while you flip
    /// through the shelves. The row recalculates from the end every time.
    ///
    /// `nil` for everything that has no running programme — that is, for every film.
    public let runsUntil: Date?

    /// The badges on the image: `1080p`, `DE·JA`, FSK, "5 days left".
    public let marks: [Brand]

    /// Which series this tile belongs to — `nil` for everything that is not an episode.
    ///
    /// **Why it travels along** (finding of 2026-09-07, on the device): The shelf "Continue
    /// Watching" shows episodes. But the tile carries series image, series name and "S1 E3" —
    /// it **looks like the series** and opened the detail page of the **episode**. That has no
    /// season picker, no episode list and none of the series' similar titles: a page with a
    /// single button where a whole series belongs.
    ///
    /// **On the TV the same finding was already fixed on 2026-08-12** — there an episode leads to
    /// its series. `entwuerfe/ENTSCHEIDUNGEN.md` E4 explicitly demands functional parity; a
    /// stripped-down detail page was the point where the phone looks like a second device.
    ///
    /// **No additional request.** Jellyfin delivers `SeriesId` in the same response from which
    /// the tile is built; it was lost only in the mapping.
    public let series: String?

    /// Whether the image is **wide** (16 : 9) rather than tall (2 : 3) — `nil` means "not
    /// checked".
    ///
    /// **Three states and not two.** A `Bool` defaulting to `false` claimed of every unchecked
    /// source that its images were tall — a statement without basis, and in a mixed level it
    /// outvoted the checked ones. The same reasoning stands at ``PortalKit`` at the field
    /// `bild_breit` of the bridge.
    ///
    /// **The finding of 2026-09-07, on the device:** A portal delivers images in landscape format
    /// (640 × 360). **Filled** into the 110 × 165 poster frame, 62,5 % of the width falls away
    /// — with an image that has the title on it, a crop remains without the beginning and end
    /// of the word. The TV has decided this correctly since 2026-08-27; on the phone the
    /// information was read and thrown away — it stands in `Core.Artwork.isWide` and never
    /// reached the tile.
    ///
    /// **Two layers hang on it, exactly as on the TV.** The level chooses its frame
    /// (``TileContent/isWideShelf(_:)``), and the tile no longer fills a wide image in a tall
    /// frame but places it whole on the backing plate (``PosterTile``). The second layer
    /// carries exactly the cases that the first cannot decide: a mixed level.
    public let wide: Bool?
    /// When this title last played — **"Continue Watching" orders by it, no matter where it
    /// comes from**, the same rule as on the TV (``Core/ContinueWatching/arrange(_:recent:)``,
    /// 2026-09-28).
    public var recent: Date?
    /// The language corner under the information at top right (AP84) — the same rule as on the
    /// TV, ``Flows/PosterCorner/audioBadge(_:)``. `nil` means: German or unknown.
    public var audio: PosterCorner.AudioBadge?

    /// Whether a **level** is drawn in wide format.
    ///
    /// **The level decides, not the tile.** A shelf of alternating 2 : 3 and 16 : 9 has no row
    /// along which the eye runs any more, and a grid made of it no columns. The same rule and
    /// the same wording as on the TV (`MediaItem.prefersWideArtwork(in:)`); deciding it a
    /// second time here would mean having two truths about the same image.
    ///
    /// Wide only if at least one tile reports wide **and none** reports tall. When in doubt,
    /// tall — that is the frame in which the app draws everything anyway, and a wide image
    /// framed upright stands completely on its plate thanks to ``PosterTile``. The other way
    /// round, a poster in a wide frame would be cropped by two thirds.
    public static func isWideShelf(_ tiles: [TileContent]) -> Bool {
        if tiles.contains(where: { $0.wide == false }) { return false }
        return tiles.contains { $0.wide == true }
    }

    public struct Brand: Sendable, Equatable, Identifiable {
        public let id: String
        public let text: String
        public let kind: Kind

        public enum Kind: Sendable, Equatable {
            /// Usual — resolution, language.
            case plain
            /// Hervorgehoben — Auszeichnungen.
            case gold
            /// Quieter than the rest — runtime, year.
            case quiet
        }

        public init(id: String = UUID().uuidString, text: String, kind: Kind = .plain) {
            self.id = id
            self.text = text
            self.kind = kind
        }
    }

    public init(
        id: String,
        title: String,
        beside: String? = nil,
        image: URL? = nil,
        backdrop: URL? = nil,
        duration: TimeInterval? = nil,
        progress: Double? = nil,
        seen: Bool = false,
        state: WatchState = .untouched,
        favorite: Bool = false,
        counter: String? = nil,
        rating: Rating? = nil,
        added: Date? = nil,
        runsUntil: Date? = nil,
        marks: [Brand] = [],
        series: String? = nil,
        wide: Bool? = nil,
        anime: AnimeQuery? = nil
    ) {
        self.id = id
        self.title = title
        self.beside = beside
        self.image = image
        self.backdrop = backdrop
        self.duration = duration
        self.progress = progress
        self.seen = seen
        self.state = state
        self.favorite = favorite
        self.counter = counter
        self.rating = rating
        self.anime = anime
        self.added = added
        self.runsUntil = runsUntil
        self.marks = marks
        self.series = series
        self.wide = wide
    }
}

extension TileContent {
    /// Whether a tap in "Continue Watching" **plays right away** instead of opening the detail
    /// page.
    ///
    /// **Continue Watching means continue watching** (user request 2026-10-01, as on the TV):
    /// Whoever taps there has already chosen the title. The tile does not know its kind —
    /// the decision is made by progress: Only what has been started has a spot where it
    /// continues. A channel has its own way and plays on a tap anyway.
    func playsInHistory(origin: Catalog.Origin?) -> Bool {
        origin != .channelList && (progress ?? 0) > 0
    }

    /// The spot where playback continues — from proportion and runtime.
    var resumePosition: TimeInterval {
        guard let duration, let progress else { return 0 }
        return duration * progress
    }
}
