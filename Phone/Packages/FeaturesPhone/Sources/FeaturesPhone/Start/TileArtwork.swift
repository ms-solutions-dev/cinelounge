import Core
import Flows
import Foundation
import RatingsKit

/// From the server's title to the tile.
///
/// **In one place**, so that the rules do not differ per shelf. Five of them are not
/// obvious:
///
/// * **Progress only if it is one.** `progress` is also set on a title that has been
///   watched completely, and on one that stands at zero. A bar at 0 % says "something has
///   been started here", and then that is not true.
/// * **The counter only counts for a started series**, and it carries its unit. See
///   ``counter(_:)`` — the rule was the wrong way round until 2026-09-05.
/// * **Otherwise the rating is there.** The top right spot on the tile is the most
///   valuable one it has; leaving it empty on every series that has not been started would
///   be a waste.
/// * **`Core.PosterAddress` decides the image address**: poster, otherwise preview image,
///   otherwise background image, otherwise **none**. A `?? item.id` as a fallback would be
///   the instruction to request an image that is already known to be missing — exactly the
///   finding of 2026-08-22 that produced a 404 per tile.
/// * **An episode also names its series.** Label and image have long been those of the
///   series; without ``series(_:)`` the identifier would remain that of the episode, and a
///   press on it would lead to a detail page without seasons.
/// * **And it shows the poster of its series**, see ``seriesPoster(_:source:width:)`` —
///   the only place where the address does **not** come from `PosterAddress`, and the
///   reason for that is stated there.
enum TileArtwork {

    static func tile(
        _ title: MediaItem, source: any ContentSource, width: Int
    ) -> TileContent {
        let pending = counter(title)
        let seriesImage = seriesPoster(title, source: source, width: width)
        var tile = TileContent(
            id: title.id,
            title: label(title),
            beside: secondaryLine(title),
            image: seriesImage ?? PosterAddress.url(for: title, from: source, width: width),
            backdrop: backdrop(title, source: source, width: width),
            // **This too was available and was thrown away** — the same kind of finding as with
            // `bild_breit` a day earlier, and in the same call. `MediaItem.runtime` is filled by
            // every source; it is needed by "For the trip", because packing is done against a flight
            // duration.
            duration: title.runtime,
            progress: progress(title),
            seen: title.progress?.isWatched ?? false,
            state: state(title),
            favorite: title.isFavorite,
            counter: pending,
            rating: pending == nil ? rating(title) : nil,
            // **Both, and the server decides which one it carries.** Jellyfin reports `DateCreated`,
            // the provider its field `added` — the same information under two names. Anyone who takes
            // only one has no sorting for the other source.
            added: title.addedAt ?? title.recordedAt,
            series: series(title),
            // **The information was available and was thrown away** (finding of 2026-09-07). The bridge
            // sends `bild_breit`, `PortalKit` writes it to `Artwork.isWide`, and `Core` is shared —
            // until here it never arrived. See ``TileContent/wide``.
            //
            // **With the series poster a wide tile becomes a tall one**, and that has to happen in the
            // same step: `isWide` describes the image of the **episode**. If it stayed, ``PosterTile``
            // would fit the 2 : 3 poster into the 2 : 3 frame instead of filling it — the same black
            // area as before, only with the right image in it.
            wide: seriesImage == nil ? title.artwork.isWide : false,
            anime: AnimeQuery.from(title))
        tile.recent = title.lastWatched
        tile.audio = PosterCorner.audioBadge(title)
        return tile
    }

