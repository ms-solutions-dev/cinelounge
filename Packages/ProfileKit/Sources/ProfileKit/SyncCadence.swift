import Foundation

/// When syncing happens — and when it does not.
///
/// **A concept of its own, because the question is asked in six places** (start,
/// profile switch, return to the foreground, before "Continue Watching", silent push, by
/// hand). If the brake sat at each of them, it would be missing at one — and that would be
/// the one that fires on every draw.
///
/// **The brake is not austerity but courtesy toward the account:**
/// "Continue Watching" is asked several times a second while scrolling the Home screen.
/// One trip to the server per question would be a flood of requests that CloudKit answers
/// with a throttle — and then even what was really important does not arrive.
///
/// **Two triggers run without the brake**, both for the same reason: they *know* there is
/// something to fetch. A silent push is the server's message that something has changed;
/// a profile switch is the viewer's announcement that another person's state is needed
/// now. Braking both would mean missing the only two moments in which syncing visibly
/// achieves something.
@MainActor
public final class SyncCadence {

    /// Why syncing should happen.
    public enum Occasion: String, Sendable, CaseIterable {
        case start
        case profileSwitch = "profilwechsel"
        case foreground = "vordergrund"
        case continueWatching = "weiterschauen"
        /// The server has reported that something has changed.
        case push
        /// The viewer asked for it (Settings → "Sync now").
        case byHand = "vonHand"

        /// Whether this trigger bypasses the brake.
        var isUrgent: Bool {
            switch self {
            case .push, .profileSwitch, .byHand: true
            case .start, .foreground, .continueWatching: false
            }
        }
    }

    /// The shortest interval between two braked runs — AP43: "at most every 30 s".
    public static let spacing: TimeInterval = 30

    private var last: Date?

    public init() {}

    /// When a run was last released — for the diagnostics line.
    public var recent: Date? { last }

    /// Whether a run may happen now — and records it at the same time.
    ///
    /// **Asking means taking here.** Separating "may I?" from "I'm going" would be the more
    /// precise form and the more dangerous one: an `await` would lie between the two calls,
    /// and two screens asking at the same moment would both get a yes.
    public func isAllowed(_ reason: Occasion, now: Date = Date()) -> Bool {
        if reason.isUrgent {
            last = now
            return true
        }
        // **A clock that jumps back does not block.** Daylight saving time, a clock set by hand,
        // or an Apple TV that fetches the time only after switching on: then `past` is
        // negative. Without the comparison against zero, syncing would stand still until the
        // clock caught up — with a jump of hours, that would be hours.
        if let last {
            let past = now.timeIntervalSince(last)
            if past >= 0, past < Self.spacing { return false }
        }
        last = now
        return true
    }

    /// Resets the brake — after an account switch, where everything applies anew.
    public func forget() { last = nil }
}

/// The call for a sync — **from packages that do not know the connection.**
///
/// ``ProfileSwitch`` lives in this package, "Continue Watching" in `Features`, the
/// connection to CloudKit in the program's shell. None of the three sees the others.
/// Instead of keeping a hook of its own at each place — and forgetting one of them at the
/// next screen — there is **one** call, which the shell sets once at startup.
///
/// **Whether a run really happens is decided by the ``SyncCadence``** and not by the
/// caller. "Continue Watching" is asked several times a second while scrolling; whoever
/// expects a brake here finds it — in the right place.
///
/// `nonisolated(unsafe)` for the same reason as with ``Core/ProfilePointer``: it is called
/// from every thread, and the call itself does nothing but pass along.
public enum SyncCall {

    nonisolated(unsafe) public static var notify: (@Sendable (SyncCadence.Occasion) -> Void)?

    public static func call(_ reason: SyncCadence.Occasion) { notify?(reason) }
}
