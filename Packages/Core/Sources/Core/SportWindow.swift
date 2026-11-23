import Foundation

/// The window of the schedule: **the next 24 hours**, what stands in it, and how
/// the time column recognises that a kickoff lies on a different calendar day.
///
/// **Why a window and no more days** (product decision 2026-09-02: no 3-day preview,
/// only one view with 24 hours — then the 3 bars for the days can go). The day
/// tabs answered a question nobody asks in front of the TV. Whoever opens the
/// area at 22:00 wants to know what is on **now and in the next hours** — and with
/// day tabs that is spread across two tabs: the game at 23:45 on "Today", the one
/// at 00:30 on "Tomorrow", although 45 minutes lie between them. A rolling window
/// knows no such seam.
///
/// It also removes the calculation of how many tabs the stock carries: it was an
/// answer to a self-posed question.
///
/// **Clock-free like the rest of `Core`.** Every calculation takes `now` and the
/// calendar as input. A clock in the calculation core would mean that the same
/// input gives something different tomorrow — then a changed number no longer says
/// whether it was the change or the calendar (the same rule as in the schedule
/// probe).
public enum SportWindow {

    /// How far **before** the window to read along.
    ///
    /// The first broadcast has to come along so that it can swallow its reruns
    /// (first-wins rule in ``SportPlan``). Two days instead of one: the Friday game
    /// still runs on Sundays — a one-day lookback no longer saw its first broadcast
    /// (on-device finding 2026-08-16, "still non-live"). Since E2 the comparison itself is
    /// limited in time (``SportPlan/rerunWindow``), so the lookback measurably costs
    /// no row of today any more.
    public static let lookback: TimeInterval = 48 * 3600

    /// How far the window reaches forward — 24 hours from **now**.
    ///
    /// Not until midnight and not three days: the program guide of this provider is,
    /// measured, a rolling 48-hour window that carries about +24 h from the time of
    /// retrieval. A window that rolls the same way promises nothing the stock cannot
    /// keep.
    public static let lookahead: TimeInterval = 24 * 3600

    /// The step at which the **read window** jumps — one hour.
    ///
    /// **Without it the result cache would be dead** (2026-09-02). The key of the
    /// ``ScheduleCalculator`` contains the bounds of the window that was read; with day
    /// tabs they lay at midnight and were the same for a whole day. A window that
    /// rolls with the clock would bring a new key on every open — and with it every
    /// time the whole pattern recognition (measured at device size: 3.4 s), although
    /// nothing in the stock has changed. That is exactly what the viewer complained
    /// about on 2026-08-29: why is the content reloaded every time I open the app?
    ///
    /// **It costs no freshness.** Reading is generous, cutting uses the exact clock:
    /// ``list(_:span:now:)`` calculates against ``Span/end``, and that is
    /// exactly `now + 24 h` to the second. The grid only determines how much
    /// **more** than necessary comes from the stock.
    public static let cadence: TimeInterval = 3600

    /// The window the area looks at.
    ///
    /// **Two pairs, and the difference is the point.** ``start`` and ``end`` are the
    /// display and run with the second; ``readAlongFrom`` and ``readUntil`` are the grab
    /// into the stock and jump in steps. The read window always encloses the display
    /// window — it is never smaller, otherwise a row would be missing at the edge.
    public struct Span: Equatable, Sendable {
        /// Now — the start of the display window.
        public let start: Date
        /// 24 hours later — exclusive.
        public let end: Date
        /// From when to read along, so that the first broadcast comes along.
        public let readAlongFrom: Date
        /// Until when to read — rounded up to the next step.
        public let readUntil: Date
    }

    public static func span(now: Date) -> Span {
        // Rounded down for the start, rounded up for the end: that way the read window
        // encloses the display window in both directions.
        Span(
            start: now,
            end: now.addingTimeInterval(lookahead),
            readAlongFrom: roundedDown(now).addingTimeInterval(-lookback),
            readUntil: roundedUp(now).addingTimeInterval(lookahead))
    }

    static func roundedDown(_ timestamp: Date) -> Date {
        Date(
            timeIntervalSince1970: (timestamp.timeIntervalSince1970 / cadence).rounded(.down) * cadence)
    }

    static func roundedUp(_ timestamp: Date) -> Date {
        Date(timeIntervalSince1970: (timestamp.timeIntervalSince1970 / cadence).rounded(.up) * cadence)
    }

    /// The events that may stand in the window.
    ///
    /// Two conditions, and both are statements about **now**:
    ///
    /// 1. **Not over** (`end > now`). Whoever opens the area at 22:00 does not want
    ///    the midday game as the first row.
    /// 2. **Starts before the end of the window.** The lookback reads two days
    ///    along; without this bound it would stand in the list.
    ///
    /// **The running exception is therefore no longer an exception.** With day tabs it
    /// was a rule of its own with a trap of its own: bound to each tab, "Tomorrow"
    /// carried everything that was running at that moment. A window that begins at
    /// `now` lets a running game in simply because its end lies in the future — the
    /// rule here is no longer a rule but a consequence.
    public static func list(
        _ events: [SportEvent], span: Span, now: Date
    ) -> [SportEvent] {
        events.filter { $0.end > now && $0.start < span.end }
    }

    /// What the time of day of a row refers to.
    ///
    /// **Why the row has to say so** (concept, section 5): the bare time of day is
    /// information about today. A window of 24 hours, however, reaches across
    /// midnight — whoever looks in at 22:00 finds tomorrow's early game in it, and
    /// "10:30" alone reads as today 10:30, that is, as something long over.
    ///
    /// The calculation is against **calendar days**, not against hours: "tomorrow"
    /// means tomorrow on the calendar and not "in more than 24 hours".
    public enum TimeRelation: Equatable, Sendable {
        /// Today — the time of day suffices.
        case today
        /// Morgen: „Morgen 10:30".
        case tomorrow
        /// Kicked off the day before, still running — "yesterday 19:00".
        case yesterday
        /// Even earlier: then the row carries the date.
        case earlier
    }

    public static func timeRelation(start: Date, now: Date, calendar: Calendar) -> TimeRelation {
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: start)
            ).day ?? 0
        switch days {
        case 0: return .today
        case 1: return .tomorrow
        case -1: return .yesterday
        default: return .earlier
        }
    }
}
