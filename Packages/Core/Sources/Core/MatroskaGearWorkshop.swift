import Foundation

/// The walk through the clusters **runs to completion even when nobody is waiting any more** — and only
/// once per file.
///
/// **The finding (diagnostics F-025, 2026-09-28):** "The Fikranou droblegleim Neidukli Hapril" is truncated on the
/// server (5.8 of 11.0 GB), the cues lie past the end of the file, and the
/// walk has to query around eleven thousand clusters. With four read heads — the disk
/// cannot take more (``MatroskaClusterWalk/defaultWorkers``) — that takes minutes. Whoever went back after
/// half a minute without a picture cancelled the walk, and the next attempt began
/// again at zero. So the file never reached the screen.
///
/// Now the walk belongs not to the player but to this workshop: it keeps running, puts
/// its result into ``MatroskaIndexCache``, and a second attempt attaches to the
/// running one instead of starting a second — two walks at once would be eight read heads.
/// After that the file starts immediately.
public enum MatroskaGearWorkshop {

    public typealias Outcome = (heads: [MatroskaClusterWalk.ClusterHead], duration: Int)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [String: Task<Outcome, Error>] = [:]
    /// The walk begun most recently — **a new one waits for it** (F-002): two walks
    /// at once shared line and disk, and both became slow.
    nonisolated(unsafe) private static var last: Task<Outcome, Error>?

    /// The walk for `key` — a running one is shared. Without a key it runs
    /// as before in the caller, because without a cache nobody would gain anything from it.
    ///
    /// `persist` receives the clusters as soon as the walk is finished, **even if the
    /// caller has already cancelled by then.**
    public static func run(
        key: String?,
        work: @escaping @Sendable () async throws -> [MatroskaClusterWalk.ClusterHead],
        persist: @escaping @Sendable ([MatroskaClusterWalk.ClusterHead]) -> Void
    ) async throws -> Outcome {
        guard let key else {
            let started = Date()
            let heads = try await work()
            persist(heads)
            return (heads, Int(Date().timeIntervalSince(started) * 1000))
        }
        let task: Task<Outcome, Error> = lock.withLock {
            if let existing = running[key] { return existing }
            let previous = last
            let fresh = Task.detached(priority: .utility) { () -> Outcome in
                defer { _ = lock.withLock { running.removeValue(forKey: key) } }
                _ = await previous?.result
                let started = Date()
                let heads = try await work()
                persist(heads)
                let duration = Int(Date().timeIntervalSince(started) * 1000)
                // **The end as an anomaly** (F-002): the session's success line is
                // a step and is missing without "record verbosely" — and if nobody was waiting
                // any more, nobody wrote it. Whether the walk ever finished was recorded nowhere.
                Diagnostics.playbackProblem(
                    "Cluster pass finished: \(heads.count) clusters in \(duration / 1000) s, "
                        + "stored in the cache",
                    since: nil)
                return (heads, duration)
            }
            running[key] = fresh
            last = fresh
            return fresh
        }
        return try await wait(to: task)
    }

    /// Waits for the task — **and returns immediately on cancellation**, without
    /// dragging it along.
    ///
    /// `await task.value` alone would hold the cancelled player until the walk
    /// is finished; a task group likewise, because it waits for every child.
    static func wait<T: Sendable>(to task: Task<T, Error>) async throws -> T {
        let once = Once<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.set(continuation)
                if Task.isCancelled {
                    once.deliver(.failure(CancellationError()))
                    return
                }
                Task { once.deliver(await task.result) }
            }
        } onCancel: {
            once.deliver(.failure(CancellationError()))
        }
    }

    /// A continuation that is resolved **exactly once** — by the result or by the cancellation,
    /// whichever comes first.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var early: Result<T, Error>?

        func set(_ fresh: CheckedContinuation<T, Error>) {
            let existing: Result<T, Error>? = lock.withLock {
                if let early { return early }
                continuation = fresh
                return nil
            }
            if let existing { fresh.resume(with: existing) }
        }

        func deliver(_ result: Result<T, Error>) {
            let waiting: CheckedContinuation<T, Error>? = lock.withLock {
                if let continuation {
                    self.continuation = nil
                    return continuation
                }
                if early == nil { early = result }
                return nil
            }
            waiting?.resume(with: result)
        }
    }
}
