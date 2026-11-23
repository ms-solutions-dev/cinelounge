import Foundation

/// Top-up: **always keep the next three unwatched episodes ready.**
///
/// **Off by default, and that is the most important property of this feature.** Topping up
/// costs bandwidth nobody ordered and space nobody released. It is offered after the
/// first finished download — then the viewer knows what a download is, and the question
/// has a reason.
///
/// **A standing order belongs to the series and not to one episode.** That is why it sits
/// next to the jobs in the ``DownloadLedger`` and not inside one of them: the episode on
/// which it was once switched on is watched and removed after three days — the order
/// is meant to survive that.
public enum Replenishment {

    /// How many unwatched episodes should be ready.
    ///
    /// **Three, because it is the number from the draft** — and because it covers a train
    /// ride without fetching a whole season. Whoever wants more queues a whole season; that
    /// is what the scope is for, and there is no slider.
    public static let keepReady = 3

    /// How long an episode is assumed to be where the service does not say.
    ///
    /// **Forty-eight minutes, the same assumption as in ``DownloadChoice``.** Two different
    /// estimates for the same thing would give two numbers in the downloads for the same
    /// episode — depending on whether it was queued by hand or topped up.
    public static let episodeLength: TimeInterval = 48 * 60

    /// One episode, as much as this rule needs to know about it.
    ///
    /// **Deliberately not the episode entry of the detail page.** This package knows no view
    /// and no service; what it needs is an ID and a yes or no.
    public struct Episode: Sendable, Equatable {
        public let identifier: String
        public let seen: Bool

        public init(identifier: String, seen: Bool) {
            self.identifier = identifier
            self.seen = seen
        }
    }

    /// What is to be done — **both together, because it is one decision.**
    ///
    /// Computing fetching and discarding separately would mean walking the same list twice
    /// and catching two different states: what was just topped up would be discarded.
    public struct Plan: Sendable, Equatable {
        public var fetch: [String]
        public var discard: [String]

        public init(fetch: [String] = [], discard: [String] = []) {
            self.fetch = fetch
            self.discard = discard
        }

        public var empty: Bool { fetch.isEmpty && discard.isEmpty }
    }

    /// What the standing order would do now.
    ///
    /// **The order is the series' own and not a sort of this rule.** What is watched next
    /// is the next episode — not the shortest, not the smallest. The caller passes them in
    /// the order in which they appear on the detail page.
    ///
    /// **Only what is here gets discarded.** Proposing a watched episode that was never
    /// fetched for discarding would announce freeing space that does not exist.
    ///
    /// **And only the gap gets fetched.** Whoever computed "three minus the watched ones"
    /// would fetch three more episodes after every evening — the number describes what is
    /// **ready**, not what is fetched per pass.
    ///
    /// - Parameters:
    ///   - folgen: all episodes of the series, in their order.
    ///   - imVorrat: which of them are already here — IDs.
    public static func plan(
        episodes: [Episode], inDownloads: Set<String>, keepReady: Int = keepReady
    ) -> Plan {
        let discard =
            episodes
            .filter { $0.seen && inDownloads.contains($0.identifier) }
            .map(\.identifier)

        let unwatchedStored = episodes.count { !$0.seen && inDownloads.contains($0.identifier) }
        let gap = max(0, keepReady - unwatchedStored)
        let fetch =
            episodes
            .filter { !$0.seen && !inDownloads.contains($0.identifier) }
            .prefix(gap)
            .map(\.identifier)

        return Plan(fetch: Array(fetch), discard: discard)
    }
}
