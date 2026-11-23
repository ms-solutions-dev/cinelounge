import Foundation

/// When the next episode is offered and when it starts by itself.
///
/// Pure calculation without a view and without an engine: the interface asks at every
/// position report and shows what comes back. The reason for this separation is the
/// experience with the opposite direction — as soon as the overlay keeps its own
/// timer, it keeps running while seeking and while paused, and the next episode
/// begins while the picture is still standing.
public enum NextUpPrompt {

    /// How long the offer stays up before the switch.
    ///
    /// Ten seconds: short enough that nobody waits, long enough to still cancel with the
    /// remote.
    public static let countdown: TimeInterval = 10

    /// How long before the end the offer is made if the server reports no outro.
    ///
    /// Forty seconds is the length of a typical outro. Too early and the overlay takes
    /// the last scene from the picture, too late and it comes after the cut to the black
    /// frame and looks like an afterthought.
    static let fallbackLead: TimeInterval = 40

    /// Shorter titles get no offer.
    ///
    /// At two minutes the fallback point already covers a third of the running time;
    /// below that the offer would be in the picture for most of the piece. That affects
    /// preview clips and short recordings from the library, where a "Next episode" has
    /// no business anyway.
    static let minimumDuration: TimeInterval = 120

    /// How much time a single tick credits to the counter at most.
    ///
    /// Two seconds with a tick of half a second — fourfold leeway for a delayed tick,
    /// and still far below the thirty seconds of a jump. The limit is the reason why
    /// ``Countdown`` survives a jump; the full rationale is there.
    static let maxStep: TimeInterval = 2

    public struct State: Sendable, Equatable {

        /// What counts down on the screen. Rounded up so that the display starts with ten
        /// and not with nine.
        public let secondsLeft: Int

        /// Whether to switch now.
        public let shouldAdvance: Bool

        public init(secondsLeft: Int, shouldAdvance: Bool) {
            self.secondsLeft = secondsLeft
            self.shouldAdvance = shouldAdvance
        }
    }

    /// The offer solely from the position in the film — **without memory**.
    ///
    /// Answers two questions: whether an offer is made at all, and how far the position
    /// lies beyond the trigger point. The first question is the actual rule and
    /// continues to apply unchanged; the second is good only for a film that runs
    /// through without a jump. Whoever also uses it for the running counter has the case
    /// described in ``Countdown``: a press of +30 shortly before the trigger point jumps
    /// straight to zero.
    ///
    /// Stays public because it can be checked without any state and fixes the position
    /// of the windows. For playback ``Countdown`` is to be used.
    ///
    /// - Parameters:
    ///   - outro: The outro reported by the server, if present.
    ///   - hasNext: Whether there is a next episode at all.
    /// - Returns: `nil` as long as nothing is to be offered.
    public static func state(
        at position: TimeInterval,
        duration: TimeInterval,
        outro: MediaSegment?,
        hasNext: Bool
    ) -> State? {
        // Without a next episode there is nothing to offer. Checked first because that is
        // the most frequent case — every film and every last episode of a season.
        guard hasNext else { return nil }

        // Length unknown: with live channels and recordings not yet scanned the server
        // reports zero. A fallback point at minus forty seconds would apply immediately,
        // and the offer would be in the picture from the first second.
        guard duration >= minimumDuration else { return nil }

        let trigger = triggerPoint(duration: duration, outro: outro)
        guard position >= trigger else { return nil }

        let left = countdown - (position - trigger)
        // Not below zero, so that the offer also stays up when the playback is reported
        // paused beyond the zero point.
        let secondsLeft = max(0, Int(left.rounded(.up)))
        return State(secondsLeft: secondsLeft, shouldAdvance: secondsLeft == 0)
    }