    /// The poster of the **series** instead of the episode image — see
    /// ``Core/Artwork/seriesPosterID``.
    ///
    /// **The finding of 2026-09-09, on the simulator:** in the "Continue Watching" shelf, movies
    /// appeared as a portrait poster, series as a small landscape image in a black area. The
    /// cause is not the address but the identifier: on an episode `posterID` is that of the
    /// episode, and behind it lies the episode screenshot in 16 : 9 format.
    ///
    /// **The rule belongs to the tile and not to ``PosterAddress``.** The TV program
    /// deliberately shows the same shelf with episode cards; anyone who changed the address
    /// rule would overwrite its decision from here. What is decided here is a rule of this
    /// shelf: equal tiles in a row.
    ///
    /// **Tied to the kind and not to the field** — the same reasoning as in ``series(_:)``: a
    /// season also carries a series identifier, and a series that substitutes itself as a
    /// poster would be no gain but a second source for the same image.
    ///
    /// **Without a series poster, everything stays as before.** Not every series has one; the
    /// episode screenshot is then better information than an empty frame.
    static func seriesPoster(
        _ title: MediaItem, source: any ContentSource, width: Int
    ) -> URL? {
        guard title.kind == .episode, let identifier = title.artwork.seriesPosterID else {
            return nil
        }
        return source.imageURL(
            itemID: identifier, kind: .primary, width: width,
            tag: title.artwork.seriesPosterTag)
    }

    /// Which series this tile belongs to — **`nil` for everything that is not an episode.**
    ///
    /// **The tile looked like the series and carried the episode.** "Continue Watching" is
    /// filled from `resumable(limit:)`, and Jellyfin delivers **episodes** there. Label and
    /// image have long taken the series (see ``label(_:)``), the identifier stayed that
    /// of the episode — a press on it therefore led to a detail page without a season picker,
    /// without an episode list and without the series' similar titles.
    ///
    /// **Nothing is fetched afterwards.** `listFields` requests `SeriesId` anyway, and
    /// `ItemMapping` maps it onto `MediaItem.seriesID`; it was only lost here.
    ///
    /// **Tied to the kind and not to the field.** Jellyfin also carries `SeriesId` on a
    /// **season**, and other sources fill it by their own rules. A series that opens itself via
    /// a detour would be the most expensive wrong turn here — which is why the kind decides and
    /// not whether something happens to be there.
    static func series(_ title: MediaItem) -> String? {
        title.kind == .episode ? title.seriesID : nil
    }

    /// From the same title, the header area.
    ///
    /// The hero gets what a tile does not carry: the logo, the blurb and the attribute line.
    /// The rating appears here **always**, even for a started series — in the box there is room
    /// for both, on a tile 110 points wide there is not.
    static func held(
        _ title: MediaItem, source: any ContentSource, width: Int, logoWidth: Int
    ) -> HeroContent {
        HeroContent(
            tile: tile(title, source: source, width: width),
            logo: logo(title, source: source, width: logoWidth),
            description: title.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
            attributes: attributes(title),
            ratings: ratings(title),
            identifier: RatingID(
                imdb: title.ratings.imdbID, anilist: title.ratings.anilistID,
                tmdb: title.ratings.tmdbID,
                // Only for series and movies: an episode carries the episode's TVDB number.
                tvdb: title.kind == .series || title.kind == .movie ? title.ratings.tvdbID : nil,
                search: title.year.flatMap { year in
                    title.kind == .movie || title.kind == .series
                        ? .init(title: title.title, year: year, series: title.kind == .series) : nil
                }),
            approval: title.ageRating)
    }

    /// The background image, if there is one — and **only** then.
    ///
    /// No fallback to the poster: a 2 : 3 image in a 16 : 9 box is either distorted or cropped
    /// to a section in which there is usually nothing.
    static func backdrop(
        _ title: MediaItem, source: any ContentSource, width: Int
    ) -> URL? {
        guard let identifier = title.artwork.backdropID else { return nil }
        return source.imageURL(
            itemID: identifier, kind: .backdrop, width: width, tag: title.artwork.backdropTag)
    }

    static func logo(_ title: MediaItem, source: any ContentSource, width: Int) -> URL? {
        guard let identifier = title.artwork.logoID else { return nil }
        return source.imageURL(
            itemID: identifier, kind: .logo, width: width, tag: title.artwork.logoTag)
    }

    /// For an episode the series is on top, not the episode title: in a "Continue Watching"
    /// shelf you look for the series and not for the fourth episode.
    static func label(_ title: MediaItem) -> String {
        if title.kind == .episode, let series = title.parentTitle { return series }
        return title.title
    }

