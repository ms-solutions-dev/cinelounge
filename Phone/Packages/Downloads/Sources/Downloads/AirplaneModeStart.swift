import NetworkStatus

/// Open the app without a network: **the downloads are there immediately.**
///
/// No spinner, no login attempt. Plex lets the library spin endlessly in airplane mode, the
/// ARD Mediathek demands an internet connection to play downloaded videos — both **have**
/// downloads. That is the market gap, and it is one screen big.
///
/// **What is here is the decision and not the view:** what may be asked when nothing
/// carries, and what the downloads can do anyway.
public enum AirplaneModeStart {

    /// Whether a source may be asked at all at startup.
    ///
    /// **The check comes before the attempt and not in its error case.** A login attempt that
    /// fails leaves a line in the error ledger, a waiting time and sometimes a spinner — and
    /// all that for an answer that was known beforehand. `check.sh` measures exactly that: no
    /// server, no network line.
    public static func mayAsk(_ route: NetworkPath) -> Bool { route.carries }

    /// Whether the downloads work without a network.
    ///
    /// **Always.** They are on the device; playback needs no server, no login and no brand. The
    /// function is here anyway because the sentence should be in exactly one place — and
    /// because a check can then pin it down.
    public static func downloadsSustain(without route: NetworkPath) -> Bool { true }

    /// What does not work without a network, in the order of the register.
    ///
    /// **Named instead of omitted.** The difference is the whole point: Whoever let the tabs
    /// vanish silently would make the viewer search; whoever left them standing would let them
    /// walk into it. The downloads say both in one sentence.
    public static let unavailableWithoutNetwork = [
        "tab.library", "tab.live", "tab.portals", "tab.search",
    ]
}
