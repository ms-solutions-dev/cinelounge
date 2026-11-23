import Testing

@testable import FeaturesPhone

/// When the brightness goes back on leaving the player — and when expressly
/// not.
///
/// **The case for which this check really exists is the second.** That a
/// lowered brightness comes back is visible; that it overwrites a **foreign** setting is
/// seen only at the moment when it is too late — at night, when the
/// screen suddenly turns bright. On the device that could be checked only in the dark, and then
/// not the same way twice.
@Suite("Restore brightness")
struct BrightnessTests {

    @Test("If nobody swiped, nothing is touched")
    func withoutGestureNoReset() {
        #expect(Brightness.resetValue(outcome: nil, isSet: nil, now: 0.4) == nil)
        #expect(Brightness.resetValue(outcome: 0.8, isSet: nil, now: 0.4) == nil)
        #expect(Brightness.resetValue(outcome: nil, isSet: 0.3, now: 0.3) == nil)
    }

    @Test("If the value the player set is still in place, it is restored")
    func loweredAndUntouchedRestores() {
        #expect(Brightness.resetValue(outcome: 0.8, isSet: 0.2, now: 0.2) == 0.8)
    }

    @Test("Upwards too — the gesture counts, not the direction")
    func alsoBackUp() {
        // Whoever turned it up for a dark film likewise does not want a
        // phone that stays at full brightness afterwards.
        #expect(Brightness.resetValue(outcome: 0.3, isSet: 1.0, now: 1.0) == 0.3)
    }

    @Test("A foreign change wins")
    func foreignHandWins() {
        // Control Center, buttons, another program: the value from before is outdated,
        // and restoring it would mean overwriting a fresh decision.
        #expect(Brightness.resetValue(outcome: 0.8, isSet: 0.2, now: 0.6) == nil)
    }

    @Test("The system's own adjustment does not count as a foreign change")
    func followUpDoesNotApply() {
        // Two hundredths of deviation are within tolerance — otherwise the restore would be skipped
        // exactly where it is most needed: in the dark room, where the
        // ambient light control constantly readjusts.
        let now = 0.2 + Brightness.tolerance / 2
        #expect(Brightness.resetValue(outcome: 0.8, isSet: 0.2, now: now) == 0.8)
    }

    @Test("Where the original value is already in place, it is not set again")
    func alreadyAtTargetIsNotSet() {
        // Whoever swipes back now and then ends up at the initial value. Writing it once
        // more then would be a touch of the brightness without any effect — and it
        // would switch off the system's tracking for nothing.
        #expect(Brightness.resetValue(outcome: 0.5, isSet: 0.5, now: 0.5) == nil)
    }
}
