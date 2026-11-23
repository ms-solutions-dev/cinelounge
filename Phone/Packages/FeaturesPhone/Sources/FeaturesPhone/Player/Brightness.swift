import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// The screen brightness — the left swipe zone.
///
/// **Why the app touches it at all:** A film is often watched in the dark, and the system
/// brightness sits three swipes deep in Control Center — in the middle of the film. Every
/// player worth anything has this zone; its absence stands out.
///
/// **And why it still goes back on exit — but only what this gesture moved.** Until 2026-09-10
/// this said the opposite: whoever lowered it during the film had lowered it for the room,
/// and turning it back would be paternalistic. The argument holds for the room and
/// overlooks the device: a phone that stays dark after the film looks broken, and
/// **nobody connects it with the player** — the gesture was minutes ago and has no control
/// with which to undo it. Both concerns together give the rule in
/// ``resetValue(outcome:isSet:now:)``: back to the value from before the first
/// swipe — and hands off as soon as someone else has touched the brightness.
///
/// **Volume has had its own zone since 2026-09-07** — see ``Volume``. The sentence that
/// stood here until then ("stays with the device buttons") was a decision of the builder;
/// it was reversed at the first TestFlight evening (product decision).
@MainActor
enum Brightness {

    /// How much brightness one whole screen of travel means.
    ///
    /// Not one: A swipe over the full height should move the brightness noticeably, but not
    /// from fully dark to fully bright — otherwise the usable range lies in the first
    /// millimeters.
    static let span = 0.6

    /// The brightness at the start of the gesture. `nil` means: nobody is dragging right now.
    private static var anchor: Double?

    /// The brightness the viewer brought along — **before the first swipe of this film** and
    /// not before the last one. Whoever readjusts three times does not want the brightness
    /// from before the third movement on exit.
    private static var outcome: Double?

    /// What this file last set itself — the reference value for "did someone else turn it?".
    private static var isSet: Double?

    /// How much deviation still passes as "nobody turned it".
    ///
    /// **Not zero, because the system adjusts by itself.** Ambient light control shifts the
    /// value over the course of a film without anybody touching anything; with a strict
    /// comparison, the reset would be skipped exactly when it is needed most — in a dark
    /// room. Five hundredths is more than the adjustment drifts in a quiet environment, and
    /// less than a person moves the slider. **To be confirmed on the device** (M7): How far
    /// the adjustment really runs cannot be measured from a simulator — it has no light
    /// sensor.
    ///
    /// **`nonisolated`, like the calculation it uses** — a number is tied to no thread, and
    /// the test should be able to read it without the main thread.
    nonisolated static let tolerance = 0.05

    /// Calculates the brightness **absolutely from the total travel** — not event by event.
    ///
    /// **The finding of 2026-09-06:** ``SwipeZones`` reports the **whole** travel so far with
    /// every intermediate frame, not the increment. Whoever then adds the value up adds the
    /// same travel fifty times — the brightness jumps to the end of the scale, and when
    /// dragging back it does not return. When seeking, ``SwipeZones`` already does it
    /// correctly: `location + portion * span`, calculated from the position at touch-down.
    /// The same calculation stands here.
    ///
    /// - Parameter um: Fraction of the screen the finger has covered since touch-down.
    ///   Positive is brighter.
    /// - Returns: The new brightness, 0 to 1 — for the display next to the finger. Until
    ///   2026-09-07 the gesture returned nothing, and on the device you could not see how bright
    ///   it currently is: you swiped and only saw the picture get darker.
    @discardableResult
    static func update(um portion: Double) -> Double? {
        #if canImport(UIKit)
            let start = anchor ?? Double(UIScreen.main.brightness)
            anchor = start
            // **The starting value is remembered once per film and not per gesture.** It is what the
            // viewer brought along; every further movement is already their own.
            if outcome == nil { outcome = start }
            let fresh = min(1, max(0, start + portion * span))
            UIScreen.main.brightness = CGFloat(fresh)
            isSet = fresh
            return fresh
        #else
            return nil
        #endif
    }

    /// Ends the gesture. **Without this line the anchor would remain the first one of the
    /// film** — and every further swipe would start from a brightness that is long since a
    /// different one.
    static func release() {
        anchor = nil
    }

    /// How far a single step carries — for those who cannot swipe.
    nonisolated static let stepSize = 0.1

    /// One step brighter (`+1`) or darker (`-1`).
    ///
    /// **With a release at the end, and that is the whole trick.** Otherwise the anchor stays
    /// beyond the step, and the second press would calculate again from the same starting
    /// brightness — the display would move once and then never again. A line under "More
    /// commands" that does nothing the second time is worse than none.
    static func step(_ direction: Double) {
        update(um: direction * stepSize / span)
        release()
    }

    /// Where to reset on exit — `nil` means: **hands off.**
    ///
    /// Three cases, and only one of them resets:
    ///
    /// * **Nobody swiped** — then there is nothing to reset, and touching the brightness
    ///   would be a change nobody initiated.
    /// * **Someone else turned it** — Control Center, buttons, another program. Then the
    ///   earlier value is stale, and restoring it would mean overwriting a fresh decision.
    ///   That is exactly the paternalism the old sentence in this file warned against.
    /// * **What we set is still in place** — then, and only then, reset.
    ///
    /// **A pure calculation, so it can be recalculated.** Testing the three cases on screen
    /// would mean checking in the dark whether it gets bright.
    nonisolated static func resetValue(
        outcome: Double?, isSet: Double?, now: Double
    )
        -> Double?
    {
        guard let outcome, let isSet else { return nil }
        guard abs(now - isSet) <= tolerance else { return nil }
        guard abs(now - outcome) > 0.001 else { return nil }
        return outcome
    }

    /// Resets on leaving the player — see ``resetValue(outcome:isSet:now:)``.
    static func reset() {
        #if canImport(UIKit)
            if let target = resetValue(
                outcome: outcome, isSet: isSet, now: Double(UIScreen.main.brightness))
            {
                UIScreen.main.brightness = CGFloat(target)
            }
        #endif
        // **Forgotten even when nothing was reset.** The next film starts with what applies now
        // — otherwise it would aim at a brightness from the day before yesterday.
        anchor = nil
        outcome = nil
        isSet = nil
    }
}
