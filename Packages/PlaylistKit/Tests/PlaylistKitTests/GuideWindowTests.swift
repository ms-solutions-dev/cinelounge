import Core
import Foundation
import Testing

@testable import PlaylistKit

/// How far the programme reaches that the cache hands out.
///
/// **The finding from 2026-08-11:** "The programme run is always cut off, earlier
/// broadcasts cannot be seen — the whole day should actually be
/// visible." It was correct and the cause sat in a condition: `stop >
/// now`. The window began at the moment of the question, so there was no before.
///
/// Both are tested — that the past is now included **and** that it stays
/// bounded. A cache holds three days per channel; whoever delivers everything
/// swaps a cut-off programme for a hundred rows to scroll through.
@Suite("The programme window")
struct GuideWindowTests {

    private static func freshCache() -> LiveCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cinelounge-programm-\(UUID().uuidString)")
        return LiveCache(directory: directory)
    }

    /// A day's programme in hourly steps around the zero point.
    private func day(around now: Date, hoursBefore: Int, hoursAfter: Int) -> [Programme] {
        (-hoursBefore..<hoursAfter).map { hour in
            Programme(
                id: "p\(hour)",
                channelID: "epg1",
                title: "Sendung \(hour)",
                start: now.addingTimeInterval(TimeInterval(hour) * 3600),
                end: now.addingTimeInterval(TimeInterval(hour + 1) * 3600)
            )
        }
    }

    @Test("What just ended is part of the programme")
    func theRecentPastIsIncluded() async {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let cache = Self.freshCache()
        await cache.save(programmes: day(around: now, hoursBefore: 6, hoursAfter: 6))

        let listing = await cache.programmes(epgID: "epg1", around: now)
        let titles = listing.map(\.title)

        // Two hours back is inside the window …
        #expect(titles.contains("Sendung -2"))
        // … and the running one is still included.
        #expect(titles.contains("Sendung 0"))
    }

    @Test("The morning of the day before yesterday is not")
    func theDistantPastIsNot() async {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let cache = Self.freshCache()
        await cache.save(programmes: day(around: now, hoursBefore: 12, hoursAfter: 6))

        let listing = await cache.programmes(epgID: "epg1", around: now)

        // The limit is at three hours; the fourth no longer belongs.
        #expect(!listing.map(\.title).contains("Sendung -5"))
    }

    @Test("Forward it reaches beyond the evening")
    func theRestOfTheDayIsIncluded() async {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let cache = Self.freshCache()
        await cache.save(programmes: day(around: now, hoursBefore: 1, hoursAfter: 30))

        let listing = await cache.programmes(epgID: "epg1", around: now)
        let titles = listing.map(\.title)

        #expect(titles.contains("Sendung 20"))
        // But not endless: the day after tomorrow is a different question.
        #expect(!titles.contains("Sendung 25"))
    }

    /// **The order is guaranteed and needed.** The overlay
    /// scrolls to the running broadcast and continues from there with up and down;
    /// an unsorted list would mean that "the next one" sits somewhere.
    @Test("Sorted by start time, past first")
    func sortedByStart() async {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let cache = Self.freshCache()
        await cache.save(programmes: day(around: now, hoursBefore: 3, hoursAfter: 3).reversed())

        let listing = await cache.programmes(epgID: "epg1", around: now)

        #expect(listing == listing.sorted { $0.start < $1.start })
        #expect(listing.first?.start ?? now < now)
    }
}
