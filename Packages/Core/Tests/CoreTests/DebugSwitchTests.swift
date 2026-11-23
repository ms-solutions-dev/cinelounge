import Foundation
import Testing

@testable import Core

/// **Everything that flips ``DebugMode/current`` is here — and runs one after the other.**
///
/// **The finding of 2026-09-20** (AP50): "The trace entry is called Wiedergabe" failed in the
/// full `check.sh` and was always green on its own. Two explanations were obvious, and
/// **both were wrong** — written down because the path to them
/// is the actual lesson:
///
/// 1. *"Flaky under load."* The fix was a wait loop with a five-second deadline.
///    The next full run was red again.
/// 2. *"A concurrent test switches the switch off."* ``NoiseGateTests`` flips
///    the same ``DebugMode`` and restores it in the `defer`; Swift Testing runs
///    **suites** concurrently, and `.serialized` only orders **within** a suite.
///    That is true and is the reason why both tests now live here — the
///    failure remained anyway.
///
/// **What was measured was the ring buffer.** ``Diagnostics/Trace`` holds 50 entries, 200 with
/// the switch on, and `verboseEntry` lets **every** message of the whole
/// process in while it is on. In this window the switch belongs to no
/// test alone: What the other 905 log on the side pushes the entry
/// we are looking for out. The deadline from attempt 1 thus **caused** the failure.
///
/// **The rule that follows:** Whoever sets the switch keeps the window as short
/// as possible — write, yield once, look immediately. And whoever raises a deadline
/// without measuring the path swaps a red test suite for a slow one that hides the same thing.
@Suite("Checks on the global diagnostics switch", .serialized)
struct DebugSwitchTests {

    /// A playback step is called "Wiedergabe" in the trace — as before the cut.
    ///
    /// **This test needed three attempts, and the lesson is at the end** (AP50,
    /// 2026-09-20). It writes into a **shared** store and reads back from it: The
    /// trace is a ring buffer (50 entries, 200 with the switch on), and
    /// as long as the switch is on, the **whole process** logs into it — in the
    /// full `check.sh` that is 905 concurrently running tests. Whoever writes once and looks
    /// once under these conditions also tests how busy the
    /// machine happens to be.
    ///
    /// **Hence several attempts instead of one longer wait.** Each pass is
    /// complete in itself — write, yield, look —, and the first one that
    /// finds the entry ends the loop. A longer *deadline* would do the opposite: It would keep
    /// the window open in which others push the entry out. That was exactly the
    /// second failed attempt, and it caused the failure instead of fixing it.
    @Test("The trace entry is named Wiedergabe")
    @MainActor
    func entriesKeepTheirName() async {
        let before = DebugMode.current
        defer {
            DebugMode.current = before
            Diagnostics.Trace.clear()
        }

        var found = false
        for attempt in 0..<20 where !found {
            Diagnostics.Trace.clear()
            DebugMode.current = DebugMode(isOn: true)
            Diagnostics.playbackStep("Sprung zu 90 s \(attempt)", since: nil)

            // The entry travels via `Task { @MainActor in Trace.record(…) }`; this
            // test itself runs on the main actor, so yielding queues it
            // behind that.
            await Task.yield()

            // `contains` statt `last`: Andere schreiben nebenher in dieselbe Spur.
            found = Diagnostics.Trace.entries.contains {
                $0.step == "Wiedergabe" && $0.target == "Sprung zu 90 s \(attempt)"
            }
            DebugMode.current = before
        }

        #expect(
            found,
            """
            In twenty attempts no entry with the area "Wiedergabe" arrived in the \
            trace. That is no longer congestion but a real finding: \
            `Diagnostics.playbackStep` does not pass its area through.
            """
        )
    }

    @Test("The throttling does not change the engine selection's answer")
    func gateDoesNotChangeTheAnswer() {
        // The line is throttled, the decision is not. On the second
        // call the lock stays silent — the return value must still be
        // the same. `canRemuxInApp` is called up to twice within a single
        // engine choice; if that diverged, the choice would depend on whether
        // something had been logged before.
        let before = DebugMode.current
        defer {
            DebugMode.current = before
            PlaybackEngineSelector.resetHEVCNote()
        }
        DebugMode.current = DebugMode(isOn: true)
        PlaybackEngineSelector.resetHEVCNote()

        // A channel does not state its video codec — exactly the case that produced the
        // 131 lines.
        let channel = MediaSource(container: .ts, videoCodec: nil)

        for _ in 0..<5 {
            #expect(PlaybackEngineSelector.canRemuxInApp(channel, canDecodeHEVC: true))
            #expect(!PlaybackEngineSelector.canRemuxInApp(channel, canDecodeHEVC: false))
        }
    }
}
