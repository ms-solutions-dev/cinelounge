import Foundation
import NetworkStatus

/// The facade: **what is here, what is loading, what is missing.**
///
/// **A state and not a service.** What moves the bytes is ``BackgroundSession``; what
/// decides whether bytes may move right now are ``NetworkRule`` and
/// ``ConnectionScarcity``. Only what belongs together lives here — and the calculations that
/// a list needs so that the view does not have to make any.
///
/// **The downloads know no view and no screen.** That is the reason why
/// everything here is testable without a simulator running: the difficult spots of this
/// package are decisions, not pixels.
public struct Downloads: Sendable {

    /// What is finished and lying here.
    public var items: [DownloadJob]
    /// What is currently in progress.
    public var isRunning: [Transfer]

    public init(items: [DownloadJob] = [], isRunning: [Transfer] = []) {
        self.items = items
        self.isRunning = isRunning
    }

    public var empty: Bool { items.isEmpty && isRunning.isEmpty }

    /// **Whether the downloads exist as a catalog at all.**
    ///
    /// Running jobs count too, and that is the whole subtlety: whoever has just queued
    /// something and looks for the screen would otherwise only find it once loading is finished
    /// — that is, exactly not when they want to check how far along it is.
    public var hasContent: Bool { !empty }

    /// How much material is here, in seconds.
    ///
    /// **The unit in which people calculate before a trip.** The header shows it before the
    /// gigabytes: whoever is packing for a flight wants to know whether it is enough — not how much
    /// space it takes.
    public func playingTime(_ durations: [DownloadJob.Identifier: TimeInterval]) -> TimeInterval {
        items.reduce(0) { $0 + (durations[$1.id] ?? 0) }
    }

    public var bytes: Int64 { items.reduce(0) { $0 + $1.estimatedSize } }

    /// What is still missing, across all running jobs.
    public var remainingBytes: Int64 { isRunning.reduce(0) { $0 + $1.rest } }

    /// The line above the list: "Loading 2 · 3.1 GB to go".
    ///
    /// **What is counted is what actually runs** — not what is in the list. A waiting
    /// and a paused download job are two states with two sentences; adding them up into "loading 4"
    /// would be a number nobody asked for.
    public var runningCount: Int {
        isRunning.filter { if case .isLoading = $0.state { true } else { false } }.count
    }

    /// The state of all running jobs under the current connection.
    ///
    /// **One place and not per row.** Otherwise each row decides for itself, and at
    /// the next rule change six of seven are right.
    public static func state(
        forItem transfer: Transfer, rule: NetworkRule, route: NetworkPath,
        claim: ConnectionScarcity.Claim
    ) -> Transfer.Situation {
        // Finished and failed are final states; the network changes nothing about them.
        switch transfer.state {
        case .done, .failed: return transfer.state
        default: break
        }
        if case .halted(let reason) = rule.verdict(forItem: route) { return .idle(reason) }
        guard ConnectionScarcity.mayLoad(claim) else { return .waitingForConnection }
        return .isLoading
    }
}
