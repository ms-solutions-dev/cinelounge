import Foundation
import Testing

@testable import Core

/// The clock by which a second playback engine is to be decided.
///
/// **That is why it is tested and not merely written:** a decision over weeks
/// of work and possibly a purchased licence hangs on these numbers. A clock
/// that runs wrong would be worse than none — it would look like proof.
@Suite("Measuring startup time")
struct StartupTimingTests {

    private let start = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Comparison is exact to the millisecond, not to the bit.
    ///
    /// `Date` computes in floating point, and 0.8 seconds there is never exactly 0.8 —
    /// an equality test fails on a deviation that nobody cares about in a
    /// startup measurement. The clock measures seconds, not
    /// nanoseconds.
    private func millis(_ value: TimeInterval?) -> Int? {
        value.map { Int(($0 * 1000).rounded()) }
    }

    @Test("The three phases are reported separately")
    func threeSections() {
        var timing = StartupTiming(opening: "native/direct", startedAt: start)
        timing.markReady(at: at(0.8))
        timing.markFirstFrame(at: at(2.5))

        #expect(millis(timing.timeToReady) == 800)
        // The second section counts from readiness, not from the start —
        // otherwise the connection time would be in the table twice.
        #expect(millis(timing.timeToFirstFrame) == 1700)
        #expect(millis(timing.total) == 2500)
        #expect(timing.isComplete)
    }

    /// During playback the state switches back to "ready" several times —
    /// every buffering looks like that. If the mark moved along, the clock would
    /// end up measuring something arbitrary.
    @Test("Only the first readiness counts")
    func readyIsRecordedOnce() {
        var timing = StartupTiming(opening: "native/direct", startedAt: start)
        timing.markReady(at: at(0.5))
        timing.markReady(at: at(9.0))

        #expect(millis(timing.timeToReady) == 500)
    }

    @Test("And only the first picture")
    func firstFrameIsRecordedOnce() {
        var timing = StartupTiming(opening: "vlc/direct", startedAt: start)
        timing.markFirstFrame(at: at(3.0))
        timing.markFirstFrame(at: at(12.0))

        #expect(millis(timing.total) == 3000)
    }

    /// **A readiness that nobody reported is not invented.**
    ///
    /// Before, the first frame back-filled a missing readiness to the same
    /// point in time. That made the middle section zero and looked
    /// like a record. If the report is missing, that is precisely the finding — about
    /// the engine, not about the startup time.
    @Test("A picture without prior readiness invents no mark")
    func frameWithoutReadyReportsNothingInvented() {
        var timing = StartupTiming(opening: "vlc/direct", startedAt: start)
        timing.markFirstFrame(at: at(1.2))

        #expect(timing.timeToReady == nil)
        #expect(timing.timeToFirstFrame == nil)
        // The total time is unaffected — it depends only on the frame.
        #expect(millis(timing.total) == 1200)
        #expect(timing.line.contains("readiness never reported on its own"))
    }

    /// **The core must not believe the caller.** The startup is sampled every 50 ms;
    /// if the caller sets both marks from the same sample, the
    /// section in between is not measured but was never even
    /// observed. That is how the 156 zeros of the session of 2026-08-23 came about.
    @Test("Two marks from the same sample do not yield a zero")
    func sameSampleIsNotAMeasurement() {
        var timing = StartupTiming(opening: "native/direct", startedAt: start)
        let now = at(1.0)
        timing.markReady(at: now)
        timing.markFirstFrame(at: now)

        #expect(millis(timing.timeToReady) == 1000)
        #expect(timing.timeToFirstFrame == nil)
        #expect(millis(timing.total) == 1000)
        // Do not check for "0 ms" alone — "1000 ms" contains that string.
        #expect(!timing.line.contains("first frame: 0 ms"))
        #expect(timing.line.contains("not separable"))
    }

    /// Some engines follow the state change only after the frame. A
    /// readiness from after that is no longer a startup mark; counted as one
    /// it would yield a negative duration, and that devalues the whole table.
    @Test("Readiness after the picture is no longer accepted")
    func readyAfterTheFrameIsRefused() {
        var timing = StartupTiming(opening: "vlc/direct", startedAt: start)
        timing.markFirstFrame(at: at(1.0))
        timing.markReady(at: at(2.0))

        #expect(timing.timeToReady == nil)
        #expect(timing.timeToFirstFrame == nil)
        #expect(millis(timing.total) == 1000)
    }

    /// A channel that never delivers a frame is the most interesting case
    /// of all — the measurement must not report it as finished.
    @Test("Without a picture the measurement stays incomplete")
    func withoutFrameTheMeasurementStaysOpen() {
        var timing = StartupTiming(opening: "native/direct", startedAt: start)
        timing.markReady(at: at(0.6))

        #expect(!timing.isComplete)
        #expect(timing.total == nil)
        #expect(timing.timeToFirstFrame == nil)
        #expect(millis(timing.timeToReady) == 600)
    }

    @Test("The line names the engine and all three numbers")
    func lineCarriesEverything() {
        var timing = StartupTiming(opening: "native/direct", startedAt: start)
        timing.markReady(at: at(0.8))
        timing.markFirstFrame(at: at(2.5))

        let line = timing.line
        #expect(line.contains("native/direct"))
        #expect(line.contains("800 ms"))
        #expect(line.contains("1700 ms"))
        #expect(line.contains("2500 ms"))
    }

    @Test("What is missing appears as a dash — not as a zero")
    func missingValuesAreNotZero() {
        let timing = StartupTiming(opening: "native/direct", startedAt: start)
        #expect(timing.line.contains("—"))
    }
}