    /// From when the offer is made.
    static func triggerPoint(duration: TimeInterval, outro: MediaSegment?) -> TimeInterval {
        // An outro that begins before half of the running time or lies beyond the end is no
        // statement but a false find of the server — with episodes with a recap at the start
        // that happens. Taken over unchecked, the offer jumps into the middle of the
        // episode, and whoever does not cancel quickly enough loses half of it.
        let candidate: TimeInterval =
            if let outro, outro.start >= duration / 2, outro.start < duration {
                outro.start
            } else {
                duration - fallbackLead
            }

        // The counter has to arrive at zero within the running time. If the server reports
        // an outro that begins only in the last seconds — short end boards do occur, and the
        // length comes from a different query than the sections —, the offer would stay at
        // "in 4" until the title ends: it only advances at zero, and after that the engine
        // reports no position at which anything would be recalculated. The additional second
        // covers that the last position report lies before the end and not exactly on it —
        // and, since ``Countdown``, additionally that its first report lies up to half a
        // tick behind the trigger point. Without this second exactly that would be lost.
        return max(0, min(candidate, duration - countdown - 1))
    }

    // MARK: - Der laufende Zähler

    /// The counter with a reference point that survives a jump.
    ///
    /// **The case it exists for:** ``state(at:duration:outro:hasNext:)`` forms the
    /// remaining seconds from the position in the film. For an episode of 25 minutes the
    /// trigger point lies forty seconds before the end; a single press of +30 shortly
    /// before skips the whole counter window. What comes out is `secondsLeft == 0`, and
    /// the next tick — half a second later — switches the episode. The viewer sees no
    /// counter, has no chance to cancel, and whoever still wanted to look something up at
    /// the end is in the next episode. A jump at the end of a film is, however, exactly
    /// the normal case.
    ///
    /// **Why not simply remember the position on appearance.** A fixed reference point
    /// carries the jump *into* the window, but not the jump *within* the window: whoever
    /// presses +30 once more at "in 5" would again get the immediate switch. Therefore
    /// no point is remembered but **carried forward**, and every tick credits at most
    /// ``maxStep``. With running playback that is the same calculation as before — the
    /// position advances by half a second per tick. A jump of more than thirty seconds
    /// counts like one tick.
    ///
    /// **Backwards is never counted.** A jump back within the window credits zero instead
    /// of letting the counter rise again. A number that counts up where "Next episode in
    /// 4" is displayed looks like an error.
    ///
    /// **Without a clock**, for the same reason as with ``PlaybackReporter``: a timer of
    /// its own would keep running while paused and while seeking, and the next episode
    /// would begin while the picture is still standing. If the playback stands, the
    /// position does not advance, and the counter stands with it.
    ///
    /// Applies to **one** episode. After the switch a new one is to be taken — the old
    /// one would carry on the state of the previous episode.
    public struct Countdown: Sendable, Equatable {

        /// What has already been credited to the counter, in seconds.
        private var elapsed: TimeInterval = 0

        /// The position seen last, or `nil` as long as nothing is offered.
        private var lastPosition: TimeInterval?

        public init() {}

        /// Takes in the new position and returns what is to be displayed.
        ///
        /// Called at every tick and without effect at the same position: two calls without
        /// progress credit nothing. That is intended — the interface also asks when only the
        /// additional information has arrived.
        public mutating func update(
            at position: TimeInterval,
            duration: TimeInterval,
            outro: MediaSegment?,
            hasNext: Bool
        ) -> State? {
            // Whether anything is offered at all is decided unchanged by the rule without
            // memory. Only the seconds in it come from here.
            guard
                NextUpPrompt.state(
                    at: position,
                    duration: duration,
                    outro: outro,
                    hasNext: hasNext
                ) != nil
            else {
                // Back to the start. Whoever jumps back before the trigger point is to get the full
                // counter again and not the remainder from before.
                self = Countdown()
                return nil
            }

            if let last = lastPosition {
                elapsed += min(max(0, position - last), NextUpPrompt.maxStep)
            }
            lastPosition = position

            let left = NextUpPrompt.countdown - elapsed
            let secondsLeft = max(0, Int(left.rounded(.up)))
            return State(secondsLeft: secondsLeft, shouldAdvance: secondsLeft == 0)
        }
    }
}
