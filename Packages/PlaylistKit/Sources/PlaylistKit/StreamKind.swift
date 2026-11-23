import Core
import Foundation

/// What is behind an entry: a live channel, a movie or a series
/// episode.
///
/// **With Xtream this is cleanly separated** — there are separate fetches for channels,
/// movies and series. With an M3U file everything is in one list, and the
/// separation has to be recognized by hand. That is exactly what this type is for.
public enum StreamKind: String, Sendable, Equatable, CaseIterable {
    case live
    case movie
    case episode
}

extension StreamKind {

    /// Recognizes the kind of an entry from what an M3U provides.
    ///
    /// There is no reliable marker — so several
    /// clues are **weighted** instead of taking the first. The order is
    /// sorted by reliability, and the reasoning is given at each step:
    ///
    /// 1. **The path in the address.** `/live/`, `/movie/`, `/series/` is the
    ///    Xtream convention and is followed by most providers, even
    ///    by those that only deliver an M3U. This is the strongest hint.
    /// 2. **The file extension.** `.ts` and `.m3u8` are live streams, `.mp4` and
    ///    `.mkv` are files. Reliable where present — only it is often missing.
    /// 3. **The group name.** "VOD", "Filme", "Movies", "Series" say it
    ///    explicitly. Weaker than the other two, because freely chosen, but
    ///    often the only thing there is.
    /// 4. **The duration.** `-1` actually means "runs endlessly", a real number
    ///    "has an end". Comes **last**, although it would be the official
    ///    marker: Many generators blindly write `-1` into every line,
    ///    even for movies. A clue that mostly lies must not come
    ///    first.
    ///
    /// **When in doubt `live`.** A movie that accidentally sits in the channel list
    /// is a cosmetic flaw — you see it and move on. A
    /// channel that is accidentally treated as a movie **disappears** from the
    /// channel list, and nobody knows where it went. The more harmless error
    /// wins.
    public static func detect(
        duration: Double?,
        url: URL?,
        group: String?
    ) -> StreamKind {
        // 1. The path — strongest hint.
        if let path = url?.path.lowercased() {
            if path.contains("/series/") { return .episode }
            if path.contains("/movie/") { return .movie }
            if path.contains("/live/") { return .live }
        }

        // 2. The file extension. If it contradicts the path, the path has already
        //    decided — only what the path did not settle arrives here.
        if let suffix = url?.pathExtension.lowercased(), !suffix.isEmpty {
            if Self.liveExtensions.contains(suffix) { return .live }
            if Self.fileExtensions.contains(suffix) {
                // A file is a movie or an episode. Which of the two is told at
                // this point only by the group name.
                return Self.groupSuggestsSeries(group) ? .episode : .movie
            }
        }

        // 3. The group name.
        if let hint = Self.kindFromGroup(group) { return hint }

        // 4. The duration, as the last and weakest marker.
        if let duration, duration > 0 { return .movie }

        return .live
    }

    /// Extensions of live streams.
    static let liveExtensions: Set<String> = ["ts", "m3u8", "mpd"]

    /// Extensions of files that have an end.
    static let fileExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "webm"]

    /// Words that mark a group as on-demand.
    ///
    /// Multilingual, because channel lists are. The emojis that almost always precede such
    /// group names play no role — the search runs in the
    /// lowercased text.
    static let movieWords = ["vod", "film", "movie", "kino", "cinema", "pelicula"]

    /// Words that mark a group as a series.
    static let seriesWords = ["serie", "series", "dizi", "staffel", "season", "show"]

    static func kindFromGroup(_ group: String?) -> StreamKind? {
        guard let group = group?.lowercased(), !group.isEmpty else { return nil }

        // Check series first: "VOD | Serien" contains both words, and the
        // more precise indication is the series.
        if seriesWords.contains(where: group.contains) { return .episode }
        if movieWords.contains(where: group.contains) { return .movie }
        return nil
    }

    static func groupSuggestsSeries(_ group: String?) -> Bool {
        kindFromGroup(group) == .episode
    }
}
