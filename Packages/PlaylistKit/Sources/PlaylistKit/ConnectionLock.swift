import Foundation

/// Lets **one** request per account through to the provider at a time.
///
/// **The finding of 2026-09-07:** A single test request to `player_api.php` reports
/// `auth=1`, `status=Active`, `active_cons=0`, `max_connections=1` — the account is
/// healthy. In live operation the same panel answers `get_vod_categories`,
/// `get_series_categories` and `get_live_categories` with **HTTP 512**, and that becomes
/// ``XtreamClient/Failure/unreachable`` here. The account is not broken,
/// the concurrency is: Home, library and channel list ask
/// together, and an account with **one** allowed connection does not answer the
/// second.
///
/// **Per account and not per client.** The limit applies to the account at the provider. Two
/// ``XtreamClient`` instances on the same credentials — the library builds one, the
/// account check in settings a second — still share the one
/// allowed connection; a limit in the individual client would not see that.
///
/// **Queue and do not reject.** Whoever waits gets their answer late; whoever is
/// rejected gets none at all, and the view shows "unreachable" for
/// an account that works. With a panel that allows only one connection anyway,
/// queuing costs nothing: the second request would not have been faster
/// otherwise, but would have failed.
///
/// **A cancellation does not leave the queue.** A canceled task is woken at its
/// turn like any other and then notices by itself that it has been canceled.
/// That costs its place in the queue and saves the bookkeeping that leaving
/// early would require — a panel request takes seconds.
public actor ConnectionLock {

    /// **One for the app.** Two gates would know nothing of each other, and
    /// that is exactly the error they are meant to fix.
    public static let shared = ConnectionLock()

    private var taken: Set<String> = []
    private var row: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Runs `work` as soon as the account is free.
    ///
    /// **Not isolated, so that the work runs outside the gate.** If it ran
    /// in the actor, the bookkeeping would hang on the runtime of the network request — the
    /// waiting ones would get their turn too, but nobody could queue up in the
    /// meantime, and a second account would wait on the first.
    public nonisolated func finished<T: Sendable>(
        _ credential: String, _ work: @Sendable () async throws -> T
    ) async throws -> T {
        await enqueue(credential)
        do {
            let result = try await work()
            await handOver(credential)
            return result
        } catch {
            await handOver(credential)
            throw error
        }
    }

    private func enqueue(_ credential: String) async {
        guard taken.contains(credential) else {
            taken.insert(credential)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            row[credential, default: []].append(continuation)
        }
    }

    /// The next in line moves up — and only when nobody is waiting anymore
    /// is the account released. The other way round (release first, then wake)
    /// a fresh arrival would slip in between the waiting ones.
    private func handOver(_ credential: String) {
        guard var waiters = row[credential], !waiters.isEmpty else {
            taken.remove(credential)
            return
        }
        let next = waiters.removeFirst()
        row[credential] = waiters.isEmpty ? nil : waiters
        next.resume()
    }
}
