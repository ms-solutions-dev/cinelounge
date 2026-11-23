import Testing

@testable import FeaturesPhone

/// The double tap in the player — **right forward, left back, middle nothing.**
///
/// **This was asked about on 2026-09-06**, and the rule has three cases and two boundaries.
/// Exactly for that reason it lives in a function and not in the view body: One would never
/// hit the middle the same way twice on the device.
@Suite("Swipe zones")
struct SwipeZoneTests {

    @Test("Left jumps back, right jumps forward")
    func direction() {
        #expect(SwipeZones.span(at: 0.1) == -SwipeZones.jump)
        #expect(SwipeZones.span(at: 0.9) == SwipeZones.jump)
    }

    /// **The seam belongs to neither.** A double tap exactly on the middle would otherwise be
    /// a coin toss — and when scrubbing one sees immediately if the wrong side wins.
    @Test("The middle does not jump")
    func dead() {
        #expect(SwipeZones.span(at: 0.5) == nil)
        #expect(SwipeZones.span(at: 0.45) == nil)
        #expect(SwipeZones.span(at: 0.55) == nil)
    }

    /// **The boundary lies one tenth beside the middle** — the dead fifth, halved.
    @Test("Just outside the middle it jumps again")
    func limit() {
        #expect(SwipeZones.span(at: 0.39) == -SwipeZones.jump)
        #expect(SwipeZones.span(at: 0.61) == SwipeZones.jump)
    }

    /// **Ten seconds, the system's number.** A custom one would be nothing but a surprise at
    /// this spot.
    @Test("The jump is ten seconds")
    func span() {
        #expect(SwipeZones.jump == 10)
    }

    /// **The transition counts, not the state.** Whoever keeps swiping at full volume reports
    /// the same value 1 with every intermediate frame — one impulse per intermediate frame
    /// would be a constant buzz. On the device the difference cannot be tested: There one
    /// feels both as "it vibrated".
    @Test("Only the impact reports itself, not the staying")
    func impactOnlyOnContact() {
        #expect(SwipeZones.atLimit(Level(audio: true, value: 0.8), Level(audio: true, value: 1)))
        #expect(!SwipeZones.atLimit(Level(audio: true, value: 1), Level(audio: true, value: 1)))
    }

    @Test("Both ends report themselves")
    func bothEnds() {
        #expect(SwipeZones.atLimit(Level(audio: false, value: 0.2), Level(audio: false, value: 0)))
        #expect(SwipeZones.atLimit(Level(audio: false, value: 0.2), Level(audio: false, value: 1)))
    }

    /// **A zone change is not an impact.** Whoever switches from brightness to volume and
    /// starts at the stop there has achieved nothing — they just stand somewhere else.
    @Test("The zone switch does not report itself")
    func zoneSwitch() {
        #expect(!SwipeZones.atLimit(Level(audio: false, value: 0.5), Level(audio: true, value: 1)))
    }

    /// The first value of a gesture is the state at touch-down — whoever was already at the
    /// top has not just arrived. And the cleanup afterwards (`nil`) reports nothing.
    @Test("Without a predecessor and when cleaning up it stays silent")
    func edgeCases() {
        #expect(!SwipeZones.atLimit(nil, Level(audio: true, value: 1)))
        #expect(!SwipeZones.atLimit(Level(audio: true, value: 1), nil))
    }

    // MARK: - What the double tap shows

    /// **The case this is about.** Tapping three times jumps thirty seconds; if every tap said
    /// "10 s", the display would contradict the picture it is meant to explain.
    @Test("Taps in the same direction add up")
    func skipAccumulates() {
        let once = JumpIndicator.State.first(SwipeZones.jump)
        let twice = once.and(SwipeZones.jump)
        let threeTimes = twice.and(SwipeZones.jump)

        #expect(once.seconds == 10)
        #expect(twice.seconds == 20)
        #expect(threeTimes.seconds == 30)
        #expect(threeTimes.forward)
    }

    /// **A change of direction starts over.** "30 s" with the arrow pointing back would be the
    /// sum of two directions and would describe no single jump.
    @Test("The other direction resets the sum")
    func directionChangeResets() {
        let forward = JumpIndicator.State.first(SwipeZones.jump).and(SwipeZones.jump)
        #expect(forward.seconds == 20)

        let back = forward.and(-SwipeZones.jump)

        #expect(!back.forward)
        #expect(back.seconds == 10, "not 30, and not 10 with the arrow pointing forward either")
    }

    /// The display carries a number with a unit and no sentence — so it is in no language
    /// catalog, and that should be checked so nobody "translates" it.
    @Test("The wording is a number with a unit")
    func skipWording() {
        #expect(JumpIndicator.wording(10) == "10 s")
        #expect(JumpIndicator.wording(30) == "30 s")
    }
}
