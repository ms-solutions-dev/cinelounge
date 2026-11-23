import Foundation

/// "Continue Watching" and the question of where a series opens — **one rule for
/// both apps** (AP58 R6, St2).
///
/// **What had diverged** (report A): The TV strung together the started titles
/// from Jellyfin, provider and portals without de-duplicating; the phone merged
/// history and server and de-duplicated. And if a series was fully watched, the TV
/// opened the **last** season, the phone the **first** episode.
public nonisolated enum ContinueWatching {

    /// This many titles "Continue Watching" carries per source — **both apps the
    /// same.**
    ///
    /// Twenty like every other shelf. Until AP58 R6 the TV asked for twelve; the same
    /// row with two lengths on two devices has no recognizable identity.
    public static let perSource = 20

    /// Merges lists in their order of precedence — **the first mention wins,
    /// duplicates are dropped.**
    ///
    /// The same title can be in the history and at the server, or at two sources. It
    /// appears once, at the position of the higher-ranked list. Which version of the
    /// tile stands there is decided by the caller via `ersetze` — the phone takes the
    /// position from the history and the content from the server (one number the same
    /// everywhere).
    public static func mix<Title>(
        _ listen: [[Title]], identifier: (Title) -> String,
        ersetze: (Title) -> Title = { $0 },
        recent: ((Title) -> Date?)? = nil
    ) -> [Title] {
        var seen = Set<String>()
        let unique = listen.flatMap { $0 }
            .filter { seen.insert(identifier($0)).inserted }
            .map(ersetze)
        guard let recent else { return unique }
        return arrange(unique, recent: recent)
    }

    /// **Most recently watched first, no matter where from** (requirement, 2026-09-28)
    /// — as with every service you know. Without a timestamp to the back, and there in
    /// the order in which they arrived: The sort is stable so that two runs show the
    /// same row.
    public static func arrange<Title>(_ title: [Title], recent: (Title) -> Date?) -> [Title] {
        title.enumerated().sorted { a, b in
            switch (recent(a.element), recent(b.element)) {
            case (let x?, let y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The season with which a series opens: **the first one with unwatched episodes.**
    ///
    /// **If everything is watched, the last one** — anyone who has finished a series
    /// looks for the newest episode and not the oldest. That is the TV's rule; the
    /// phone opened the first one until AP58 R6. **If nobody knows anything about the
    /// state** (no season reports a number), the first: "everything watched" would
    /// otherwise be a claim.
    ///
    /// **Specials do not count** (review 2026-09-27, D3). Jellyfin lists them as
    /// season 0 and puts them first; with an unwatched special the page opened there
    /// and the main button played "Special 1" instead of S2E1. Specials are extras and
    /// not a position in the series. **Only if there are nothing but such seasons** does
    /// the rule apply to them. A season without a number counts like season 0
    /// (``isSpecialSeason(_:)``).
    ///
    /// - Parameters:
    ///   - nummer: the season number, `nil` for unknown. On the TV
    ///     ``seasonNumber(_:)``, on the phone the number of its group.
    ///   - offen: how many episodes of the season are unwatched, `nil` for unknown.
    public static func startSeason<Season>(
        in seasons: [Season], number: (Season) -> Int?, pending: (Season) -> Int?
    ) -> Season? {
        let regular = seasons.filter { !isSpecialSeason(number($0)) }
        let candidates = regular.isEmpty ? seasons : regular
        guard !candidates.isEmpty else { return nil }
        if let running = candidates.first(where: { (pending($0) ?? 0) > 0 }) { return running }
        if candidates.contains(where: { pending($0) != nil }) { return candidates.last }
        return candidates.first
    }

    /// Whether a season number means the specials: **0, and likewise no number.**
    ///
    /// The phone has always put episodes without a season value into group 0; a season
    /// without a number is, in Jellyfin, usually a folder with extras. Treating both
    /// as a season of their own would mean that a title without a value opens the
    /// series.
    public static func isSpecialSeason(_ number: Int?) -> Bool { (number ?? 0) == 0 }

    /// The number of a season as a title — **`seasonNumber`, otherwise
    /// `episodeNumber`.**
    ///
    /// Jellyfin sends the season number of a season as `IndexNumber`, and the mapping
    /// puts `IndexNumber` into ``MediaItem/episodeNumber`` (the season has no
    /// `ParentIndexNumber`). Portals set ``MediaItem/seasonNumber``. Anyone who asks a
    /// season for its number asks here and not at one of the two fields.
    public static func seasonNumber(_ season: MediaItem) -> Int? {
        season.seasonNumber ?? season.episodeNumber
    }

    /// Which episode the main button plays: **the started one, otherwise the first
    /// unwatched, otherwise the first.**
    ///
    /// Started means ``PlaybackProgress/isResumable`` — the same threshold after which
    /// playback resumes (AP58 R0). Until R6 the phone read its own (1 % to 99 %), and an
    /// episode at 97 % counted as started there but then played from the beginning.
    public static func nextEpisode(from episodes: [MediaItem]) -> MediaItem? {
        if let started = episodes.first(where: { $0.progress?.isResumable == true }) {
            return started
        }
        return episodes.first { $0.progress?.isWatched != true } ?? episodes.first
    }
}
