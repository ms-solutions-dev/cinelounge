import Foundation
import Testing

@testable import Core

/// Home videos are ordered by month. The test covers the grouping, not the
/// label — the label only comes into being in the view and depends on the
/// selected language.
@Suite("Recordings by month")
struct DateGroupingTests {

    /// A fixed calendar, so the check does not depend on the machine's time zone.
    /// Otherwise a video from 1 January 00:30 lands in December, depending on
    /// the location.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func video(_ id: String, _ recorded: Date?) -> MediaItem {
        MediaItem(id: id, kind: .homeVideo, title: id, recordedAt: recorded)
    }

    @Test("Recordings of the same month land in one group")
    func groupsByMonth() {
        let items = [
            video("a", date(2023, 12, 1)),
            video("b", date(2023, 12, 24)),
            video("c", date(2024, 1, 5)),
        ]

        let groups = DateGroup.byMonth(items, calendar: calendar)

        #expect(groups.count == 2)
        #expect(groups.first?.id == "2024-01", "the most recent month first")
        #expect(groups.last?.items.count == 2)
    }

    @Test("The most recent month is on top, and within it the most recent recording")
    func newestFirst() {
        // Anyone who filmed in December usually looks for the latest, not the first.
        let items = [
            video("früh", date(2023, 12, 3)),
            video("spät", date(2023, 12, 28)),
            video("mitte", date(2023, 12, 15)),
        ]

        let groups = DateGroup.byMonth(items, calendar: calendar)

        #expect(groups.count == 1)
        #expect(groups[0].items.map(\.id) == ["spät", "mitte", "früh"])
    }

    @Test("September comes after December, not before")
    func monthOrderIsNumeric() {
        // The obvious mistake: comparing the identifiers as text, without the
        // leading zero. Then "2023-9" would come after "2023-12".
        let items = [
            video("sep", date(2023, 9, 10)),
            video("dez", date(2023, 12, 10)),
            video("okt", date(2023, 10, 10)),
        ]

        let groups = DateGroup.byMonth(items, calendar: calendar)

        #expect(groups.map(\.id) == ["2023-12", "2023-10", "2023-09"])
    }

    @Test("Recordings without a date go to the end, not under the oldest month")
    func undatedGoLast() {
        // Mixing them in silently would be wrong — people would look for them
        // where they do not belong.
        let items = [
            video("ohne", nil),
            video("mit", date(2020, 5, 1)),
        ]

        let groups = DateGroup.byMonth(items, calendar: calendar)

        #expect(groups.count == 2)
        #expect(groups.last?.id == "undated")
        #expect(groups.last?.month == nil)
        #expect(groups.first?.id == "2020-05")
    }

    @Test("Without undated recordings no empty group appears")
    func noEmptyUndatedGroup() {
        let groups = DateGroup.byMonth([video("a", date(2024, 3, 1))], calendar: calendar)

        #expect(groups.count == 1)
        #expect(!groups.contains { $0.id == "undated" })
    }

    @Test("An empty list yields no groups")
    func emptyInput() {
        #expect(DateGroup.byMonth([], calendar: calendar).isEmpty)
    }

    @Test("The start of the month is passed along for the heading")
    func monthStartProvided() throws {
        // The view needs a date to build "December 2023" in the respective
        // language. A name assembled by hand would be German everywhere.
        let groups = DateGroup.byMonth([video("a", date(2023, 12, 24))], calendar: calendar)
        let month = try #require(groups.first?.month)

        let parts = calendar.dateComponents([.year, .month, .day], from: month)
        #expect(parts.year == 2023)
        #expect(parts.month == 12)
        #expect(parts.day == 1, "the first of the month, not the day of the recording")
    }
}
