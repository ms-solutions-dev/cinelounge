import Foundation
import Testing

@testable import Core

/// How a measured line becomes a quality level.
///
/// It is needed when the app measures the bandwidth itself instead of asking the
/// viewer. The detour via a level is intentional: each level carries a
/// matching picture width, and a limit without a width yields a picture of blocks
/// although the number is right.
@Suite("Translating a measured line into a tier")
struct StreamQualityFittingTests {

    @Test("A measured rate yields the highest tier that still fits")
    func picksHighestFitting() {
        #expect(StreamQuality.fitting(25_000_000) == .veryHigh)
        #expect(StreamQuality.fitting(8_000_000) == .high)
        #expect(StreamQuality.fitting(4_000_000) == .medium)
        #expect(StreamQuality.fitting(2_000_000) == .low)
    }

    @Test("Never rounds up")
    func neverRoundsUp() {
        // Seven megabits yield the level for four, not the one for eight. The measurement
        // is a snapshot, and a line tends to get worse rather than better over the
        // course of a movie — whoever rounds up gets a picture that freezes twenty
        // minutes later.
        #expect(StreamQuality.fitting(7_999_999) == .medium)
        #expect(StreamQuality.fitting(19_999_999) == .high)
    }

    @Test("The measured tunnel lands on the lowest tier")
    func tunnelHitsMinimal() {
        // The real measurement from this project: 0.3 Mbit/s through the WireGuard tunnel.
        // Only the lowest level remains there. It looks bad and plays — that
        // is the difference between a picture and a waiting spinner.
        #expect(StreamQuality.fitting(300_000) == .minimal)
        #expect(StreamQuality.fitting(0) == .minimal)
    }

    @Test("A nonsensical measurement yields no high tier")
    func negativeMeasurementIsSafe() {
        // A measurement can go wrong and return a negative value. If that produced
        // a high level, the automatic mode would be more dangerous in a failure
        // than without it.
        #expect(StreamQuality.fitting(-1) == .minimal)
    }

    @Test("Of two limits the stricter one applies")
    func strictestWins() {
        // Both paths can apply at the same time: the viewer has set a level,
        // and the measurement says the line carries even less. Taking the larger one
        // would mean silently ignoring one of the two inputs.
        #expect(StreamQuality.high.stricter(than: .low) == .low)
        #expect(StreamQuality.low.stricter(than: .high) == .low)
        #expect(StreamQuality.minimal.stricter(than: .veryHigh) == .minimal)
    }

    @Test("Unlimited loses against any limit")
    func unlimitedLoses() {
        // Otherwise one side cancels the other: whoever has set nothing should let the
        // measurement take effect — and whoever has set something should keep it, even
        // if there is no measurement.
        #expect(StreamQuality.unlimited.stricter(than: .medium) == .medium)
        #expect(StreamQuality.medium.stricter(than: .unlimited) == .medium)
        #expect(StreamQuality.unlimited.stricter(than: .unlimited) == .unlimited)
    }

    @Test("Every tier except unlimited names rate and width")
    func everyStepIsComplete() {
        // A level with a rate but no width is exactly the trap described at maxWidth.
        // A test case against it is cheaper than the finding later.
        for step in StreamQuality.allCases where step != .unlimited {
            #expect(step.bitrate != nil, "\(step.rawValue) has no rate")
            #expect(step.maxWidth != nil, "\(step.rawValue) has no width")
        }
        #expect(StreamQuality.unlimited.bitrate == nil)
        #expect(StreamQuality.unlimited.maxWidth == nil)
    }

    @Test("The tiers are ordered by rate")
    func stepsAreOrdered() {
        // `fitting` runs through the levels from top to bottom and takes the first
        // matching one. If the order in `allCases` were not descending, the
        // wrong level would come out — and that would only show at an intermediate value.
        let rates = StreamQuality.allCases.compactMap(\.bitrate)
        #expect(rates == rates.sorted(by: >), "order: \(rates)")
    }
}
