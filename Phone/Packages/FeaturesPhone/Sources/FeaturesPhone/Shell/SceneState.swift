import Foundation
import Observation

/// Foreground, background, return.
///
/// On the TV this does not exist: an Apple TV runs or is off. On the phone this one piece of information
/// decides whether the position in the movie is kept, whether the downloads
/// keep loading and whether, on coming back, it reloads or not.
///
/// **The rule: do not reload on every return.** Whoever answers a message in between
/// comes back after twelve seconds and wants to continue where they were —
/// not in a loading spinner. Only after a while is reloading worthwhile.
@MainActor
@Observable
public final class SceneState {

    /// How long the app must have been in the background for reloading to be worthwhile.
    ///
    /// Five minutes: shorter than the validity of a portal video address (300 s) and
    /// longer than any interruption still felt as "away briefly".
    public static let reloadAfter: TimeInterval = 300

    public private(set) var isInForeground = true
    private var backgroundSince: Date?

    public init() {}

    public func wentToBackground(_ now: Date = .now) {
        isInForeground = false
        backgroundSince = now
    }

    /// Reports the return and says whether to reload.
    @discardableResult
    public func cameBack(_ now: Date = .now) -> Bool {
        isInForeground = true
        defer { backgroundSince = nil }
        guard let backgroundSince else { return false }
        return now.timeIntervalSince(backgroundSince) >= Self.reloadAfter
    }
}
