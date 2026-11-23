import Foundation
import Testing

@testable import Core

/// The values come from an episode in the media library: 24 minutes of runtime, credits
/// from 21:56.8 to 22:57.4. The trigger point decides whether the offer
/// belongs to the last scene or bursts into the middle of the episode — and because it
/// switches on by itself after ten seconds, a mistake here costs the rest of the
/// episode.
@Suite("Next-episode prompt")
struct NextUpPromptTests {

    static let duration: TimeInterval = 1440
    static let outro = MediaSegment(id: "b", kind: .outro, start: 1316.8, end: 1377.4)

    /// Shorthand for the episode above — only the position changes from case to case.
    private static func state(
        at position: TimeInterval,
        outro: MediaSegment? = outro,
        hasNext: Bool = true
    ) -> NextUpPrompt.State? {
        NextUpPrompt.state(at: position, duration: duration, outro: outro, hasNext: hasNext)
    }

    @Test("Without a next episode nothing is offered")
    func noNextEpisode() {
        // Concerns every film and every last episode of a season. An offer without a
        // target would switch to nothing after ten seconds.
        #expect(Self.state(at: 1350, hasNext: false) == nil)
        #expect(Self.state(at: 1440, hasNext: false) == nil)
    }

    @Test("Before the outro nothing is offered")
    func beforeOutro() {
        #expect(Self.state(at: 0) == nil)
        #expect(Self.state(at: 1200) == nil)
        #expect(Self.state(at: 1316.7) == nil)
    }

    @Test("When the outro starts the prompt appears at ten seconds")
    func outroStartsCountdown() {
        // At eleven or nine the first displayed number would be wrong; that is noticed
        // immediately in the room, because the counter then jumps.
        let state = Self.state(at: 1316.8)

        #expect(state?.secondsLeft == 10)
        #expect(state?.shouldAdvance == false)
    }

    @Test("The countdown runs down from the trigger point")
    func countdownRunsDown() {
        #expect(Self.state(at: 1321.8)?.secondsLeft == 5)
        #expect(Self.state(at: 1325.8)?.secondsLeft == 1)

        // Between two seconds it rounds up, and that is what matters: The engine
        // reports twice per second, so the first report after appearing is
        // half a second off. Rounded down, nine would already be there — the
        // counter would visibly start at nine for the viewer — and the switch
        // would happen half a second too early, in the middle of the last frame.
        #expect(Self.state(at: 1317.3)?.secondsLeft == 10)
        #expect(Self.state(at: 1326.3)?.secondsLeft == 1)
        #expect(Self.state(at: 1326.3)?.shouldAdvance == false)
    }

    @Test("At zero it advances")
    func advancesAtZero() {
        let state = Self.state(at: 1326.8)

        #expect(state?.secondsLeft == 0)
        #expect(state?.shouldAdvance == true)
    }

    @Test("Past zero it keeps advancing")
    func staysAdvancing() {
        // If the position is reported late — say after a jump into the
        // credits —, the offer must not jump back to ten seconds or
        // disappear altogether.
        let state = Self.state(at: 1440)

        #expect(state?.secondsLeft == 0)
        #expect(state?.shouldAdvance == true)
    }

    @Test("The countdown never shows more than ten or less than zero")
    func countdownStaysInRange() {
        // A negative number on screen is the most visible mistake this
        // calculation can make.
        for step in 0...200 {
            let position = 1316.8 + TimeInterval(step) * 0.5
            guard let state = Self.state(at: position) else {
                Issue.record("no prompt at \(position) seconds")
                continue
            }
            #expect(state.secondsLeft >= 0)
            #expect(state.secondsLeft <= 10)
        }
    }

