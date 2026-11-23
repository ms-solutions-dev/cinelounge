import Foundation

/// Decides when a report about playback is due to the server.
///
/// **Was called `ProgressReporter` until 2026-09-16.** With Xcode 27 Foundation introduces its
/// own `ProgressReporter`, and every file that imports `Core` and `Foundation`
/// got "ambiguous for type lookup" — in both apps, without a line here having
/// changed. Renamed instead of qualified, following the rule from the shared
/// packages: a descriptive name of our own costs once, `Core.` in front of 37 places every day.
///
/// **Why this is a state machine of its own:** the engine reports its position
/// several times per second. If each of them were passed on, two hours of film would
/// produce a five-digit number of requests — the server would be busy with that instead of
/// delivering. Conversely, reporting must not follow the clock rigidly: pause, seek
/// and end must go out immediately, otherwise the server shows a state that no longer exists in the
/// living room.
///
/// **Without a clock.** Elapsed time is measured by position and not by the
/// calendar. During playback the position itself is the clock, and a
/// seek is therefore indistinguishable from elapsed time — which does not
/// matter, because both should be reported. The gain: this rule can be tested without
/// waiting and without an engine.
///
/// A counter applies to **one** playback. After sign-off it stays silent
/// for good; the next title gets a new one.
public struct PlaybackReporter: Sendable, Equatable {

    /// A report that is meant to go out.
    public struct Report: Sendable, Equatable {

        public enum Kind: String, Sendable, Equatable {
            case start, progress, pause, resume, stop
        }

        public let kind: Kind
        public let position: TimeInterval

        public init(kind: Kind, position: TimeInterval) {
            self.kind = kind
            self.position = position
        }
    }

    /// Mindestabstand zwischen zwei Fortschrittsmeldungen in Sekunden.
    public let interval: TimeInterval

    /// Kind and position of the last report sent. Both together, because the
    /// kind decides about pause and resume and the position about the interval.
    private var lastKind: Report.Kind?
    private var lastPosition: TimeInterval = 0

    /// Whether sign-off has already happened. A second sign-off would end a
    /// session on the server that now belongs to a different title.
    private var isFinished = false

    /// Whether this counter has already signed off — then it stays silent for good, and whoever keeps playing the same
    /// title needs a new one (player review, findings S5 and S10).
    public var isSignedOff: Bool { isFinished }

    public init(interval: TimeInterval = 10) {
        // Zero or negative would produce one report per frame — exactly the case
        // this type was built against. One second is the lower bound.
        self.interval = max(1, interval)
    }

    /// The engine submits its state; what comes out is what should be reported.
    ///
    /// Called with every position report and mostly answers with `nil`.
    ///
    /// With `.ended` the **passed** position applies. Some engines report a position
    /// of zero at the end; if that were passed in, the title would be reset to the start
    /// and would be under "Continue Watching" again.
    public mutating func consider(position: TimeInterval, status: PlaybackStatus) -> Report? {
        if isFinished { return nil }

        switch status {
        case .ended, .failed:
            // The error case also signs off, and even without a prior `.start`:
            // the session already comes into existence on the server on opening. If the
            // sign-off does not happen, it stands there for hours as running and blocks
            // the "Now Playing" display on all devices.
            isFinished = true
            return record(.stop, at: position)

        case .paused:
            // Immediately and regardless of the interval: otherwise the server keeps
            // showing "playing", and on the phone it is not understandable
            // why the picture is frozen.
            //
            // Without a prior sign-in it stays silent — a pause for a
            // session that does not exist yet leaves the server with an
            // entry that nobody signs off anymore.
            guard lastKind != nil, lastKind != .pause else { return nil }
            return record(.pause, at: position)

        case .playing:
            guard lastKind != nil else { return record(.start, at: position) }
            if lastKind == .pause { return record(.resume, at: position) }

            // The interval is measured as an absolute value so that a seek
            // backwards also goes out immediately. Otherwise after a
            // backward seek the server shows the old position for up to ten seconds, and a second
            // device resumes at exactly that wrong place.
            guard abs(position - lastPosition) >= interval else { return nil }
            return record(.progress, at: position)

        case .idle, .opening, .buffering:
            // Buffering is explicitly not a pause. Whoever treats both the same
            // reports "paused" while the viewer is waiting — the display then lies,
            // and when playback continues a resume follows that
            // nobody triggered.
            return nil
        }
    }

    private mutating func record(_ kind: Report.Kind, at position: TimeInterval) -> Report {
        lastKind = kind
        lastPosition = position
        return Report(kind: kind, position: position)
    }

    // MARK: - Schwellen

    /// From which fraction a title counts as watched.
    ///
    /// Ninety percent, because the credits are rarely watched to the end. Whoever
    /// sets it higher collects series that never get finished.
    ///
    /// **`public` since 2026-09-08, for the downloads of the phone app.** There the
    /// same threshold decides what "Remove Watched" takes along — from the local
    /// history, because this screen has to work without a network. A second number next to it
    /// would be the place where a title counts as watched on the TV and does not on the
    /// phone.
    public static let watchedFraction: Double = 0.9

    public static func isWatched(position: TimeInterval, duration: TimeInterval) -> Bool {
        // Without a known runtime no fraction can be formed. Better not
        // watched then: a wrongly set mark takes the title out of
        // "Continue Watching", and the viewer cannot find the position again.
        guard duration > 0 else { return false }
        return position / duration >= watchedFraction
    }

    /// The position at which to resume, or `nil` for from the start.
    public static func resumePosition(position: TimeInterval, duration: TimeInterval) -> TimeInterval? {
        // Deliberately via ``PlaybackProgress`` and not with thresholds of its own: what
        // counts here as a resume position must be the same as what appears in the
        // "Continue Watching" row. If two rules for it drift apart,
        // a title sits in the row that starts from the beginning when opened.
        //
        // That ``PlaybackProgress`` stops at 0.95 and 0.9 applies here is not a
        // contradiction: the watched mark takes hold first and covers the range
        // in between.
        let progress = PlaybackProgress(
            position: position,
            duration: duration,
            isWatched: isWatched(position: position, duration: duration)
        )
        return progress.isResumable ? position : nil
    }
}
