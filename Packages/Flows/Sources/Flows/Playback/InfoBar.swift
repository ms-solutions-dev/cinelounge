import Core

/// A tab in the info area of playback (the area that slides into view when
/// swiping down).
nonisolated public enum InfoTab: String, Sendable, Equatable, CaseIterable {
    /// Year, director, runtime, rating, genres and the description.
    case info
    /// The main roles, main roles first. Called **"Cast"**, not "Who is in
    /// the picture": Apple's Insight knows second by second who is in the picture, because Apple TV+ has
    /// time-coded data for it. For Jellyfin, Xtream and CL-Server there is no such data,
    /// and a tab that promises more than it delivers stands out.
    case cast = "besetzung"
    /// Further episodes of the same series, starting after the current one.
    case episodes = "folgen"
    /// Similar movies — only from your own catalog, so playable.
    case similarTitles = "aehnliches"
    /// Chapter marks to jump to.
    case chapters = "kapitel"
    /// Audio & Subtitles. Always there and always on the far right, so the hand learns the way.
    case tracks = "spuren"
}

/// Which tabs the info area shows — a pure function, so that the rule can be checked without
/// a player (AP79, 2026-10-12).
///
/// **Nobody shows an empty tab** (product decision, 2026-10-12, after comparing with
/// Apple TV, Netflix, Prime Video and Disney+): until then every title had three
/// tabs, "Who is in the picture", "More Episodes" or "Similar Movies" and "Audio &
/// Subtitles" — even for an Xtream episode without a cast and a portal movie
/// without similar items, with "no further details" behind them. Now a tab appears
/// only if the source can fill it. The skeleton stays the same everywhere: fixed
/// order, Info first, Audio & Subtitles last, only the number of tabs
/// changes.
///
/// Live channels have no info area, but the live overlay with channel list
/// and schedule (``LiveOverlay``) — there "what else is on" is the right question,
/// not "who is in it". Trailers have nothing at all.
nonisolated public enum InfoBar {

    /// What the rule needs to know about the current target.
    public struct Situation: Sendable, Equatable {
        public var kind: PlaybackTarget.Kind
        /// Whether the target belongs to a series — then the list is called "Episodes", otherwise
        /// "Similar" (``InfoBoard`` fills one or the other accordingly).
        public var series: Bool
        /// Number of main roles the board delivered.
        public var cast: Int
        /// Number of further episodes or similar movies.
        public var more: Int
        /// Ob es Kapitelmarken gibt (``ChapterJump/hasChapters(kind:chapters:)``).
        public var chapters: Bool

        public init(
            kind: PlaybackTarget.Kind, series: Bool, cast: Int, more: Int, chapters: Bool
        ) {
            self.kind = kind
            self.series = series
            self.cast = cast
            self.more = more
            self.chapters = chapters
        }
    }

    /// The tabs in display order. Empty if there is no info area.
    ///
    /// While the board is still loading, cast and further items are null, and the bar
    /// shows Info, possibly Chapters, and Audio & Subtitles; the other tabs
    /// are added as soon as the answer is there. That is more honest than a tab with a
    /// spinner that in the end says "nothing here".
    public static func tabs(_ state: Situation) -> [InfoTab] {
        guard state.kind == .recording else { return [] }
        var row: [InfoTab] = [.info]
        if state.cast > 0 { row.append(.cast) }
        if state.more > 0 { row.append(state.series ? .episodes : .similarTitles) }
        if state.chapters { row.append(.chapters) }
        row.append(.tracks)
        return row
    }

    /// The tab shown after a change of the bar: the previous one if
    /// it is still there, otherwise Info. Without this rule, after loading, content would
    /// remain whose tab no longer exists.
    public static func remains(_ previous: InfoTab, in row: [InfoTab]) -> InfoTab {
        row.contains(previous) ? previous : .info
    }
}
