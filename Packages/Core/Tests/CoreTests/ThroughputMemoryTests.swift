import Foundation
import Testing

@testable import Core

/// The automatic quality choice: when a measurement may have a say.
@Suite("Measured throughput")
struct ThroughputMemoryTests {

    @Test("A tight, fresh measurement becomes the limit")
    func tightMeasurementConstrains() {
        let store = InMemoryStore()
        ThroughputMemory.save(mbps: 12.5, at: Date(timeIntervalSince1970: 1000), to: store)

        let limit = ThroughputMemory.constrainingBitrate(
            from: store,
            now: Date(timeIntervalSince1970: 2000)
        )
        #expect(limit == 12_500_000)
    }

    @Test("A healthy line is not capped")
    func healthyLineStaysSilent() {
        // The levels end at twenty megabits. If a 300 measurement were
        // passed through, `fitting` would clip precisely the best line to
        // the highest level — and a UHD title would be transcoded that it
        // carries with ease.
        let store = InMemoryStore()
        ThroughputMemory.save(mbps: 300, at: Date(timeIntervalSince1970: 1000), to: store)

        #expect(
            ThroughputMemory.constrainingBitrate(
                from: store,
                now: Date(timeIntervalSince1970: 2000)
            ) == nil
        )
    }

    @Test("An old measurement expires")
    func staleMeasurementExpires() {
        // Networks change: yesterday's tunnel measurement must not force the
        // movie night on the home network to the lowest level.
        let store = InMemoryStore()
        ThroughputMemory.save(mbps: 5, at: Date(timeIntervalSince1970: 0), to: store)

        let sevenHoursLater = Date(timeIntervalSince1970: 7 * 60 * 60)
        #expect(ThroughputMemory.constrainingBitrate(from: store, now: sevenHoursLater) == nil)

        let fiveHoursLater = Date(timeIntervalSince1970: 5 * 60 * 60)
        #expect(ThroughputMemory.constrainingBitrate(from: store, now: fiveHoursLater) != nil)
    }

    @Test("Without a measurement and with nonsense it stays quiet")
    func missingOrBrokenValuesStaySilent() {
        let store = InMemoryStore()
        #expect(ThroughputMemory.constrainingBitrate(from: store) == nil)

        try? store.set("kaputt", for: "playback.measuredThroughput")
        #expect(ThroughputMemory.constrainingBitrate(from: store) == nil)

        try? store.set("0|1000", for: "playback.measuredThroughput")
        #expect(ThroughputMemory.constrainingBitrate(from: store) == nil)
    }
}
