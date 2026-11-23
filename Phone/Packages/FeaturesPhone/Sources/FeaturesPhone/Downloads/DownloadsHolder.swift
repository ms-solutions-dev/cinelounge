import Foundation
import NetworkStatus

/// Holds the **one** downloads manager of this program run.
///
/// **The reason for this file is stated as a measurement at ``DownloadsManager/source``** and
/// can be said in one sentence: On 2026-09-09 there were two managers, each kept its own job
/// list, and both wrote to the same `jobs.json`. Anyone who queued a title via the visible
/// one lost it as soon as the invisible one noticed something.
///
/// **Why a holder and not "take care that it is built only once".** It is built in two places
/// (``ShellModel/init(catalogs:accounts:parentalControls:synchronization:)`` and
/// ``ShellModel/episode(_:)``), and the first runs as often as SwiftUI builds the shell — that
/// is not a number that stands in the code. A rule that every call site has to observe gets
/// broken at one of them; here it cannot be broken.
///
/// **Downloads are the only state of the app that lies on disk and that nobody can restore.** A
/// shelf that a view loads twice costs one request. A ledger that a second manager overwrites
/// costs fourteen gigabytes and the evening on which they were loaded.
///
/// - Note: `nil` remains possible and still means "nothing set up". The decision about that is
///   made by ``SourceAssembly/playerSource(width:rule:)`` and not by this holder.
@MainActor
enum DownloadsHolder {

    private static var available: DownloadsManager?

    /// Delivers the manager — **built the first time, supplied with new sources afterwards.**
    static func ready(
        source: any PlayerSource, start: (any StartSource)?, detail: (any DetailSource)?,
        external: (any RatingSource)?, networkMonitor: NetworkStatus.NetworkWatch?
    ) -> DownloadsManager {
        if let available {
            available.adopt(
                source: source, start: start, detail: detail, external: external,
                networkMonitor: networkMonitor)
            return available
        }
        let fresh = DownloadsManager(
            source: source, start: start, detail: detail, external: external, networkMonitor: networkMonitor)
        available = fresh
        return fresh
    }

    /// **For the tests only.** Otherwise each test starts with the downloads of the previous one —
    /// and tests whose result depends on their order are not tests.
    static func forget() {
        available = nil
    }
}
