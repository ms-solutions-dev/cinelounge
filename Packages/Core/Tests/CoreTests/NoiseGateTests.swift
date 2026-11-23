import Foundation
import Testing

@testable import Core

/// The lock against identical message lines — and the assurance that it only touches the
/// line and never the decision.
///
/// The occasion is in the log of 2026-08-23: "Umpacken: kein Bildcodec genannt"
/// appeared there 131 times verbatim, 2.5 % of the verbose block, and said in
/// none of the 131 cases anything that was not already fixed by the design.
///
/// Serial, because ``DebugMode/current`` and the lock in ``PlaybackEngineSelector``
/// are global quantities: Two tests that flip them at the same time would test
/// each other instead of the thing.
/// **The test "The throttling does not change the answer of the engine choice" has stood in
/// ``DebugSwitchTests`` since 2026-09-20** — it flips ``DebugMode/current``, and that
/// must be serialised in exactly one place.
@Suite("Lock against identical lines", .serialized)
struct NoiseGateTests {

    // MARK: - Die Sperre für sich

    @Test("The first value passes, the repetition does not")
    func firstAdmittedThenSilent() {
        // The calls deliberately stand before the `#expect`: The macro treats
        // its expression as immutable, a `mutating` method does not work
        // in it.
        var gate = NoiseGate<Bool>()
        #expect(gate.lastAdmitted == nil)
        let first = gate.admit(true)
        let second = gate.admit(true)
        let third = gate.admit(true)
        #expect(first)
        #expect(!second)
        #expect(!third)
        #expect(gate.lastAdmitted == true)
    }

    @Test("A different value passes — and so does the change back")
    func changeIsAdmitted() {
        // That is the whole purpose: Not the line is locked, but the
        // statement. If it changes, it must get through, otherwise the
        // lock would have swallowed exactly the incident one is looking for.
        var gate = NoiseGate<String>()
        let opened = gate.admit("200 from edge-1")
        let again = gate.admit("200 from edge-1")
        let refused = gate.admit("407 from edge-1")
        let back = gate.admit("200 from edge-1")
        #expect(opened)
        #expect(!again)
        #expect(refused)
        #expect(back)
    }

    // MARK: - Am Einbauort
}

/// The gate that counts along — AP1, the debounced refusals.
///
/// **The finding:** `Reply 407` appears 18 times among 30 error lines of the
/// recording of 2026-08-23 — the same refusal from the same remote end, once per
/// reconnection. Without the counter the shortening would be a concealment.
@Suite("The counting gate")
struct CountingGateTests {

    @Test("The first refusal passes, the repetitions are counted")
    func countsRepeats() {
        var gate = CountingGate<String>()

        let first = gate.admit("407@iptvhost.example")
        let second = gate.admit("407@iptvhost.example")
        let third = gate.admit("407@iptvhost.example")

        #expect(first)
        #expect(!second)
        #expect(!third)
        #expect(gate.swallowed == 2)
    }

    /// **A different remote end is a different piece of information.** In the log of
    /// 2026-08-23 the same 407s are from `iptvhost.example` and from `203.0.113.228` —
    /// a gate on the status alone would have concealed the second.
    @Test("A different sender passes")
    func otherChannel() {
        var gate = CountingGate<String>()
        let first = gate.admit("407@iptvhost.example")
        let second = gate.admit("407@203.0.113.228")

        #expect(first)
        #expect(second)
    }

    /// A new key resets the counter: What was swallowed
    /// belongs to the information that repeated it.
    @Test("A new key resets the counter")
    func counterReset() {
        var gate = CountingGate<String>()
        _ = gate.admit("407@a")
        _ = gate.admit("407@a")
        #expect(gate.swallowed == 1)

        _ = gate.admit("404@a")
        #expect(gate.swallowed == 0)
    }

    /// Without repetition there is nothing to report at the end — the settlement
    /// writes no line then.
    @Test("Without a repetition the counter stays at zero")
    func withoutRepeat() {
        var gate = CountingGate<String>()
        _ = gate.admit("407@a")
        #expect(gate.swallowed == 0)
    }
}
