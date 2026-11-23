import Core
import Foundation
import Testing

@testable import PlaylistKit

/// The whole schedule stretch: programmes in the download store → events.
///
/// **The on-device finding of 2026-08-16. ("Sport stays empty despite sync")** — here
/// the stretch that stayed silent on the device is reproduced: the download store carries
/// programmes, the query over the time window must yield them, and the
/// schedule must build events from them.
@Suite("Schedule: from the cache to the event list")
struct SportPipelineTests {

    @Test("What lies in the cache comes out as an event")
    func storedProgrammesBecomeEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spielplan-\(UUID().uuidString)")
        let cache = LiveCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let programmes = [
            Programme(
                id: "p1", channelID: "arenaspor1.tr",
                title: "Süper Lig: Demirbahçe - Kalesaray",
                start: now.addingTimeInterval(3600), end: now.addingTimeInterval(3600 * 3)),
            Programme(
                id: "p2", channelID: "kanal1.tr",
                title: "Süper Lig: Demirbahçe - Kalesaray",
                start: now.addingTimeInterval(3600), end: now.addingTimeInterval(3600 * 3)),
            // A rerun — must not come out.
            Programme(
                id: "p3", channelID: "arenaspor1.tr",
                title: "Süper Lig Maç Özeti",
                start: now.addingTimeInterval(7200), end: now.addingTimeInterval(9000)),
        ]
        await cache.save(programmes: programmes)
        #expect(await cache.programmeCount() == 3, "the store must really arrive")

        // The time-window query — the schedule's new path.
        let day = await cache.programmes(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(24 * 3600))
        #expect(day.count == 3, "the cache must yield all three")

        let events = SportPlan.events(from: day)
        #expect(events.count == 1, "one match, two channels, no repeat")
        #expect(events.first?.epgIDs.sorted() == ["arenaspor1.tr", "kanal1.tr"])
    }

    /// The silent failure of 2026-08-16, reproduced: if the database lies in
    /// an unwritable directory (on tvOS it was Application
    /// Support), nothing may crash — but the counter must tell the truth:
    /// zero arrived, not "61.026 in the download store".
    @Test("Unwritable directory: nothing crashes, the counter says zero")
    func unwritableDirectoryStaysHonest() async throws {
        let cache = LiveCache(
            directory: URL(fileURLWithPath: "/System/cinelounge-nie-beschreibbar"))
        let now = Date()
        await cache.save(programmes: [
            Programme(
                id: "p1", channelID: "kanal1.tr", title: "Süper Lig: A - B",
                start: now, end: now.addingTimeInterval(3600))
        ])
        #expect(await cache.programmeCount() == 0)
        #expect(await cache.hasProgrammes() == false)
        #expect(await cache.programmes(from: now, to: now.addingTimeInterval(3600)).isEmpty)
    }
}
