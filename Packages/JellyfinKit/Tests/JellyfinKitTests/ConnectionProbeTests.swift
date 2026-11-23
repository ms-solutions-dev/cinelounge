import Foundation
import Testing

@testable import JellyfinKit

/// The classification of the connection measurement — five cases in fixed order.
///
/// What is checked is the finding, not the measurement: ``ConnectionProbe/run()`` goes
/// onto the network, ``ConnectionProbe/Result/finding`` is a pure function over three
/// numbers. Exactly for this the named case stands in the source — the promise is only
/// redeemed here.
@Suite("Connection measurement: finding and report")
struct ConnectionProbeTests {

    private func result(
        latencies: [Double], throughput: Double? = nil, lost: Int = 0
    ) -> ConnectionProbe.Result {
        ConnectionProbe.Result(latencies: latencies, throughput: throughput, lost: lost)
    }

    @Test("With no answer at all the finding is unreachable")
    func noAnswerAtAll() {
        let probe = result(latencies: [], lost: ConnectionProbe.latencySamples)
        #expect(probe.finding == .unreachable)
        #expect(probe.finding.isProblem)
    }

    @Test("Lost requests mask spread and throughput")
    func lossOutranksTheRest() {
        // The order IS the statement: whoever loses packets, their throughput no longer says
        // anything. A reordered chain would otherwise go unnoticed.
        #expect(result(latencies: [5, 6, 7], throughput: 300, lost: 1).finding == .packetLoss)
        #expect(result(latencies: [5, 900], throughput: 1, lost: 1).finding == .packetLoss)
    }

    @Test("Spread triggers before throughput, and only above the limit")
    func jitterBeforeThroughput() {
        let limit = ConnectionProbe.Result.jitterThreshold
        #expect(result(latencies: [5, limit + 1], throughput: 300).finding == .jitter)
        // Exactly on the boundary it is not yet scatter — `>` and not `>=`.
        #expect(result(latencies: [5, limit], throughput: 300).finding == .healthy)
        // An unreliable route is not dismissed as "too slow".
        #expect(result(latencies: [5, limit + 1], throughput: 1).finding == .jitter)
    }

    @Test("Too little throughput on a clean path")
    func tooSlowOnACleanLine() {
        let minimum = ConnectionProbe.Result.minimumThroughput
        #expect(result(latencies: [5, 6, 7], throughput: minimum - 0.1).finding == .tooSlow)
        #expect(result(latencies: [5, 6, 7], throughput: minimum).finding == .healthy)
        #expect(result(latencies: [5, 6, 7], throughput: 300).finding == .healthy)
    }

    @Test("The median is the upper of two middles, the worst is the largest")
    func medianAndWorst() {
        let probe = result(latencies: [40, 10, 30, 20])
        #expect(probe.medianLatency == 30)
        #expect(probe.worstLatency == 40)
    }

    @Test("Without an answer the report has no invented zero")
    func summaryWithoutAnySample() {
        // The error this check stands against (fixed 2026-08-26): with an empty series of
        // measurements, middle and worst both returned zero — in the report the best possible
        // response time stood directly above "not reachable".
        let probe = result(latencies: [], lost: 12)
        let rows = probe.summary.split(separator: "\n").map(String.init)

        #expect(rows.count == 2)
        #expect(rows[0] == "Response time: no answer at all (12 requests without a reply)")
        #expect(rows[1] == probe.verdict)
        #expect(!probe.summary.contains("median"))
        #expect(!probe.summary.contains("0 ms"))
    }

    @Test("The report lists every measured number — and only those")
    func summaryCarriesTheMeasuredNumbers() {
        let probe = result(latencies: [10, 20, 30], throughput: 42, lost: 2)
        let rows = probe.summary.split(separator: "\n").map(String.init)

        #expect(rows[0] == "Response time: median 20 ms, worst 30 ms")
        #expect(rows[1] == "Unanswered: 2")
        #expect(rows[2] == "Throughput: 42 Mbit/s")
        // The denominator is the number of requests ISSUED, not of those that arrived.
        #expect(rows[3].hasPrefix("2 of 5 requests did not arrive at all."))
    }

    @Test("Without measured throughput the line is not acquitted")
    func healthyWithoutThroughputIsNoAcquittal() {
        // No information, no acquittal: ``measureThroughput()`` silently returns `nil` in three
        // of four error cases. "Connection fine" then acquitted the line without having
        // measured what matters for a film.
        let probe = result(latencies: [5, 6, 7], throughput: nil)
        #expect(probe.finding == .healthy)
        #expect(!probe.verdict.contains("Connection fine"))
        #expect(probe.verdict.contains("throughput not measured"))
    }

    @Test("A measured throughput turns “unreachable” into a wait time")
    func throughputContradictsUnreachable() {
        // The state can be produced: `reachable()` aborts after 5 s, the throughput fetch has
        // its own 30 s. A server that answers in between lets all the small requests pile up
        // and pushes the big one through.
        let probe = result(latencies: [], throughput: 300, lost: ConnectionProbe.latencySamples)
        #expect(probe.finding == .unreachable)
        #expect(probe.finding.isProblem)

        let report = probe.summary
        // The line above reads "Throughput: 300 Mbit/s". The sentence below was allowed to claim
        // "the server was not reachable" until 2026-08-26.
        #expect(report.contains("300 Mbit/s"))
        #expect(!report.contains("unreachable"))
        #expect(report.contains("first byte"))

        // Without the big fetch the old, then accurate sentence stays.
        #expect(result(latencies: [], lost: 12).summary.contains("unreachable"))
    }
}
