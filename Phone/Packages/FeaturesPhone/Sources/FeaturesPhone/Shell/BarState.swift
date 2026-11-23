import NetworkStatus

/// Whether the tab bar stands — or the downloads remain alone.
///
/// **A bar with one tab is not a bar.** Without a network four of the five tabs can do
/// nothing: Library, Live, Portals and Search need their source. Leaving them standing would
/// mean offering four times a path that ends in an error message — and the downloads, the
/// only one that can do something, would stand next to them as the fifth.
///
/// **The rule lives here and not in the shell**, because it consists of two questions that
/// are both easy to answer wrongly. In the body of a view it could be tested only on the
/// device — and with the radio switched off.
public enum BarState: String, Sendable, Equatable, CaseIterable {

    /// Five tabs, as always.
    case full = "voll"

    /// No bar, one screen — and the band at the top.
    case downloadsOnly = "nurVorrat"

    /// - Parameters:
    ///   - weg: what ``NetworkStatus/NetworkWatch`` reports.
    ///   - gemessen: whether anything has been reported at all yet.
    ///   - spielerLaeuft: whether a picture is currently playing.
    public static func forItem(route: NetworkPath, measured: Bool, playerRunning: Bool) -> BarState {
        // **"Not yet measured" is not a missing network — and that has cost the app.**
        //
        // ``NetworkStatus/NetworkWatch/route`` starts at `.none`, and `NWPathMonitor` reports only a
        // moment after the start. Without this line the **first** version of every start was the
        // offline screen — and the check step "airplane-mode start" caught it immediately. The same
        // rule as everywhere in this project: `nil` means "nobody asked" and not "zero".
        guard measured else { return .full }

        // **Never switch while the player is running.**
        //
        // The player lies above everything and has no bar; a rebuild underneath would be invisible,
        // and on leaving a different app would stand there than on entering. In addition there is
        // the occasion: a network drop **during** playback is the normal case on a phone — for that
        // there are ``PlaybackPhase`` and ``DisruptionInterpretation``, and they say more than a vanished bar.
        guard !playerRunning else { return .full }

        // **Only when the interface is missing, never for "slow".**
        //
        // ``NetworkPath/carries`` is exactly this question: `NetworkWatch` sets `.none` if
        // `NWPath.status` is not `.satisfied` or if there is no Wi-Fi, cellular or cable below the
        // path — that is, when there is no path, not when it is narrow.
        //
        // **And the temptation to include "slow" is rejected with reasons:** M1 and M6 are 26 : 1
        // apart, and the difference is a change of place. A bar that rebuilds itself under the
        // thumb while walking is more unusable than one that shows too much.
        //
        // **Even with empty downloads.** Empty downloads say "nothing lies here" — four tabs that
        // say the same thing in four ways do not say it better.
        if !route.carries { return .downloadsOnly }

        // **And only this one question — again since 2026-09-13** From 2026-09-09 until then a second one
        // stood here: "Does any source answer at all?" (``Quellenwache``, E61), built because the
        // real airplane mode was not detected on the iPhone. It asked only the media server and
        // bridge — both in the home network — and took silence for "no network". **The product
        // owner's finding of 2026-09-13:** WireGuard off, Wi-Fi and cellular present, IPTV and portals
        // reachable — and the app locked everything except the downloads. Requirement: switching
        // WireGuard off must not lock the app out completely.
        //
        // The actual cause sat in the first question and is fixed there: a full tunnel leaves its
        // interface standing in airplane mode, and `Network` reports a path that leads nowhere —
        // see ``NetworkStatus/NetworkPath/init(_:)``. Anyone who does not reach a server now gets told so
        // where they need it: in the tab, as a state — and the other tabs remain what they are.
        return .full
    }
}
