import Foundation
import Testing

@testable import Core

/// **What the single line cannot say** (AP12, 2026-09-02).
///
/// ``StartupTiming`` measures one start. The finding of 2026-08-11 is about many,
/// though — "sometimes fast, sometimes slow" is a statement about the spread. These
/// checks record when the summary states that and when it does not.
@Suite("Startup: the balance of a session")
struct StartupBalanceTests {

    /// Builds a completed measurement with a given total duration.
    private func measurement(_ route: String, _ seconds: TimeInterval) -> StartupTiming {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var timing = StartupTiming(opening: route, startedAt: start)
        timing.markReady(at: start.addingTimeInterval(seconds / 2))
        timing.markFirstFrame(at: start.addingTimeInterval(seconds))
        return timing
    }

    @Test("Median and range are listed separately per delivery route")
    func medianAndSpreadPerPath() {
        let balance = StartupTally()
        for value in [1.0, 2.0, 3.0] { balance.take(measurement("nativ/remuxInApp", value)) }
        for value in [0.4, 0.5] { balance.take(measurement("nativ/directPlay", value)) }

        let rows = balance.rows
        #expect(rows.count == 2)
        // The most-used path first — it carries the session.
        #expect(rows.first?.route == "nativ/remuxInApp")
        #expect(rows.first?.count == 3)
        #expect(rows.first?.median == 2.0)
        #expect(rows.first?.smallest == 1.0)
        #expect(rows.first?.largest == 3.0)
        // **And the paths stay separate.** Thrown together, every session in which both
        // occurred would look uneven — that is, every one.
        #expect(rows.last?.count == 2)
        #expect(rows.last?.largest == 0.5)
    }

    @Test("A steady startup is not reported as a defect")
    func steadyStartupIsNoFinding() {
        let balance = StartupTally()
        for value in [1.2, 1.3, 1.25, 1.4, 1.35] { balance.take(measurement("nativ/hls", value)) }

        let row = balance.rows[0]
        #expect(!row.isUneven)
        #expect(!row.row.contains("uneven"))
    }

    @Test("A fluctuating startup says so itself")
    func unsteadyStartupSaysSo() {
        let balance = StartupTally()
        // Exactly the finding of 2026-08-11: sometimes one and a half seconds, sometimes five.
        for value in [1.5, 5.0, 1.6, 4.8] { balance.take(measurement("nativ/remuxInApp", value)) }

        let row = balance.rows[0]
        #expect(row.isUneven)
        #expect(row.row.contains("uneven"))
    }

    /// **The threshold that does not turn the normal case into a defect.** Two starts are
    /// no spread: The first of a session is regularly the slowest, because downloads and
    /// connections are not up yet.
    @Test("Two starts do not yet give a verdict")
    func twoStartsAreNoVerdict() {
        let balance = StartupTally()
        balance.take(measurement("nativ/remuxInApp", 1.0))
        balance.take(measurement("nativ/remuxInApp", 6.0))

        #expect(!balance.rows[0].isUneven)
    }

    /// **Fast and faster is no defect.** The ratio alone would be worthless for short
    /// paths — a factor of 2.3 between 180 and 420 ms is noticed by nobody.
    @Test("Far apart, but both fast — no finding")
    func fastEvenIfSpreadWide() {
        let balance = StartupTally()
        for value in [0.18, 0.42, 0.2, 0.4] { balance.take(measurement("nativ/directPlay", value)) }

        #expect(!balance.rows[0].isUneven)
    }

    /// **A start without a picture is not a missing measurement, but the worst one.**
    /// Anyone who left it out would flatter a session in which every third channel stayed
    /// black.
    @Test("Routes without a single picture do not vanish from the balance")
    func abandonedStartsStayVisible() {
        let balance = StartupTally()
        balance.recordAbort(route: "nativ/remuxInApp")
        balance.recordAbort(route: "nativ/remuxInApp")

        let row = balance.rows[0]
        #expect(row.count == 0)
        #expect(row.aborts == 2)
        #expect(row.row.contains("gave up without a frame: 2"))
    }

    /// An incomplete measurement carries no duration — it must not shift the median with
    /// an invented zero.
    @Test("A measurement without a first picture does not enter the median")
    func incompleteMeasurementIsIgnored() {
        let balance = StartupTally()
        let start = Date(timeIntervalSince1970: 1_000_000)
        var pending = StartupTiming(opening: "nativ/hls", startedAt: start)
        pending.markReady(at: start.addingTimeInterval(0.3))
        balance.take(pending)

        #expect(balance.rows.isEmpty)
    }

    /// A long session should not fill the memory — and the limit has to keep the most
    /// recent values, not the oldest.
    @Test("The balance keeps only the most recent values")
    func onlyTheNewestValuesAreKept() {
        let balance = StartupTally()
        for _ in 0..<StartupTally.retentionLimit { balance.take(measurement("nativ/hls", 9.0)) }
        for _ in 0..<StartupTally.retentionLimit { balance.take(measurement("nativ/hls", 1.0)) }

        let row = balance.rows[0]
        #expect(row.count == StartupTally.retentionLimit)
        #expect(row.largest == 1.0)
    }
}