    static func secondaryLine(_ title: MediaItem) -> String? {
        if title.kind == .episode {
            if let identifier = title.episodeIdentifier { return identifier }
            return title.title
        }
        return title.year.map(String.init)
    }

    /// Position, year, age rating, up to two genres.
    ///
    /// **For an episode the position comes first.** The header area carries the series name at
    /// the top; without "S1 E22" it would not be visible that this is about a started series,
    /// and the blurb below it — that of a single episode — would come out of nowhere.
    ///
    /// **Two genres and not all.** On some titles the server carries seven; showing them all
    /// fills the line with "Action · Adventure · Fantasy · Science Fiction" and pushes
    /// position, year and rating out of the picture — the information that anyone looks for in
    /// the first place.
    static func attributes(_ title: MediaItem) -> [String] {
        var split: [String] = []
        if title.kind == .episode, let location = secondaryLine(title) { split.append(location) }
        if let year = title.year { split.append(String(year)) }
        if let approval = title.ageRating, !approval.isEmpty { split.append(approval) }
        split += title.genres.prefix(2)
        return split
    }

    /// Where you stand on this title — **for a series, calculated via its episodes.**
    ///
    /// **The finding of 2026-09-05:** the library filter "Started" produced an empty list for
    /// twenty-three series. Jellyfin carries `UserData.PlayedPercentage` only on episodes and
    /// movies; on a series there is never anything there, and `isWatched` is just as empty.
    /// What a series **does** carry are `unplayedCount` and `episodeCount` — from these the
    /// state follows without a single additional request:
    ///
    /// * no open episode → **finished**
    /// * all open → **untouched**
    /// * in between → **started**
    ///
    /// **Without both numbers nothing is claimed.** A series for which the server reports no
    /// episode count counts as untouched — and not as started, because "I have already looked
    /// in here once" is the stronger statement of the two.
    ///
    /// **Since decision 27 (C6) the rule is in ``Flows/WatchState/forItem(_:)``** — the TV now
    /// filters its library by it.
    static func state(_ title: MediaItem) -> WatchState {
        WatchState.forItem(title)
    }

    /// Only between the first and the last percent — ``Flows/WatchState/portion(_:)``.
    static func progress(_ title: MediaItem) -> Double? {
        WatchState.portion(title)
    }

    /// How many episodes are still open — **only for a started series**.
    ///
    /// **The finding of 2026-09-05** ("Skeblus deitseflaum Poblaplal · 1 new — but the series has 87 episodes
    /// and 4 seasons"). The number was right: `unplayedCount` are the **unwatched** episodes,
    /// and of 87 exactly one was open. The word was wrong. "New" means added, and for a series
    /// from 2013 that was not a single one.
    ///
    /// **And for a series that was never started, the number says nothing.** It is then equal
    /// to the episode count — "269 new" on *The Flaihuski Freipri Taspreis* is the series length in a red
    /// capsule. It only becomes information once you are in: "17 episodes left" answers the
    /// question you ask yourself before continuing to watch.
    static func counter(_ title: MediaItem) -> String? {
        PosterCorner.remainingEpisodes(title).map { AppLanguageSetting.text("tile.remaining \($0)") }
    }

    /// What the server supplies about the title in the way of ratings.
    ///
    /// Costs no request: both numbers are in the response with which the tile is built anyway.
    /// What comes in from the network — IMDb, AniList — replaces it later and only for the
    /// hero; see ``RatingSource``.
    static func rating(_ title: MediaItem) -> Rating? {
        Rating.forItem(title)
    }

    /// All that the server supplies.
    static func ratings(_ title: MediaItem) -> [Rating] {
        [
            Rating.fromTen(title.ratings.imdb, .imdb),
            Rating.fromTen(title.ratings.community, .community),
            Rating.fromHundred(title.ratings.critic, .critics),
        ].compactMap { $0 }
    }
}
