import Foundation
import Testing

@testable import Core

@Suite("Establishing decode order")
struct DecodeOrderTests {

    /// The timestamps from `mkv-hevc-aac`, as they really are in the file.
    static let real: [Int64] = [0, 209, 125, 42, 83, 167, 417, 334, 250, 292, 375]

    static func run(_ times: [Int64], window: Int = 4) -> (DecodeOrder, [DecodeOrder.Timing]) {
        var order = DecodeOrder(window: window)
        var result: [DecodeOrder.Timing] = []
        for time in times { result += order.push(time) }
        result += order.flush()
        return (order, result)
    }

    /// **The one property that matters.** If it is violated, the
    /// writer refuses — or accepts and writes something that stutters.
    @Test("Decode times ascend and never fall behind presentation")
    func decodeTimesAreOrdered() {
        let (order, timings) = Self.run(Self.real)

        #expect(timings.count == Self.real.count)
        #expect(zip(timings, timings.dropFirst()).allSatisfy { $0.decode < $1.decode })
        for timing in timings {
            #expect(timing.decode <= timing.presentation, "decode time behind presentation")
        }
        #expect(order.correctionCount == 0, "The window was not enough")
    }

    /// **The presentation order must not change.** Everything is shifted
    /// by the same amount — otherwise it would not be a shift but
    /// a reordering.
    @Test("Presentation stays, it only moves backward")
    func presentationOnlyShifts() {
        let (order, timings) = Self.run(Self.real)
        #expect(timings.map { $0.presentation - order.delay } == Self.real)

        // **The shift reaches at least one window length.**
        //
        // This used to say `== 167` — the furthest fall-back observed in the window.
        // Exactly this rule ruined "Jade Comet": What is in the
        // first frames says nothing about the rest of the film. The
        // condition now no longer reads "as much as observed" but
        // "as much as this window can reorder at all".
        //
        // Four frames of window, distance 42 → at least 168.
        #expect(order.delay >= 167)
        #expect(order.delay == 4 * 42)
    }

    /// **The decode times are the same values, just sorted.** No
    /// invented number, no guessed frame duration.
    @Test("Decode times are the presentation times, in sorted order")
    func decodeTimesAreTheSameValues() {
        let (_, timings) = Self.run(Self.real)
        #expect(timings.map(\.decode) == Self.real.sorted())
    }

    /// **A stream without reordering is shifted anyway — and that is the
    /// whole fix.**
    ///
    /// This used to say `delay == 0` and "the presentation stays unchanged". That was
    /// the rule "Jade Comet" broke on (on-device finding 2026-08-23): The
    /// intro of this episode is encoded without reordering, so the
    /// shift was calibrated to zero — and held for the whole film.
    /// The rest of the file reorders by up to three frames; measured afterwards, every
    /// fifth frame carried the same display time as its neighbour.
    ///
    /// What really counts is stated below: **Distances and order stay
    /// untouched.** Where the timeline as a whole sits, nobody sees — picture
    /// and audio move together.
    @Test("Even a straight stream is shifted, but not distorted")
    func straightStreamIsShiftedNotDistorted() {
        let straight: [Int64] = [0, 40, 80, 120, 160, 200]
        let (order, timings) = Self.run(straight)

        #expect(order.delay == 4 * 40)
        #expect(timings.map { $0.presentation - order.delay } == straight)
        #expect(timings.map(\.decode) == straight)
        #expect(order.correctionCount == 0)
    }

    /// **The "Jade Comet" case, recorded as a rule.**
    ///
    /// A stream whose start is encoded without reordering and which later
    /// reorders. The old calibration saw nothing in the intro, set the
    /// shift to zero and then let the stopgap do the work — every
    /// frame nudged into place got the time of another one.
    ///
    /// **The condition that pins it down: no two frames at the same
    /// display time.** That is the quantity visible on screen,
    /// and it was nowhere before.
    @Test("A late-reordering stream gets no duplicate timestamps")
    func lateReorderingKeepsDistinctTimes() {
        // Twelve frames straight, then groups of three in decode order.
        var times: [Int64] = (0..<12).map { Int64($0) * 42 }
        for group in 0..<6 {
            let base = Int64(12 + group * 3) * 42
            times += [base + 84, base, base + 42]
        }

        let (order, timings) = Self.run(times, window: 8)

        #expect(order.correctionCount == 0, "the fallback had to kick in")
        let shown = timings.map(\.presentation)
        #expect(Set(shown).count == shown.count, "two pictures at the same timestamp")
        // **Not** ascending: Output is in decode order, not in
        // display order — that is what B-frames are for. Sorted, though, the
        // times must again carry the distances of the template.
        #expect(shown.sorted().map { $0 - order.delay } == times.sorted())
    }

    /// **A window that is too small stays correct, it only notices.** Both
    /// conditions are still kept — if necessary the presentation catches
    /// up, and the count says that it happened.
    @Test("A window that is too narrow is noticed, not hidden")
    func tooNarrowWindowIsCounted() {
        let (order, timings) = Self.run(Self.real, window: 1)

        #expect(order.correctionCount > 0)
        #expect(zip(timings, timings.dropFirst()).allSatisfy { $0.decode < $1.decode })
        for timing in timings {
            #expect(timing.decode <= timing.presentation)
        }
    }
}
