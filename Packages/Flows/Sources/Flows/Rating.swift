import Core
import Foundation

/// A number that says what others think of a title.
///
/// **Four services, four scales, one display.** IMDb and MyAnimeList count to ten, the
/// critics' portals to a hundred, and the media server passes through whatever is set at its
/// metadata provider. Comparison therefore uses ``portion``; what is shown is
/// ``text``, in the scale of the respective service — converting "88 %" into "8.8"
/// would produce a number that exists nowhere and that nobody recognises.
///
/// **Zero is not a rating.** All four services deliver a zero for a title nobody
/// has voted on — and Xtream sends it with every second entry. A displayed "0.0" would look
/// like a devastating verdict. Ratings are therefore created only via the two builders,
/// and they return ``nil`` for zero.
nonisolated public struct Rating: Sendable, Equatable {

    public enum Origin: Sendable, Equatable, CaseIterable {
        /// Supplied by the media server. Depending on its setting TMDb or IMDb —
        /// it does not say which of the two.
        case community
        case imdb
        /// MyAnimeList — since AP68 (2026-10-07) in place of the AniList score.
        case mal
        /// Critics in percent; for Jellyfin the Rotten Tomatoes field.
        case critics
        /// Metacritic — **its own origin, not a second critics' number.**
        ///
        /// Until 09-05 Rotten Tomatoes and Metacritic both carried ``critics``. On
        /// a tile this went unnoticed, because only one number is shown there; in the
        /// badge row two badges with the same label and
        /// different numbers then stood side by side — which looks as if the
        /// app contradicts itself. They are two services with two methods: Rotten Tomatoes counts the
        /// share of favourable reviews, Metacritic averages weighted scores.
        case metacritic
    }

    public let origin: Origin

    /// The value as a share between 0 and 1 — the only form in which four scales
    /// can be compared.
    public let portion: Double

    /// Ready-formatted and localised: "8.4" or "88 %".
    public let text: String

    public init(origin: Origin, portion: Double, text: String) {
        self.origin = origin
        self.portion = portion
        self.text = text
    }

    public var originKey: String {
        switch origin {
        case .community: "rating.community"
        case .imdb: "rating.imdb"
        case .mal: "rating.mal"
        case .critics: "rating.critic"
        case .metacritic: "rating.metacritic"
        }
    }

    /// From a ten-point scale — IMDb, MyAnimeList and the community rating. MyAnimeList with
    /// two decimals as on myanimelist.net: "9.25" is recognisable, "9.3" is not.
    public static func fromTen(_ value: Double?, _ origin: Origin) -> Rating? {
        guard let value, value > 0, value <= 10 else { return nil }
        return Rating(
            origin: origin,
            portion: value / 10,
            text: value.formatted(.number.precision(.fractionLength(origin == .mal ? 2 : 1))))
    }

    /// From a percentage scale — the critics' portals.
    public static func fromHundred(_ value: Int?, _ origin: Origin) -> Rating? {
        guard let value, value > 0, value <= 100 else { return nil }
        return Rating(
            origin: origin,
            portion: Double(value) / 100,
            text: (Double(value) / 100).formatted(.percent.precision(.fractionLength(0))))
    }

    /// From a points scale — Metacritic.
    ///
    /// **Without a percent sign, and that is the difference from ``fromHundred(_:_:)``.**
    /// Metacritic awards 0 to 100 **points**; "88 %" would be a claim about a
    /// method that nobody applies there. Rotten Tomatoes, on the other hand, really counts a
    /// share, and there the sign is right.
    public static func fromPoints(_ value: Int?, _ origin: Origin) -> Rating? {
        guard let value, value > 0, value <= 100 else { return nil }
        return Rating(
            origin: origin, portion: Double(value) / 100, text: value.formatted(.number))
    }

    /// Which of several is shown.
    ///
    /// The order is a ranking, and every place has a reason:
    ///
    /// * **MyAnimeList first.** That a MAL number exists at all means that the
    ///   title is anime — and there critics' portals have nothing and IMDb has few votes.
    /// * **Then IMDb.** Of all four the one with the most votes.
    /// * **Then the community rating.** It costs no request, because the server
    ///   supplies it; in return nobody knows which provider it comes from.
    /// * **Critics last.** A different scale and a different question — not "did
    ///   people like it", but "was it well made". Rotten Tomatoes before
    ///   Metacritic, because its share number is readable without knowing the method.
    /// **The one rating that goes on a poster** — the same on TV and phone
    /// (2026-09-29). Until then only the phone computed it (`TileArtwork`), and
    /// the TV showed none; now the rule lives here, in `Flows`, which both
    /// apps use.
    ///
    /// **With the MAL rating, if it has already been fetched for the poster** (AP68) — for anime
    /// it comes before all others.
    public static func forItem(_ title: MediaItem, mal: Double? = nil) -> Rating? {
        best(from: [
            fromTen(mal, .mal),
            fromTen(title.ratings.imdb, .imdb),
            fromTen(title.ratings.community, .community),
            fromHundred(title.ratings.critic, .critics),
        ])
    }

    public static func best(from downloads: [Rating?]) -> Rating? {
        let available = downloads.compactMap { $0 }
        for origin in [Origin.mal, .imdb, .community, .critics, .metacritic] {
            if let match = available.first(where: { $0.origin == origin }) { return match }
        }
        return nil
    }
}

/// The information at the top right of a poster — **the same ranking on both devices**
/// (2026-09-29): first the open episodes, otherwise the rating. Watched and favourite are
/// at the top left.
public nonisolated enum PosterCorner {

    /// How many episodes are still open — `nil` if none or all (then the series
    /// is not started, and the number would say nothing that "unwatched" does not already say).
    public static func remainingEpisodes(_ title: MediaItem) -> Int? {
        guard let pending = title.unplayedCount, pending > 0 else { return nil }
        guard let total = title.episodeCount, pending < total else { return nil }
        return pending
    }

    /// The language badge below the information — **only if there is no German audio** (AP84).
    ///
    /// "Die Briasle" had ten mirrors at Filmhub on 2026-11-08, all `(EN)`; it was noticed
    /// by the audio. `DE` next to `EN` is the normal case and gets nothing, only
    /// German subtitles are `OmU`, otherwise the first language (`EN`). Unknown (`nil` or
    /// empty) shows nothing.
    public static func audioBadge(_ title: MediaItem) -> AudioBadge? {
        guard let languages = title.languages?.filter({ !$0.isEmpty }), !languages.isEmpty else {
            return nil
        }
        let lowercased = languages.map { $0.lowercased() }
        if lowercased.contains(where: { $0 == "de" || $0 == "deu" || $0 == "ger" }) { return nil }
        if lowercased.contains("ger-sub") { return .originalWithSubtitles }
        return .language(String(languages[0].uppercased().prefix(3)))
    }

    /// What the corner shows, and what the screen-reader aid says about it.
    public enum AudioBadge: Equatable, Sendable {
        case originalWithSubtitles
        case language(String)

        /// The text in the capsule — short, because it has to fit on a poster.
        public var short: String {
            switch self {
            case .originalWithSubtitles: "OmU"
            case .language(let code): code
            }
        }

        /// The sentence for VoiceOver — spelled out, because "EN" read aloud helps nobody.
        public var spoken: String {
            switch self {
            case .originalWithSubtitles: AppLanguageSetting.text("tile.audio.omu")
            case .language(let code): AppLanguageSetting.text("tile.audio \(code)")
            }
        }
    }
}
