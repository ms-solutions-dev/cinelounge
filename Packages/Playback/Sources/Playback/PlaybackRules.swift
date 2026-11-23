import Core
import Foundation

/// The engine's computations that get by without an engine.
///
/// **Expressly outside any platform condition**: they are ordinary arithmetic, and
/// this is exactly where the cases are that stand out in everyday viewing — seeking
/// back in the first seconds, a jump past the end.
///
/// **Since 2026-09-26 only one** (AP58). Here also stood the rules of the VLC engine —
/// resuming, wait period, lead, media options, end detection. After its removal on
/// 2026-08-16 nobody called it any more; only its checks still ran and reported
/// protection that no longer existed in the playback path.
enum PlaybackRules {

    /// Where a seek actually goes, or `nil` if it does not work yet.
    ///
    /// `nil` for an unknown length: whoever set `position` then would show a position
    /// where the film is not — the bar would stand ahead, the picture elsewhere.
    ///
    /// The lower bound is the everyday case and not the special case: ten seconds back
    /// at second three gives minus seven. Unfiltered the bar would run past the left
    /// edge, and the progress reported to the server would be negative — on the next
    /// opening the viewer would be offered a nonsensical resume position.
    static func seekTarget(_ requested: TimeInterval, duration: TimeInterval) -> TimeInterval? {
        guard duration.isFinite, duration > 0 else { return nil }
        return min(max(requested, 0), duration)
    }
}