    @Test("Without a reported outro the fallback is forty seconds before the end")
    func fallbackWithoutOutro() {
        // The server does not find the credits for every episode. Without a fallback there
        // would be no offer there at all, and Continue Watching breaks off in the middle of the
        // season.
        #expect(NextUpPrompt.state(at: 1399, duration: 1440, outro: nil, hasNext: true) == nil)
        #expect(
            NextUpPrompt.state(at: 1400, duration: 1440, outro: nil, hasNext: true)?.secondsLeft == 10
        )
    }

    @Test("An outro before the halfway point is discarded")
    func implausibleOutroIsIgnored() {
        // Occurs with episodes with a recap at the start: The server takes the
        // recap for the credits. Taken over unchecked, the offer would appear on screen after
        // five minutes and the episode would be gone after another ten seconds.
        let bogus = MediaSegment(id: "x", kind: .outro, start: 300, end: 360)

        #expect(Self.state(at: 305, outro: bogus) == nil)
        #expect(Self.state(at: 1400, outro: bogus)?.secondsLeft == 10)
    }

    @Test("An outro past the end is discarded")
    func outroBeyondEndIsIgnored() {
        // Contradictory server data — the section list and the runtime come from
        // two queries. A trigger point behind the end is never reached, and the
        // offer would never appear.
        let bogus = MediaSegment(id: "x", kind: .outro, start: 1500, end: 1560)

        #expect(Self.state(at: 1400, outro: bogus)?.secondsLeft == 10)
    }

    @Test("An outro just before the end still advances")
    func lateOutroStillAdvances() {
        // The server occasionally reports only a short end card as the credits, and
        // runtime and sections come from two queries. If the trigger point then lay
        // five seconds before the end, the counter would never reach zero: The offer would stand
        // still at "in 4", the next episode would never start by itself, and after the end there is no
        // place where it would be recalculated. That is exactly what the overlay is there for.
        let late = MediaSegment(id: "x", kind: .outro, start: 1435, end: 1440)

        #expect(Self.state(at: 1429, outro: late)?.secondsLeft == 10)
        #expect(Self.state(at: 1435, outro: late)?.shouldAdvance == false)
        #expect(Self.state(at: 1439, outro: late)?.shouldAdvance == true)
    }

    @Test("An outro starting exactly at the halfway point is still accepted")
    func outroAtHalfIsAccepted() {
        // The limit belongs to the plausible range, otherwise an episode with
        // long credits falls back to the fallback needlessly.
        let late = MediaSegment(id: "x", kind: .outro, start: 720, end: 1440)

        #expect(Self.state(at: 719, outro: late) == nil)
        #expect(Self.state(at: 720, outro: late)?.secondsLeft == 10)
    }

    @Test("Without a known duration nothing is offered")
    func unknownDuration() {
        // For live channels and freshly recorded shows the server reports
        // zero. The fallback point would lie at minus forty seconds, so the offer would
        // be on screen from the first second — and ten seconds later it would have switched.
        #expect(NextUpPrompt.state(at: 30, duration: 0, outro: nil, hasNext: true) == nil)
        #expect(NextUpPrompt.state(at: 30, duration: -1440, outro: nil, hasNext: true) == nil)
    }

    @Test("Very short titles get no prompt")
    func shortItems() {
        // For a preview clip of ninety seconds the fallback point would lie at
        // fifty — the offer would be on screen for over half of the piece.
        #expect(NextUpPrompt.state(at: 89, duration: 90, outro: nil, hasNext: true) == nil)
        #expect(NextUpPrompt.state(at: 119, duration: 119, outro: nil, hasNext: true) == nil)

        // From two minutes on, the offer only covers the last third.
        #expect(NextUpPrompt.state(at: 80, duration: 120, outro: nil, hasNext: true)?.secondsLeft == 10)
    }
}

/// The same title as above — 24 minutes, credits from 21:56.8 —, but with the counter
/// that is carried forward instead of arising anew from the position each time.
///
/// These tests do not contradict the ones above, they complement them: The rule without
/// memory fixes the windows, the counter the seconds within them. Where the two arrive at
/// different numbers, this is stated here explicitly as an expectation — otherwise
/// it would not be recognisable that the difference is intended.
@Suite("Next-episode countdown")
struct NextUpCountdownTests {

    static let duration = NextUpPromptTests.duration
    static let outro = NextUpPromptTests.outro
    /// The trigger point of this title — the credits lie in the plausible range.
    static let trigger: TimeInterval = 1316.8

    /// The playback tick. The same half second as in the model, because the
    /// counter is queried on every tick.
    static let tick: TimeInterval = 0.5

    private func advance(
        _ countdown: inout NextUpPrompt.Countdown,
        to position: TimeInterval
    ) -> NextUpPrompt.State? {
        countdown.update(at: position, duration: Self.duration, outro: Self.outro, hasNext: true)
    }

