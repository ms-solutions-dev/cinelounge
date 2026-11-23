import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The frame cadence has to be measured, not estimated.**
///
/// On 2026-08-22 the engine announced the same channel to the TV within eighteen seconds with
/// 24, then 25, then 50 Hz — it can only read the frame rate from
/// its own drawing rate, and during startup that is still half the
/// truth. The remuxer has the number already: It sees every frame spacing.
@Suite("The frame cadence")
struct FrameCadenceTests {

    private func filled(_ gaps: [Double]) -> FrameCadence {
        var cadence = FrameCadence()
        for gap in gaps { cadence.add(gap) }
        return cadence
    }

    /// A uniform stream yields exactly its rate.
    @Test("Even gaps yield the rate they are")
    func evenGapsGiveTheirRate() throws {
        #expect(filled(Array(repeating: 0.02, count: 100)).rate == 50)
        #expect(filled(Array(repeating: 0.04, count: 100)).rate == 25)
        #expect(try #require(filled(Array(repeating: 1.0 / 24, count: 100)).rate) == 24)
    }

    /// **No number without a basis.** If anything came out here already, exactly
    /// the wrong number would go to the TV — and it would switch.
    @Test("Below the minimum count the cadence stays silent")
    func staysSilentBelowTheMinimum() {
        let few = filled(Array(repeating: 0.02, count: FrameCadence.minimumSamples - 1))
        #expect(few.rate == nil)
        #expect(few.jitter == nil)

        let enough = filled(Array(repeating: 0.02, count: FrameCadence.minimumSamples))
        #expect(enough.rate == 50)
    }

    /// **The median and not the average.** A burst restart at the
    /// provider sets a coarse outlier every nine seconds; an
    /// average would visibly be pulled by it, the median not.
    @Test("Single outliers do not shift the rate")
    func outliersDoNotMoveTheRate() {
        var gaps = Array(repeating: 0.02, count: 100)
        gaps[10] = 0.4
        gaps[50] = 0.35
        #expect(filled(gaps).rate == 50)
    }

    /// Implausible values are not even taken in: A spacing of zero
    /// arises where the monotonicity stopgap resolved a timestamp collision,
    /// and a half-second jump is not a frame rate.
    @Test("Implausible gaps do not count")
    func implausibleGapsAreRefused() {
        var cadence = FrameCadence()
        for gap in [0.0, -1.0, 0.0001, 0.6, 5.0] { cadence.add(gap) }
        #expect(cadence.gaps.isEmpty)
    }

    /// The irregularity is the separating question for judder: clean stream
    /// near zero, uneven one clearly above.
    @Test("The irregularity shows what is unevenly spaced")
    func jitterSeparatesTheCases() throws {
        #expect(try #require(filled(Array(repeating: 0.02, count: 100)).jitter) == 0)

        // Every second frame too early, every second one too late — exactly the pattern
        // a viewer sees as stuttering. The median then lies on one
        // of the two halves, and the other counts as an outlier: half of them.
        let uneven = (0..<100).map { $0.isMultiple(of: 2) ? 0.01 : 0.03 }
        #expect(try #require(filled(uneven).jitter) >= 0.5)
    }

    /// The cap keeps the list finite — a channel runs for hours.
    @Test("Above the maximum count nothing more is collected")
    func stopsCollectingAtTheCeiling() {
        let many = filled(Array(repeating: 0.02, count: FrameCadence.maximumSamples + 500))
        #expect(many.gaps.count == FrameCadence.maximumSamples)
    }
}

/// The same cadence, but on the real stream — the rules above are useless if
/// the remuxer never feeds them.
@Suite("The frame cadence on a real recording")
struct RemuxerCadenceTests {

    private func fed(_ data: Data, chunk: Int = 65536) -> TransportRemuxer {
        let remuxer = TransportRemuxer(store: SegmentStore(label: "cadence", logsProduction: false))
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + chunk, data.endIndex)
            remuxer.feed(Data(data[offset..<end]))
            offset = end
        }
        return remuxer
    }

    /// **The median systematically misses a quantised source.**
    ///
    /// Both provider transcoders and every Matroska file stamp onto a
    /// millisecond grid. At 59.94 Hz the spacings alternate between 16 and
    /// 17 ms — the median takes the more frequent one and yields **58.82 Hz**, a
    /// frame rate that does not exist. It is then discarded, and the channel
    /// gets no announcement at all.
    @Test("A millisecond grid still yields the true rate")
    func millisecondGridStillYieldsTheTruth() throws {
        // Quantised like a real source: The timestamps arise from the
        // true rate and are rounded to whole milliseconds — the
        // spacings thereby alternate between 16 and 17 ms.
        #expect(abs(try #require(Self.gridded(hertz: 59.94).rate) - 59.94) < 0.2)
    }

    /// The same for 23.976 Hz from a Matroska — there it would read 24.0 Hz: a
    /// repeated frame every 41.7 seconds.
    @Test("23.976 Hz from a file does not become 23.81")
    func filmRateSurvivesTheGrid() throws {
        #expect(abs(try #require(Self.gridded(hertz: 23.976).rate) - 23.976) < 0.2)
    }

    /// **And the lesson of 2026-08-11 still holds**: A burst boundary must not
    /// pull the rate. Averaging happens only over what is near the median
    /// — the outlier is thrown out beforehand.
    @Test("A burst jump still does not pull the rate")
    func burstBoundaryStillDoesNotPull() {
        var cadence = FrameCadence()
        for _ in 0..<60 { cadence.add(0.04) }
        cadence.add(0.31)
        for _ in 0..<60 { cadence.add(0.04) }
        #expect(cadence.rate == 25.0)
    }

    /// Builds the spacings the way a channel stamps them: computed from the true rate
    /// and rounded to whole milliseconds.
    private static func gridded(hertz: Double, frames: Int = 200) -> FrameCadence {
        var cadence = FrameCadence()
        var previous = 0
        for index in 1...frames {
            let stamp = Int((Double(index) * 1000 / hertz).rounded())
            cadence.add(Double(stamp - previous) / 1000)
            previous = stamp
        }
        return cadence
    }

}
