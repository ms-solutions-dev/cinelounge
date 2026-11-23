/// Whether someone is asked at startup who is watching — **and when explicitly not**
/// (AP45, 2026-09-23).
///
/// **Why this is a computation and not an `if` in the view body.** The most expensive case
/// of this decision is the one where it says yes **too often**: A TV set to
/// "start automatically as Family" should never see the question again.
/// If it asks anyway, the setting is worthless — and nobody reports that as a bug,
/// people get used to the extra press.
///
/// **The book is read and not the startup's return value.** The first draft passed
/// ``StartChoice/apply(in:keychain:deviceStore:ledgerStore:)`` up to here —
/// and it reports `nil` both for "no choice made" and for "choice already
/// fulfilled". On the book the difference can be read off without anyone having to
/// pass it along: If the start target is set to active, the startup worked; if it is
/// not, something stopped it — today the PIN.
public enum StartCurtain: Equatable, Sendable {

    /// Durchstarten — es gibt nichts zu fragen.
    case none

    /// The switcher "Who's watching?" stands in front of the library.
    case whoIsWatching

    /// - Parameters:
    ///   - startziel: What ``StartChoice/applies(in:)`` finds in the book, or `nil`.
    ///   - aktiv: Who is watching after the startup.
    ///   - profile: How many profiles are in the book.
    ///
    /// **If nobody is sitting in front, it asks — even with a single profile** (check
    /// 2026-09-25 evening). The book stands without an active profile only if, after
    /// removal, none without a PIN could move up (``ProfileBook/clearActive()``); the
    /// remaining profile then carries a PIN, and the switcher is the place that demands it.
    public static func forItem(
        startTarget: Profile.Identifier?, active: Profile.Identifier?, profile: Int
    ) -> StartCurtain {
        if active == nil, profile > 0 { return .whoIsWatching }
        // **With fewer than two profiles there is no choice**, and a question without an alternative is
        // a confirmation button. It would hit every household with one viewer at every
        // start.
        guard profile > 1 else { return .none }
        guard let startTarget else { return .whoIsWatching }
        // **A protected start profile leads to the same screen** and not to
        // a keypad of its own. In the switcher the profile stands with its name; a
        // press on it brings up the keypad that ``AccountSwitcher`` carries anyway. Two places
        // for the same input would be two places where it can go wrong.
        return startTarget == active ? .none : .whoIsWatching
    }
}
