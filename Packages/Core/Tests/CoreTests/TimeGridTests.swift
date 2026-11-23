import CoreMedia
import Foundation
import Testing

@testable import Core

/// **F-005 (2026-09-04):** 41, 42, 42, 41 ms instead of 41.708 — the cadence that
/// comes out of millisecond marks when nobody locks on.
@Suite("The time grid")
struct TimeGridTests {
    @Test("23.976 Hz becomes the exact fraction 1001/24000")
    func filmRate() throws {
        let grid = try #require(TimeGrid(nanosecondsPerFrame: 41_708_333))
        #expect(grid.step == CMTime(value: 1001, timescale: 24000))
        #expect(grid.timebase == 24000)
    }

    @Test("25 Hz stays 1/25 and ends up at 90 000")
    func tvRate() throws {
        let grid = try #require(TimeGrid(nanosecondsPerFrame: 40_000_000))
        #expect(grid.step == CMTime(value: 1, timescale: 25))
        #expect(grid.timebase == 90_000)
    }

    @Test("Millisecond marks snap in, real deviations stay")
    func snap() throws {
        let grid = try #require(TimeGrid(nanosecondsPerFrame: 41_708_333))
        let ms = { (value: Int64) in CMTime(value: value * 1_000_000, timescale: 1_000_000_000) }
        // Picture 42,000: 42000 × 41.708 = 1,751,750 ms — the file writes 1,751,750.
        let image: Int32 = 42000
        #expect(grid.snap(ms(1_751_750)) == CMTimeMultiply(grid.step, multiplier: image))
        // Picture 42,001 would be at 1,751,791.7 — the file writes 1,751,792.
        #expect(grid.snap(ms(1_751_792)) == CMTimeMultiply(grid.step, multiplier: image + 1))
        // Twelve milliseconds off is no longer a rounding error.
        #expect(grid.snap(ms(1_751_762)) == ms(1_751_762))
    }

    @Test("Without a value or with a nonsensical one there is no grid")
    func withoutValue() {
        #expect(TimeGrid(nanosecondsPerFrame: nil) == nil)
        #expect(TimeGrid(nanosecondsPerFrame: 0) == nil)
        #expect(TimeGrid(nanosecondsPerFrame: 10) == nil)
    }

    @Test("The grid is detected from the seek table times — and 24 stays 24")
    func detect() throws {
        // Keyframes every 37 pictures over two hours, rounded to milliseconds.
        let film = (0..<200).map { Int64((Double($0 * 37) * 1001.0 / 24000.0 * 1000).rounded()) }
        #expect(
            TimeGrid.detect(marks: film, scale: 1_000_000)?.step
                == CMTime(value: 1001, timescale: 24000))
        // Rounded down instead of rounded (K for Kestrel: 2085 for 2085.4) — it is detected anyway.
        let roundedDown = (0..<200).map { Int64((Double($0 * 37) * 1001.0 / 24000.0 * 1000).rounded(.down)) }
        #expect(
            TimeGrid.detect(marks: roundedDown, scale: 1_000_000)?.step
                == CMTime(value: 1001, timescale: 24000))
        // With phase: 21 ms beside the grid from zero.
        let shifted = film.map { $0 + 21 }
        let detected = try #require(TimeGrid.detect(marks: shifted, scale: 1_000_000))
        #expect(detected.step == CMTime(value: 1001, timescale: 24000))
        #expect(abs(detected.anchor.seconds - 0.021) < 0.0006)
        // And the mark of the 42,000th picture locks onto phase plus grid.
        let tag = CMTime(
            value: (Int64((42000.0 * 1001.0 / 24.0).rounded()) + 21) * 1_000_000, timescale: 1_000_000_000)
        let ideal = detected.anchor + CMTimeMultiply(detected.step, multiplier: 42000)
        #expect(abs((detected.snap(tag) - ideal).seconds) < 0.0000001)
        let cinema = (0..<200).map { Int64((Double($0 * 37) / 24.0 * 1000).rounded()) }
        #expect(
            TimeGrid.detect(marks: cinema, scale: 1_000_000)?.step == CMTime(value: 1, timescale: 24))
        // Too few marks, or marks that fit no grid.
        #expect(TimeGrid.detect(marks: Array(film.prefix(4)), scale: 1_000_000) == nil)
        let jumbled: [Int64] = [0, 1234, 2500, 3999, 5100, 6250, 7777, 9001, 10111, 11500]
        #expect(TimeGrid.detect(marks: jumbled, scale: 1_000_000) == nil)
    }

    @Test("The step can be estimated from 48 marks of a piece — even with a gap")
    func estimate() throws {
        // 48 pictures at 23.976 Hz, rounded down to milliseconds, with one
        // skipped picture in the middle (K for Kestrel).
        var marks: [Int64] = []
        for k in 0..<48 {
            let number = k < 24 ? k : k + 1
            marks.append(Int64((Double(number) * 1001.0 / 24.0 + 1758_760).rounded(.down)))
        }
        let grid = try #require(TimeGrid.estimate(marks: marks, scale: 1_000_000))
        #expect(grid.step == CMTime(value: 1001, timescale: 24000))
        // 24,000 bleibt 24,000.
        let cinema = (0..<48).map { Int64((Double($0) * 1000.0 / 24.0).rounded(.down)) }
        #expect(
            TimeGrid.estimate(marks: cinema, scale: 1_000_000)?.step == CMTime(value: 1, timescale: 24))
        #expect(TimeGrid.estimate(marks: Array(marks.prefix(10)), scale: 1_000_000) == nil)
    }

}
