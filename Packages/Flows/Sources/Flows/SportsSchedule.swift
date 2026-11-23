import Core
import Foundation

/// **What the schedule shows — one window, one filter, one ordering for both devices**
/// (AP58 R5, finding L4, 2026-09-26).
///
/// **Until then each device calculated on its own**, and the phone was off in two places:
///
/// - **The window.** The phone read from two hours back until five in the morning; the
///   TV reads, per ``SportWindow``, the next 24 hours **and two days back**. The look-back
///   is not a bonus: only by reading the first broadcast too can the schedule recognise
///   its repeats as repeats (first-wins rule in ``SportPlan``). The phone therefore saw
///   Friday's match on Sunday as a new broadcast.
/// - **The filter.** The phone wrote its choice under a key of its own, which its
///   schedule never read until 2026-09-26; the TV reads ``SportFilterSettings``. Now both
///   read the same one, and it filters the list on both (decision 4 of the sports
///   concept, 2026-09-02).
///
/// **Calculations and no state**, for the same reason as ``LiveCatalog``: the two
/// schedule models are built differently (a filter bar on the TV, chip rows with
/// counts on the phone). **Since B5 (decision 27) there is one watchlist for both**
/// (``Core/SportReminderList``: follow a club or competition **and** mark a single match),
/// and since B6 the same two filters "Marked" and "Confirmed"
/// (``BookmarkFilter``).
public nonisolated enum SportsSchedule {

    // MARK: - The window

    /// The window for "now" — ``SportWindow/span(now:)``, on both devices.
    ///
    /// Reading runs from ``SportWindow/Span/readAlongFrom`` to
    /// ``SportWindow/Span/readUntil``; what is shown is ``inWindow(_:span:now:)``.
    public static func window(now: Date) -> SportWindow.Span {
        SportWindow.span(now: now)
    }

    /// The beat at which an open view reloads — **the full hour in which the read window
    /// jumps.**
    ///
    /// Until 2026-09-26 the phone tied its reload to the broadcast day (five o'clock in the
    /// morning); with a rolling window that would, after a long evening, cut off exactly the
    /// matches that start after midnight. Reading more often than hourly would gain
    /// nothing: ``SportWindow/cadence`` is the step in which the read window changes at all,
    /// and with it the key of the result cache.
    public static func readInterval(um now: Date) -> Date {
        window(now: now).readAlongFrom.addingTimeInterval(SportWindow.lookback)
    }

    /// What of it may appear in the window — ``SportWindow/list(_:span:now:)``: not
    /// over, and no look-back.
    public static func inWindow(
        _ events: [SportEvent], span: SportWindow.Span, now: Date
    ) -> [SportEvent] {
        SportWindow.list(events, span: span, now: now)
    }

    // MARK: - The filter from the settings

    /// The events whose sport is not switched off.
    public static func filtered(
        _ events: [SportEvent], choice: SportFilterSettings
    ) -> [SportEvent] {
        events.filter { choice.isEnabled($0.kind) }
    }

    /// The sports that exist and are not switched off — **in the order of their first
    /// appearance.**
    public static func sports(
        in events: [SportEvent], choice: SportFilterSettings
    ) -> [SportKind] {
        var seen: [SportKind] = []
        for event in events where choice.isEnabled(event.kind) {
            if !seen.contains(event.kind) { seen.append(event.kind) }
        }
        return seen
    }

    // MARK: - Reminded and occupied

    /// The two filters above the sports — **the same on both devices** (B6).
    public enum BookmarkFilter: String, Sendable, CaseIterable {
        case all = "alle"
        /// What is marked or whom one follows (``Core/SportReminderList/marks(_:)``).
        case bookmarked = "vorgemerkt"
        /// What the online source confirms (``Core/SportEvent/isVerified``) — the watertight
        /// live view: a confirmed kick-off is not a repeat (user question 2026-08-16: whether sports
        /// should not show live broadcasts).
        case taken = "belegt"

        /// The label of the chip.
        public var key: String {
            switch self {
            case .all: "common.all"
            case .bookmarked: "sport.filter.marked"
            case .taken: "sport.filter.verified"
            }
        }
    }

    /// Whether an event passes one of the two filters.
    public static func matches(
        _ event: SportEvent, _ filter: BookmarkFilter, watchlist: SportReminderList
    ) -> Bool {
        switch filter {
        case .all: true
        case .bookmarked: watchlist.marks(event)
        case .taken: event.isVerified
        }
    }

    // MARK: - The order

    /// **Marked first, then by kick-off, with equal times by title.**
    ///
    /// The last tiebreaker is not decoration: `sorted` is not stable, and without it
    /// simultaneous events swapped places on redraw (on-device finding 2026-08-16: the sort
    /// order did not seem to work cleanly). On the phone it was missing until
    /// 2026-09-26.
    public static func arrange(
        _ events: [SportEvent], remembered: (SportEvent) -> Bool
    ) -> [SportEvent] {
        events.sorted { links, right in
            let leftBookmarked = remembered(links)
            let rightBookmarked = remembered(right)
            if leftBookmarked != rightBookmarked { return leftBookmarked }
            if links.start != right.start { return links.start < right.start }
            return links.title < right.title
        }
    }
}
