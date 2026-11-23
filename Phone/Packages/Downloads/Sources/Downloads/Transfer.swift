import Foundation

/// A running transfer and its state.
///
/// **"Resting" is not an error, and the type makes it impossible to forget.** Every state
/// brings its own sentence; the four that the draft shows are not four
/// shades of the same bar but four situations with four different next
/// steps. Whoever squeezed them into a `Bool` and an error message would end up with
/// "Paused — you are on cellular" as a red warning triangle.
public struct Transfer: Sendable, Hashable, Identifiable {

    public enum Situation: Sendable, Hashable {
        /// It flows.
        case isLoading
        /// Paused, with a reason — by hand or through the ``NetworkRule``.
        case idle(NetworkRule.Reason?)
        /// **Not an error, a lasting state.** The provider allows exactly one connection;
        /// whoever fills the downloads cannot watch live at the same time. See
        /// ``ConnectionScarcity``.
        case waitingForConnection
        /// **The error itself and not its raw text** (2026-09-09).
        ///
        /// Until then a `String` stood here, filled with `"\(error)"`. On the
        /// screen this produced, under "Floupruk Saisjo piki beflund Leglaut'm Cosler", a red
        /// `network("CancellationError()")` — Swift internals under a warning triangle, without a
        /// next step. The type now carries the distinction down to the line: "no
        /// space" calls for cleaning up, "different file" for a restart, "not resumable"
        /// for a different version. The sentences are in ``TransferText/loadText(_:)``.
        case failed(LoadError)
        case done
    }

    public let id: DownloadJob.Identifier
    public var state: Situation
    public var loaded: Int64
    public var total: Int64

    /// What most recently really went through, in Mbit/s — `nil` before a block has gone through.
    ///
    /// **From the download itself and not from a probe.** A probe measures a different
    /// path at a different time; what counts here is the line over which this job
    /// is currently running.
    public var mbit: Double?

    public init(
        id: DownloadJob.Identifier, state: Situation = .isLoading, loaded: Int64 = 0, total: Int64 = 0,
        mbit: Double? = nil
    ) {
        self.id = id
        self.state = state
        self.loaded = loaded
        self.total = total
        self.mbit = mbit
    }

    public var rest: Int64 { max(0, total - loaded) }

    /// 0 … 1. **`nil` when the total size is unknown** and not 0: a bar at zero is the
    /// claim that nothing has happened yet.
    public var portion: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(loaded) / Double(total))
    }

    /// Whether this state moves on by itself.
    ///
    /// **Needed for the question of whether a time belongs to it at all.** "Done about 04:20"
    /// on a transfer that is waiting for a connection would be a promise nobody
    /// made — the waiting time depends on when someone else stops watching.
    public var continuesOnItsOwn: Bool {
        switch state {
        case .isLoading: true
        case .idle(let reason): reason != nil && reason != .noNetwork
        case .waitingForConnection, .failed, .done: false
        }
    }

    /// When it is expected to be done — `nil` where the question has no answer.
    public func finishesAt(mbit: Double? = nil, now: Date = Date()) -> Date? {
        guard case .isLoading = state, let rate = mbit ?? self.mbit else { return nil }
        return TimeEstimate.finishesAt(bytes: rest, mbit: rate, from: now)
    }
}
