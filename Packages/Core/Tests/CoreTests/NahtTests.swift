import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The new burst starts before the end of the previous one** — and what comes twice
/// must not play a second time (2026-10-02, Telve on the TV: 20 s of broadcast,
/// 8 s back, 20 s again). Rationale at
/// ``TransportRemuxer/seamOverlap(pts:seam:)``.
@Suite("Burst seam")
struct NahtTests {

    private final class TallyCounter: SampleSink, @unchecked Sendable {
        var frames = 0
        var failure: Error? { nil }
        var needsInterleavedInput: Bool { false }
        func append(video sample: CMSampleBuffer) -> Bool {
            frames += 1
            return true
        }
        func append(audio sample: CMSampleBuffer) -> Bool { true }
        func discontinuity() {}
        func finish() async {}
        func audioTrackChanged() {}
    }

    private func liveData() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts"))
        return try Data(contentsOf: url)
    }

    @Test("A start point far beyond the end is a new timeline, not a seam")
    func onlySixtySecondsBack() {
        let end: UInt64 = 10_000_000
        #expect(TransportRemuxer.seamOverlap(pts: end, seam: end))
        #expect(TransportRemuxer.seamOverlap(pts: end - 8 * 90_000, seam: end))
        #expect(!TransportRemuxer.seamOverlap(pts: end + 1, seam: end))
        #expect(!TransportRemuxer.seamOverlap(pts: end - 61 * 90_000, seam: end))
        // Across the overflow: end just after zero, start just before it.
        #expect(TransportRemuxer.seamOverlap(pts: (1 << 33) - 90_000, seam: 90_000))
    }

    // MARK: - Das Nahtbuch

    @Test("An overlap is recorded in the ledger with start point, discard and continuation")
    func seamLineNamesEverything() throws {
        var ledger = SeamLedger()
        let first = ledger.seam(back: 8.1, discarded: 203, next: 0.4)
        let row = try #require(first)
        #expect(
            row == "Seam no. 1: new burst started 8.1 s before the end, "
                + "203 pictures discarded twice, continued 0.4 s after the end")
        let next = ledger.seam(back: nil, discarded: 0, next: 2.5)
        let second = try #require(next)
        #expect(second.hasPrefix("Seam no. 2: new burst started 2.5 s after the end — gap"))
        #expect(second.contains("so far 2 seams, 1 with overlap"))
        #expect(ledger.balance?.contains("1 with gap") == true)
    }

    @Test("In burst mode the ledger does not flood: five in full, then every tenth")
    func throttlePassesFiveAndEveryTenth() {
        var ledger = SeamLedger()
        var rows: [Int] = []
        for nr in 1...30 where ledger.seam(back: 8, discarded: 1, next: 0.2) != nil {
            rows.append(nr)
        }
        #expect(rows == [1, 2, 3, 4, 5, 10, 20, 30])
        #expect(ledger.seams == 30, "every one is counted, including the throttled ones")
    }

    @Test("The distance on the circle has a sign, even across the wraparound")
    func circularDistanceWithSign() {
        #expect(TransportRemuxer.circularDistance(from: 900_000, until: 180_000) == -8)
        #expect(TransportRemuxer.circularDistance(from: 180_000, until: 900_000) == 8)
        #expect(TransportRemuxer.circularDistance(from: (1 << 33) - 90_000, until: 90_000) == 2)
    }

    // MARK: - Die Stille-Frist

    /// **The delivery pauses of the edge** (probe 2026-10-03, Telve 1 HQ): up to 3.0 s, always at
    /// a good 21 s lead. A three-second deadline broke off exactly there.
    @Test("With a lead the line may stay silent longer, without it stays at three seconds")
    func silentDeadlineFollowsTheLead() {
        #expect(LiveRemuxSession.silenceDeadline(lead: nil) == 3)
        #expect(LiveRemuxSession.silenceDeadline(lead: 2) == 3)
        #expect(LiveRemuxSession.silenceDeadline(lead: 8) == 5)
        #expect(LiveRemuxSession.silenceDeadline(lead: 21) == 10, "the 3.0 s pause holds")
        #expect(LiveRemuxSession.silenceDeadline(lead: 60) == LiveRemuxSession.silenceUpperLimit)
    }
}
