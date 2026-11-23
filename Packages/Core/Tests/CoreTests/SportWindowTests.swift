import Foundation
import Testing

@testable import Core

/// The window of the schedule — the calculation that sat unchecked in the view layer
/// until 2026-08-29 and has not been a day any more since 2026-09-02.
///
/// **Why these checks exist.** For ``SportModel`` and ``SportView`` there was not a
/// single line of checking in the whole project, and the cut lived there. Exactly
/// there the viewer finding lives too: whoever cuts wrongly sees on the TV either too
/// little or the wrong thing — and no number says which of the two. That is why the
/// **rule** is checked, not the view.
///
/// The fixed clock stands here and is passed in; ``SportWindow`` itself knows none.
@Suite("The window in the schedule")
struct SportWindowTests {

    /// Saturday, 2026-08-29, 15:00 in Berlin — the same clock as the schedule probe, so
    /// that the numbers of both test benches are comparable.
    static let timeZone = TimeZone(identifier: "Europe/Berlin")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func time(_ tag: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: timeZone, year: 2026, month: 8, day: tag, hour: hour,
                minute: minute))!
    }

    static let now = time(29, 15)

    static func event(
        _ title: String, from: Date, until: Date
    ) -> SportEvent {
        SportEvent(
            id: title, kind: .football, competition: nil, title: title, start: from, end: until,
            epgIDs: ["sender.de"])
    }

    static var span: SportWindow.Span { SportWindow.span(now: now) }

    static func list(_ events: [SportEvent]) -> [SportEvent] {
        SportWindow.list(events, span: span, now: now)
    }

    // MARK: - Das Fenster

    /// **It rolls with the clock and not with the calendar** (product decision 2026-09-02). At
    /// 15:00 it reaches to tomorrow 15:00 — not to midnight, which lies exactly in the
    /// middle and with day tabs would separate two rows between which there are 45
    /// minutes.
    @Test("The window starts now and reaches 24 hours ahead")
    func windowBounds() {
        #expect(Self.span.start == Self.now)
        #expect(Self.span.end == Self.time(30, 15))
    }

    /// The look-back is not a display window but reading material for the first-wins rule.
    /// Two days, because the Friday match is still running on Sunday (on-device finding
    /// 2026-08-16).
    @Test("Reading along starts two days before the window")
    func lookback() {
        #expect(Self.span.readAlongFrom == Self.time(27, 15))
    }

    /// **The read window jumps in steps, the display window does not.**
    ///
    /// The result cache hangs on that: its key contains the boundaries of the read window.
    /// If they rolled with the second, every stored answer would be worthless on the next
    /// opening — and the pattern recognition would run again (measured 3.4 s at device
    /// size).
    @Test("The read window snaps hourly, the display window follows the clock")
    func readWindowSnapsToGrid() {
        let early = SportWindow.span(now: Self.time(29, 15, 3))
        let late = SportWindow.span(now: Self.time(29, 15, 57))

        // The same reach into the cache — so the same key.
        #expect(early.readAlongFrom == late.readAlongFrom)
        #expect(early.readUntil == late.readUntil)
        // But a different display window, exact to the second.
        #expect(early.end != late.end)
        #expect(late.end == Self.time(30, 15, 57))
    }

    /// **The read window encloses the display window** — never smaller, otherwise a row
    /// would be missing at the edge. Rounded up means: up to one hour more from the cache,
    /// and cutting happens afterwards with the exact clock.
    @Test("The read window always reaches at least as far as the display")
    func readWindowEncloses() {
        for minute in [0, 1, 30, 59] {
            let span = SportWindow.span(now: Self.time(29, 15, minute))
            #expect(span.readUntil >= span.end)
            #expect(span.readAlongFrom <= span.start)
        }
    }

    // MARK: - Was hereinkommt

    /// **What is running is in — without a separate rule for it.** With day tabs that was
    /// an exception with its own trap (E3: "Tomorrow" carried everything that was just
    /// running). A window that begins at `now` lets it in because its end lies in the
    /// future.
    @Test("What is running now is in the window")
    func running() {
        let running = Self.event(
            "Bergland - Erzfeld", from: Self.time(29, 14, 30), until: Self.time(29, 16, 30))

        #expect(Self.list([running]) == [running])
    }

    /// Also what began yesterday and is still running — a duration cap against that was
    /// measured and rejected in the concept.
    @Test("What has been running since yesterday is in the window too")
    func runningPastMidnight() {
        let ultra = Self.event(
            "Ultra-Trail du Mont-Valmeur", from: Self.time(28, 23), until: Self.time(29, 20))

        #expect(Self.list([ultra]).count == 1)
    }

    @Test("What is over appears nowhere any more")
    func over() {
        let over = Self.event(
            "Lunchtime match", from: Self.time(29, 12), until: Self.time(29, 14))

        #expect(Self.list([over]).isEmpty)
    }

    /// The look-back reads two days along. Without the window boundary it would stand in
    /// the list — and that is exactly the difference between "reading along" and
    /// "showing".
    @Test("The lookback is read, not shown")
    func lookbackStaysOut() {
        let yesterday = Self.event(
            "Friday match", from: Self.time(28, 20, 30), until: Self.time(28, 22, 30))

        #expect(Self.list([yesterday]).isEmpty)
    }

    /// **The gain of the window over the tabs.** The early match of tomorrow 10:30 stood on
    /// a different tab although it is closer than every second row of today. It now
    /// stands in the same list.
    @Test("Tomorrow's early match is in the window too")
    func earlyTomorrowInWindow() {
        let early = Self.event(
            "Sunday match", from: Self.time(30, 10, 30), until: Self.time(30, 12, 30))

        #expect(Self.list([early]).count == 1)
    }

    /// And the boundary applies: what kicks off beyond the 24 hours stays outside —
    /// otherwise the window would be a multi-day view again.
    @Test("Beyond 24 hours it stays outside")
    func beyondTheLimit() {
        let late = Self.event(
            "Evening match tomorrow", from: Self.time(30, 17, 30), until: Self.time(30, 19, 30))

        #expect(Self.list([late]).isEmpty)
    }

    // MARK: - Der Zeitbezug der Zeile

    /// The bare time of day is information about today. The window reaches over midnight —
    /// so the row must say when it means something else.
    @Test("The row says when the kickoff is not today")
    func timeRelation() {
        func reference(_ start: Date) -> SportWindow.TimeRelation {
            SportWindow.timeRelation(start: start, now: Self.now, calendar: Self.calendar)
        }

        #expect(reference(Self.time(29, 14, 30)) == .today)
        #expect(reference(Self.time(29, 0)) == .today)
        #expect(reference(Self.time(29, 23, 59)) == .today)
        #expect(reference(Self.time(30, 0, 1)) == .tomorrow)
        #expect(reference(Self.time(30, 10, 30)) == .tomorrow)
        #expect(reference(Self.time(28, 23, 59)) == .yesterday)
        #expect(reference(Self.time(28, 0)) == .yesterday)
        #expect(reference(Self.time(27, 23, 59)) == .earlier)
    }

    /// **Calendar days, not hours.** At 15:00 only nine hours lie between now and tomorrow
    /// 00:01 — it is tomorrow nonetheless, and the row must say so. A calculation over
    /// hour distances would have claimed "today" here.
    @Test("Calendar days are compared, not hour distances")
    func timeReferenceCountsDays() {
        let shortlyAfterMidnight = Self.time(30, 0, 1)
        #expect(shortlyAfterMidnight.timeIntervalSince(Self.now) < 10 * 3600)
        #expect(
            SportWindow.timeRelation(
                start: shortlyAfterMidnight, now: Self.now, calendar: Self.calendar) == .tomorrow)
    }
}
