import Core
import Foundation

/// Jumping from chapter to chapter — **the same rule on both devices** (AP58 G1, A5).
///
/// Until then it lived in the TV's `PlayerModel`; the phone showed chapters only as a
/// row on the detail page. The lead-in when skipping forward and the grace period when going back are defined
/// on ``Core/Chapter``; here is when there are buttons and where they lead.
nonisolated public enum ChapterJump {

    /// Whether there are chapter jump targets.
    ///
    /// **From two marks:** a single one is almost always at zero and would offer only the
    /// start of the movie — "from the start" on the detail page exists for that. **Only for a
    /// recording:** a channel has no chapters, even if the stream carries marks.
    public static func hasChapters(kind: PlaybackTarget.Kind, chapters: [Chapter]) -> Bool {
        kind == .recording && chapters.count >= 2
    }

    /// The chapter starts as a fraction of the runtime — for the marks on the timeline.
    ///
    /// The edges stay free: a mark at zero would lie under the handle, one at one
    /// under the remaining time.
    public static func fractions(
        kind: PlaybackTarget.Kind, chapters: [Chapter], duration: TimeInterval
    ) -> [Double] {
        guard hasChapters(kind: kind, chapters: chapters), duration > 0 else { return [] }
        return chapters.map { $0.start / duration }.filter { $0 > 0.01 && $0 < 0.99 }
    }

    /// Where a chapter jump leads — `nil` if there is no further chapter forward.
    ///
    /// Backward without a previous chapter lands at the start: whoever presses "back"
    /// in the first chapter means the start of the movie.
    public static func target(
        kind: PlaybackTarget.Kind, chapters: [Chapter], location: TimeInterval, forward: Bool
    ) -> TimeInterval? {
        guard hasChapters(kind: kind, chapters: chapters) else { return nil }
        return forward
            ? chapters.nextStart(after: location)
            : (chapters.previousStart(before: location) ?? 0)
    }
}