    @Test("A jump past the countdown window starts the countdown instead of switching")
    func jumpOverWindowStartsCountdown() {
        // The finding itself. A single press of +30 shortly before the credits carries
        // beyond the whole window. Without its own reference point it immediately says
        // zero there, and the next tick — half a second later — switches the episode:
        // no counter, no chance to cancel. Whoever still wanted to
        // look something up at the end is already in the next episode.
        var countdown = NextUpPrompt.Countdown()

        #expect(advance(&countdown, to: 1310) == nil, "nothing is offered before the outro")

        let afterJump = advance(&countdown, to: 1340)
        #expect(afterJump?.secondsLeft == 10)
        #expect(afterJump?.shouldAdvance == false)

        // And the counter-proof in the same test: Exactly this position switches on
        // the spot under the rule without memory. If the reference point
        // were dropped again, this line would continue to hold and the one above would not.
        #expect(
            NextUpPrompt.state(at: 1340, duration: Self.duration, outro: Self.outro, hasNext: true)?
                .shouldAdvance == true
        )
    }

    @Test("During playback the countdown reaches zero after ten seconds")
    func countdownReachesZeroInTenSeconds() {
        // The normal case, and it must not shift because of the reference point:
        // Ten seconds from the start of the credits, not eleven and not nine. Too early
        // tears the viewer out of the picture, too late the offer stands in the
        // cut to the black frame.
        var countdown = NextUpPrompt.Countdown()
        var position = Self.trigger

        #expect(advance(&countdown, to: position)?.secondsLeft == 10)

        for _ in 0..<19 {
            position += Self.tick
            #expect(advance(&countdown, to: position)?.shouldAdvance == false)
        }

        position += Self.tick
        let last = advance(&countdown, to: position)
        #expect(position == Self.trigger + NextUpPrompt.countdown)
        #expect(last?.secondsLeft == 0)
        #expect(last?.shouldAdvance == true)
    }

    @Test("A jump during the countdown costs one tick, not the whole remainder")
    func jumpInsideWindowCostsOneStep() {
        // The case where a fixed remembered trigger point alone is not enough: Whoever
        // has the offer in front of them and still presses +30 once more lands far
        // behind the window. Computed from the distance to the reference point, the
        // counter would be at zero immediately again — exactly the finding, just one position
        // later.
        var countdown = NextUpPrompt.Countdown()

        #expect(advance(&countdown, to: Self.trigger)?.secondsLeft == 10)

        let afterJump = advance(&countdown, to: 1400)
        #expect(afterJump?.secondsLeft == 8, "at most one tick is credited")
        #expect(afterJump?.shouldAdvance == false)
    }

    @Test("The countdown never counts backwards")
    func countdownNeverCountsUp() {
        // A jump back within the credits must not let the number rise again.
        // "Next episode in 8" and on the next tick "in 9" looks like a
        // bug, and one no longer knows whether it will switch at all.
        var countdown = NextUpPrompt.Countdown()

        #expect(advance(&countdown, to: Self.trigger)?.secondsLeft == 10)
        #expect(advance(&countdown, to: Self.trigger + 1)?.secondsLeft == 9)
        #expect(advance(&countdown, to: Self.trigger + 0.2)?.secondsLeft == 9)
    }

    @Test("Going back before the outro resets the countdown to ten")
    func leavingTheWindowResetsCountdown() {
        // Whoever jumps back wants to see the scene once more — and afterwards the full
        // ten seconds to cancel. If the started state stayed put, the
        // offer would already be half expired the second time the credits are reached.
        var countdown = NextUpPrompt.Countdown()

        #expect(advance(&countdown, to: Self.trigger)?.secondsLeft == 10)
        #expect(advance(&countdown, to: Self.trigger + 1)?.secondsLeft == 9)

        #expect(advance(&countdown, to: 1200) == nil)
        #expect(advance(&countdown, to: Self.trigger)?.secondsLeft == 10)
    }

    @Test("Two ticks at the same position credit nothing")
    func repeatedPositionDoesNotAdvance() {
        // The UI also asks when only the sections or the
        // next episode have arrived. If every call counted, the counter would run
        // faster than the film, and when the additional data loads the
        // episode would switch early.
        var countdown = NextUpPrompt.Countdown()

        #expect(advance(&countdown, to: Self.trigger)?.secondsLeft == 10)
        #expect(advance(&countdown, to: Self.trigger)?.secondsLeft == 10)
        #expect(advance(&countdown, to: Self.trigger)?.secondsLeft == 10)
    }

    @Test("When playback stands still, the countdown stands still")
    func pausedPlaybackHoldsCountdown() {
        // The counter measures at the position in the film and not against a clock. A separate
        // timer would keep running while paused, and the next episode would start
        // while the picture is still standing — exactly the trap this type
        // is built against.
        var countdown = NextUpPrompt.Countdown()
        #expect(advance(&countdown, to: Self.trigger)?.secondsLeft == 10)

        for _ in 0..<40 {
            #expect(advance(&countdown, to: Self.trigger)?.shouldAdvance == false)
        }
    }

    @Test("The windows of the stateless rule still apply unchanged")
    func windowRulesStillApply() {
        // The counter determines the seconds, not the whether. Whoever mixes that up silently
        // cancels every test of the rule: no offer without a next episode,
        // none without a known runtime, none for a preview clip.
        var countdown = NextUpPrompt.Countdown()

        #expect(
            countdown.update(at: 1400, duration: Self.duration, outro: nil, hasNext: false) == nil
        )
        #expect(countdown.update(at: 30, duration: 0, outro: nil, hasNext: true) == nil)
        #expect(countdown.update(at: 89, duration: 90, outro: nil, hasNext: true) == nil)

        // And credits before half of the runtime remain a false finding of the server.
        let bogus = MediaSegment(id: "x", kind: .outro, start: 300, end: 360)
        #expect(countdown.update(at: 305, duration: Self.duration, outro: bogus, hasNext: true) == nil)
    }

    @Test("The countdown never shows more than ten or less than zero")
    func countdownStaysInRange() {
        // The same limit as with the rule without memory, here across a whole
        // playback with jumps: A negative number on screen is
        // the most visible mistake this calculation can make.
        var countdown = NextUpPrompt.Countdown()
        var position = Self.trigger

        for step in 0...200 {
            // Every twentieth tick is a jump — at the end of a film the
            // normal case and not the exception.
            position += step % 20 == 0 ? 30 : Self.tick
            guard let state = advance(&countdown, to: min(position, Self.duration)) else {
                Issue.record("no prompt at \(position) seconds")
                continue
            }
            #expect(state.secondsLeft >= 0)
            #expect(state.secondsLeft <= 10)
        }
    }
}
