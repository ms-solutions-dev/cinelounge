import Foundation
import SwiftUI
import Testing

@testable import Features

/// **Two sources, one movement.**
///
/// Since 2026-08-14 the app reads page directions from two sources: the
/// movement command and a swipe gesture. The reason is at
/// ``RemoteSwipeDirection`` — on the old Siri Remote no movement
/// command arises when swiping, on the new one both arise.
///
/// From exactly that follows the danger that these checks record: where both report,
/// only **one** step may still happen. That the opposite direction is just as
/// important — quick paging must not be swallowed — stands as a
/// separate case below. Both statements here are calculations over values and
/// need no TV.
@Suite("Swipe and move command")
/// On the main actor, because the rules under test live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct RemoteSwipeTests {

    // MARK: - The gate

    /// The first report counts — from both sources.
    @Test("The first step goes through")
    func firstStep() {
        var gate = MoveGate()
        // Pulled out of the macro: `#expect` passes its expression on as an
        // immutable value, and `accepts` changes the gate.
        let command = gate.accepts(.left, Date(timeIntervalSince1970: 100), from: .command)
        #expect(command)

        var secondGate = MoveGate()
        let gestureAccepted = secondGate.accepts(.left, Date(timeIntervalSince1970: 100), from: .gesture)
        #expect(gestureAccepted)
    }

    /// **The actual purpose.** On the remote with a click ring, the movement command and
    /// the gesture recognizer report the same swipe — the command on
    /// press-down, the gesture on release. Without this gate every
    /// movement would run twice.
    @Test("The gesture echo of a command stays out")
    func gestureEcho() {
        var gate = MoveGate()
        let start = Date(timeIntervalSince1970: 100)
        let command = gate.accepts(.left, start, from: .command)
        let echo = gate.accepts(.left, start.addingTimeInterval(0.02), from: .gesture)
        #expect(command)
        #expect(!echo)
    }

    /// **The finding of 2026-08-15: every sixth or seventh click jumped twice.**
    /// How long the thumb stays down after the click depends on the hand —
    /// the echo came after 100 ms one time and after 370 ms another, and the old
    /// 250 ms window caught only one half. Since the gate knows the source,
    /// the command shadow also covers the late echo.
    @Test("Even a late gesture echo stays out")
    func lateGestureEcho() {
        var gate = MoveGate()
        let start = Date(timeIntervalSince1970: 100)
        let command = gate.accepts(.left, start, from: .command)
        // 370 ms — jenseits des alten Fensters, mitten im neuen Schatten.
        let echo = gate.accepts(.left, start.addingTimeInterval(0.37), from: .gesture)
        #expect(command)
        #expect(!echo)
    }

    /// **The counter-check, and it is the more important one.** Every click is a
    /// separate, intended step — however fast it comes. The old gate
    /// swallowed clicks less than 250 ms apart; the new one lets commands
    /// through in principle.
    @Test("Quick clicking is never swallowed")
    func briskClicking() {
        var gate = MoveGate()
        var clockTime = Date(timeIntervalSince1970: 100)
        var finished = 0
        for _ in 0..<8 {
            if gate.accepts(.left, clockTime, from: .command) { finished += 1 }
            // Six steps per second — faster than the old window allowed.
            clockTime = clockTime.addingTimeInterval(0.16)
        }
        #expect(finished == 8)
    }

    /// On the old glass surface no command ever arises — there every
    /// gesture must count, also when swiping quickly.
    @Test("On the old remote every gesture counts")
    func oldRemote() {
        var gate = MoveGate()
        var clockTime = Date(timeIntervalSince1970: 100)
        var finished = 0
        for _ in 0..<6 {
            if gate.accepts(.left, clockTime, from: .gesture) { finished += 1 }
            clockTime = clockTime.addingTimeInterval(0.3)
        }
        #expect(finished == 6)
    }

    /// The rare reverse echo: the gesture ends first, the command of the same
    /// movement arrives right after — it stays out. A command with
    /// distance, on the other hand, is a new step.
    @Test("A command right after the gesture is its echo")
    func commandEcho() {
        var gate = MoveGate()
        let start = Date(timeIntervalSince1970: 100)
        let gestureAccepted = gate.accepts(.left, start, from: .gesture)
        let echo = gate.accepts(.left, start.addingTimeInterval(0.02), from: .command)
        let newStep = gate.accepts(.left, start.addingTimeInterval(0.4), from: .command)
        #expect(gestureAccepted)
        #expect(!echo)
        #expect(newStep)
    }

    /// **A suppressed echo must not cast a shadow.** Otherwise the chain
    /// command → echo → command would lock out the second command, and
    /// paging would stand still as long as someone clicks and swipes at the same time.
    @Test("A suppressed echo does not block the next command")
    func echoDoesNotBlock() {
        var gate = MoveGate()
        let start = Date(timeIntervalSince1970: 100)
        let command = gate.accepts(.left, start, from: .command)
        let echo = gate.accepts(.left, start.addingTimeInterval(0.2), from: .gesture)
        let next = gate.accepts(.left, start.addingTimeInterval(0.3), from: .command)
        #expect(command)
        #expect(!echo)
        #expect(next)
    }

    /// After the command shadow a gesture counts again — the switch from the
    /// click-ring remote to the glass remote costs at most this span.
    ///
    /// **Tested against the default value, not against a copied number.**
    /// Before, the test passed `MoveGate(commandShadow: 3)` in by hand
    /// and probed at 2.9 and 3.1 seconds — it stayed green
    /// while the default could change arbitrarily, and incidentally wrote down
    /// the three seconds as the intended value. What belongs under test is the rule.
    @Test("After the shadow the gesture counts again")
    func afterTheShadow() {
        var gate = MoveGate()
        let start = Date(timeIntervalSince1970: 100)
        _ = gate.accepts(.left, start, from: .command)
        let inShadow = gate.accepts(.left, start.addingTimeInterval(gate.commandShadow - 0.1), from: .gesture)
        let following = gate.accepts(
            .left, start.addingTimeInterval(gate.commandShadow + 0.1), from: .gesture)
        #expect(!inShadow)
        #expect(following)
    }

    /// **The guardrail for the number itself.** The shadow stood at three
    /// seconds, justified with "costs almost nothing" — in mixed operation
    /// (second remote, iPhone remote, HDMI-CEC) it costs plenty:
    /// every real gesture of the same direction stays out that long. The
    /// expert review counts 13 of 54 selection presses that were
    /// repeated within two seconds; a shadow that outlives this repetition
    /// swallows the second attempt too. The model for this test is
    /// ``FocusRulesTests/wrapDelayStaysBelowANormalStep()``.
    @Test("The command shadow stays below the viewer's patience")
    func shadowStaysShort() {
        #expect(MoveGate().commandShadow <= 1.5)
    }

    /// **The bug of 2026-08-14 evening, recorded as a test.** On a second household's TV
    /// the log showed "recognized: left" five times, followed by
    /// "key down arrived": a swipe to the lower left makes the focus engine
    /// first go one row down, and a gate that counted every movement
    /// equally thereby locked out exactly the left gesture for the sake of which
    /// the whole thing exists. The shadow is therefore armed per direction.
    @Test("Another direction is not blocked along with it")
    func otherDirectionStaysFree() {
        var gate = MoveGate()
        let start = Date(timeIntervalSince1970: 100)
        let down = gate.accepts(.down, start, from: .command)
        // Milliseconds later, another direction, as a gesture — must get through.
        let links = gate.accepts(.left, start.addingTimeInterval(0.03), from: .gesture)
        #expect(down)
        #expect(links)
    }

    // MARK: - Which axis was meant

    /// **The case that triggered all of this.** On a second household's TV the
    /// log counted 35 reports of "down" and two of "left", although the swipe was
    /// to the left: four recognizers ran side by side, and whichever fired first
    /// won. A diagonal pull to the left must mean left.
    @Test(
        "A diagonal stroke counts by its stronger axis",
        arguments: [
            (CGFloat(-1178), CGFloat(260), RemoteSwipeDirection.left),
            (1166, -132, .right),
            (-180, 100, .left),
            (400, 200, .right),
        ]
    )
    func diagonalPull(_ dx: CGFloat, _ dy: CGFloat, _ expected: RemoteSwipeDirection) {
        #expect(RemoteSwipeDirection.fromDrag(dx: dx, dy: dy) == expected)
    }

    /// **Vertical stays out, and that is intentional.** Up and down
    /// the focus engine handles reliably — the same log counts 35
    /// arrived down steps. If this path reported them additionally, the
    /// list would run two rows instead of one on every swipe.
    @Test(
        "Nobody reports vertical strokes",
        arguments: [
            (CGFloat(0), CGFloat(-1500)),
            (0, 1500),
            (300, 2000),
            (-400, -1800),
        ]
    )
    func vertical(_ dx: CGFloat, _ dy: CGFloat) {
        #expect(RemoteSwipeDirection.fromDrag(dx: dx, dy: dy) == nil)
    }

    /// Jitter when the thumb is placed is not a swipe.
    @Test("Short strokes do not count")
    func tooShort() {
        #expect(RemoteSwipeDirection.fromDrag(dx: -80, dy: 2) == nil)
        #expect(RemoteSwipeDirection.fromDrag(dx: -121, dy: 2) == .left)
    }

    /// **The boundary itself, so that it does not shift unnoticed.** At exactly
    /// 1.2 times overhang the pull is not distinct enough yet — only
    /// above that.
    @Test("The overhang limit is fixed")
    func limit() {
        // 240 horizontal, 200 vertical: exactly 1.2 times — not enough.
        #expect(RemoteSwipeDirection.fromDrag(dx: -240, dy: 200) == nil)
        // One unit less vertical, and it prevails.
        #expect(RemoteSwipeDirection.fromDrag(dx: -240, dy: 199) == .left)
    }

    // MARK: - The measured moves from the device

    /// **Real numbers, no thought experiment.** All four come from the log
    /// of a second household's TV (2026-08-14, build 281) and were **rejected** there,
    /// although the swipe was to the left: every pull carried a large
    /// downward component, y lay consistently above 1800. The ratio rule alone
    /// did not recognize the intent.
    @Test(
        "Measured left swipes are recognized",
        arguments: [
            (CGFloat(-1496), CGFloat(2202)),
            (-1323, 1962),
            (-1281, 2028),
            (-817, 1829),
            (-985, 3423),
        ]
    )
    func measuredLeftSwipes(_ dx: CGFloat, _ dy: CGFloat) {
        #expect(RemoteSwipeDirection.fromDrag(dx: dx, dy: dy) == .left)
    }

    /// **The counter-check from the same measurement**, and it is the reason why the
    /// threshold must not go arbitrarily low: these pulls were paging downward.
    /// Their horizontal distance stayed under 350, while the intended swipes lay at
    /// 800 and more — the boundary lies in between.
    @Test(
        "Measured paging stays paging",
        arguments: [
            (CGFloat(-76), CGFloat(1628)),
            (-122, 1654),
            (-258, 1606),
            (-349, 1670),
            (-245, 883),
        ]
    )
    func measuredPaging(_ dx: CGFloat, _ dy: CGFloat) {
        #expect(RemoteSwipeDirection.fromDrag(dx: dx, dy: dy) == nil)
    }

    // MARK: - The translation

    /// Both sources flow into the same rule — for that the directions must
    /// correspond to each other, otherwise a swipe to the left would open something different
    /// than a press to the left.
    @Test(
        "Swipe direction and move direction mean the same",
        arguments: [
            (RemoteSwipeDirection.left, MoveCommandDirection.left),
            (.right, .right),
            (.up, .up),
            (.down, .down),
        ]
    )
    func directions(_ swipe: RemoteSwipeDirection, _ movement: MoveCommandDirection) {
        #expect(swipe.asMove == movement)
    }

    // MARK: - Two gestures from one move (AP4 · K9)

    /// **The finding:** the gate checked a gesture only against commands, never against
    /// a previous gesture — "on the old remote one swipe therefore pages
    /// two titles". The command shadow does not apply there: on the glass
    /// surface no command ever arises against which it could arm itself.
    @Test("A stroke reported twice pages once")
    func doubleGestureCountsOnce() {
        var moveGate = MoveGate()
        let now = Date(timeIntervalSince1970: 1_000)

        let first = moveGate.accepts(.left, now, from: .gesture)
        let second = moveGate.accepts(.left, now.addingTimeInterval(0.05), from: .gesture)

        #expect(first)
        #expect(!second)
    }

    /// **And the counter-check.** Whoever swipes twice wants to page twice — the
    /// shadow may only cover the recognizer, not the operator.
    @Test("Two real strokes page twice")
    func twoRealPulls() {
        var moveGate = MoveGate()
        let now = Date(timeIntervalSince1970: 1_000)

        let first = moveGate.accepts(.left, now, from: .gesture)
        let second = moveGate.accepts(
            .left, now.addingTimeInterval(MoveGate().gestureShadow + 0.01), from: .gesture)

        #expect(first)
        #expect(second)
    }

    /// The shadow applies per direction: whoever swipes left and right right
    /// after means both.
    @Test("The gesture shadow applies per direction")
    func gestureShadowPerDirection() {
        var moveGate = MoveGate()
        let now = Date(timeIntervalSince1970: 1_000)

        let links = moveGate.accepts(.left, now, from: .gesture)
        let right = moveGate.accepts(.right, now.addingTimeInterval(0.05), from: .gesture)

        #expect(links)
        #expect(right)
    }

    // MARK: - Vertical moves (AP4 · K3)

    /// **Without it, channel switching and the info area are unreachable on the old
    /// remote.** Above and below the running picture there is
    /// nothing the focus engine could move — so no movement
    /// command arises there either.
    @Test("Vertical strokes are reported on demand")
    func verticalOnDemand() {
        #expect(RemoteSwipeDirection.fromDrag(dx: 20, dy: 400, vertical: true) == .down)
        #expect(RemoteSwipeDirection.fromDrag(dx: 20, dy: -400, vertical: true) == .up)
    }

    /// **And only on request.** In a list the focus engine handles up
    /// and down reliably; if they were reported additionally, it would run two rows
    /// per swipe instead of one.
    @Test("Without demand vertical stays out")
    func verticalOnlyOnDemand() {
        #expect(RemoteSwipeDirection.fromDrag(dx: 20, dy: 400) == nil)
    }

    /// **The measured case from a second household's TV:** all pulls carried a
    /// large downward component (y between 1600 and 2200), including the intended
    /// left swipes (x between 800 and 1500). They must not suddenly count as
    /// "down" just because vertical is allowed.
    @Test("A clear left swipe stays left, even with a downward drift")
    func leftStaysLeft() {
        #expect(RemoteSwipeDirection.fromDrag(dx: -1200, dy: 1800, vertical: true) == .left)
    }

    /// A diagonal pull without a distinct axis stays out — in both
    /// directions.
    @Test("A diagonal stroke stays out")
    func diagonalStaysOut() {
        #expect(RemoteSwipeDirection.fromDrag(dx: 200, dy: 200, vertical: true) == nil)
    }
}
