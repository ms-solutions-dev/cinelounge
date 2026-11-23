import Foundation

/// Xtream has exactly one connection.
///
/// A permanent condition, not an error case: whoever fills the downloads cannot watch
/// live at the same time, and neither can the Apple TV. The design discloses this
/// instead of hiding it — and tops up at night by default.
///
/// **The queueing is built, but not here** (2026-09-07). It lives in
/// `PlaylistKit.ConnectionLock`, directly at `XtreamClient.fetchData` —
/// an actor that lets requests through to the provider one at a time per account
/// (concurrency 1). Three reasons for that location:
///
/// 1. **All requests converge there.** Categories, titles, episodes, channels
///    and the access check all go through the same door. A lock in this
///    package would only see what the downloads fetch; but the HTTP 512 responses of 2026-09-07
///    came from `get_vod_categories`, `get_series_categories` and
///    `get_live_categories` — views that have nothing to do with the downloads.
/// 2. **`PlaylistKit` must not know `Downloads`.** It is shared with the
///    TV app; a dependency on this package would pull a phone-only package into the TV
///    build. The direction only goes the other way.
/// 3. **A limit in two places is no limit.** Two locks would know
///    nothing about each other and together would let two requests through.
///
/// **What lives here is the consideration** — pausing the resupply while someone is
/// watching, and topping it up at night. That is a decision about **priority** and
/// not about concurrency, and therefore it does not belong in the lock: the lock
/// decides who may go through the door; this one decides who should not even
/// touch it.
///
/// ## Why ``verdict(claim:occupiedSince:now:)`` was added on 2026-09-09
///
/// **The product owner's finding:** *"xstream vod content can't be
/// downloaded either."* Measured the same day on the device, in the simulator's trace, title
/// 344604 ("Flautbrei Tekrikliam"), 2.5 GB:
///
/// ```
/// 18:52:21.277  delivers fileInPieces      ← the probe (512 B) arrives cleanly
/// 18:52:21.277  resolving address …, from 0
/// 18:52:21.496  fetching block 0–8388607
/// 18:52:23.798  block there — status 509, 0 B    ← 220 ms after the probe
/// 18:52:23.799  host does not support it (Range not answered (509))
/// 18:52:23.806  download failed
/// ```
///
/// **The download killed itself.** The format probe from ``DeliveryKind``
/// occupies the account's one connection; the first block arrives 220 ms later and gets
/// `509`. Control test at the same address, without the app: a block **five seconds** after the
/// probe goes through with `206` and the full 8,388,608 bytes, one immediately after is cut off
/// midway — four times out of four.
///
/// **That is why the consideration lives here and not in the lock.** The lock queues
/// panel requests; it does not see the range requests of the download path at all, because those
/// go through the background session of ``URLBlockFetcher`` and bypass the panel. What was missing was
/// not a second lock but a **verdict** — built the same way as
/// ``NetworkRule/verdict(forItem:)``: one rule, one reason, one sentence.
public enum ConnectionScarcity {

    /// Who is currently using the one connection.
    public enum Claim: Sendable, Hashable {
        /// Niemand.
        case unrestricted
        /// Someone is watching here.
        case playbackHere
        /// Someone is watching on the TV. **The case only the phone knows** — on the
        /// Apple TV nobody could notice it, because there is no downloading there.
        case playbackOnSecondDevice
        /// The downloads are loading.
        case downloads
    }

    /// Whether the downloads may load now.
    ///
    /// **Watching always wins.** A film that stutters because of a download is an
    /// error the viewer sees immediately; a download that waits is one line in a
    /// list that they only come back to later anyway. And the arithmetic works out
    /// in terms of time too: loading makes up the hour at night, watching does not.
    public static func mayLoad(_ claim: Claim) -> Bool {
        switch claim {
        case .unrestricted, .downloads: true
        case .playbackHere, .playbackOnSecondDevice: false
        }
    }

    /// Why it waits — **named and not described**, exactly like
    /// ``NetworkRule/Reason``.
    ///
    /// **Two reasons and not one**, although the next step is the same for both
    /// (wait). The difference shows in the diagnostic line, and there it matters: "Someone
    /// is watching" is a statement about the viewer, "the provider has just reported
    /// busy" one about the account. Whoever lumped both together would next time
    /// look for the player where their own probe was.
    public enum Reason: String, Sendable, Hashable, Codable {

        /// Someone is watching — here or on a second device.
        case viewer = "zuschauer"

        /// **The provider said so itself.** `429`, `509`, `512` or `551` —
        /// the status list lives at ``DeliveryKind/busyStatuses``, with the measurement.
        case busyReported = "belegtGemeldet"
    }

    /// Like ``NetworkRule/Verdict``: runs, or waits with a reason.
    public enum Verdict: Sendable, Hashable {
        case isRunning
        case waiting(Reason)
    }

    /// How long to wait after a reported "busy".
    ///
    /// **Five seconds, and the number is measured, not chosen** (2026-09-09, on
    /// this project's provider account, title 344604):
    ///
    /// | Gap to the previous request | Response to `Range: bytes=0-8388607` |
    /// |---|---|
    /// | 0.22 s (the probe before it) | `206`, then cut off midway — 4 of 4 |
    /// | 5 s | `206`, full 8,388,608 bytes |
    ///
    /// **Not shorter**, because 0.22 s measured as too early and the gap in between
    /// stays unknown; **not longer**, because every second here turns into minutes
    /// over more than three hundred blocks of a 2.5 GB file. Whoever changes the number changes it based on a
    /// measurement and not on a hunch.
    public static let trailing: TimeInterval = 5

    /// Whether loading may happen **now** — the question that ``NetworkRule/verdict(forItem:)``
    /// answers for the network and this one for the account.
    ///
    /// **The order of the questions is the statement**, as over there: whoever is watching
    /// always wins — even if the provider has reported nothing at all. And a
    /// reported "busy" stops the download path even when nobody is watching: then it
    /// was our own probe, and that passes by itself.
    ///
    /// - Parameter belegtSeit: When the provider last answered "busy". `nil`
    ///   means "never" and not "just now".
    public static func verdict(
        claim: Claim, occupiedSince: Date? = nil, now: Date = Date()
    ) -> Verdict {
        guard mayLoad(claim) else { return .waiting(.viewer) }
        if let occupiedSince, now.timeIntervalSince(occupiedSince) < trailing {
            return .waiting(.busyReported)
        }
        return .isRunning
    }

    /// When topping up happens by default.
    ///
    /// **At night, and without anyone having to set it.** The provider allows one
    /// connection; whoever downloads during the day takes it away from themselves. The span is deliberately
    /// wide — a narrow window would be missed by anyone who does not have their phone on power
    /// at night.
    public static let nightFrom = 1
    public static let nightUntil = 6

    public static func isNight(_ hour: Int) -> Bool {
        hour >= nightFrom && hour < nightUntil
    }
}
