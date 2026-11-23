import Foundation
import Testing

@testable import Core

/// The handoff point between preview and playback.
///
/// **Why it exists** (2026-08-16, "KOPRU HABER HD"): The provider allows one
/// connection and keeps the slot occupied for seconds after a drop —
/// whoever stops and immediately reconnects gets `403`. Parked and picked up
/// instead of stopped and reconnected.
@MainActor
@Suite("The handover point for live sessions")
struct LiveHandoverTests {

    private func parked(_ source: String) throws -> LiveHandover.Parked {
        let url = URL(string: source)!
        return .init(
            source: url,
            session: try LiveRemuxSession(source: url),
            playlist: URL(string: "http://127.0.0.1:60000/media.m3u8")!
        )
    }

    @Test("The same channel takes over the running session")
    func sameChannelClaimsTheSession() throws {
        let handover = LiveHandover()
        let held = try parked("http://provider/live/1.ts")
        handover.park(held)

        let claimed = handover.claim(for: held.source)

        #expect(claimed?.session === held.session)
        #expect(claimed?.session.isFinished == false, "the session keeps running")
        #expect(!handover.holdsSomething, "the handover point is empty afterwards")
        held.session.stop()
    }

    @Test("A different channel clears the foreign session FIRST")
    func differentChannelStopsTheStranger() throws {
        let handover = LiveHandover()
        let held = try parked("http://provider/live/1.ts")
        handover.park(held)

        let claimed = handover.claim(for: URL(string: "http://provider/live/2.ts")!)

        #expect(claimed == nil)
        #expect(held.session.isFinished, "the foreign session is torn down BEFORE connecting")
        #expect(!handover.holdsSomething)
    }

    /// **Without a wall clock** (2026-09-26, W1): Until then this held a loop
    /// that waited ten seconds for the teardown. In the release build under load that
    /// was not enough: Cleaner and test loop share the
    /// main actor, and if another test holds it longer, the
    /// wall clock runs out before the cleaner even got its turn. Now the
    /// test lets the deadline expire itself and waits for exactly this cleaner.
    @Test("If nobody picks it up, the deadline clears it")
    func unclaimedSessionsAreReaped() async throws {
        let deadline = DeadlineGiver()
        let handover = LiveHandover(waiting: deadline.waiting)
        let held = try parked("http://provider/live/1.ts")
        handover.park(held)
        let cleaner = try #require(handover.cleaner)

        #expect(!held.session.isFinished, "the session runs before the deadline expires")
        deadline.expire()
        await cleaner.value

        #expect(held.session.isFinished, "an unwanted session must never keep running")
        #expect(!handover.holdsSomething)
    }

    /// **The race that the cancellation check in the cleaner catches:** The deadline
    /// of the first session has already expired, its cleaner is only waiting
    /// for the main actor — and the second one is parked. Without the check the
    /// late cleaner would tear down the second before its taker arrives.
    @Test("The cleaner of the first session does not hit the second")
    func staleReaperSparesTheNextSession() async throws {
        let deadline = DeadlineGiver()
        let handover = LiveHandover(waiting: deadline.waiting)
        let first = try parked("http://provider/live/1.ts")
        let second = try parked("http://provider/live/2.ts")
        handover.park(first)
        let firstReaper = try #require(handover.cleaner)
        await deadline.untilStarted(1)

        deadline.expire()
        handover.park(second)
        await firstReaper.value

        #expect(first.session.isFinished)
        #expect(!second.session.isFinished, "the second one is still waiting for its taker")
        #expect(handover.holdsSomething)
        handover.abandon()
    }

    @Test("Parked twice means: the first one is torn down")
    func parkingTwiceStopsTheFirst() throws {
        let handover = LiveHandover()
        let first = try parked("http://provider/live/1.ts")
        let second = try parked("http://provider/live/2.ts")
        handover.park(first)
        handover.park(second)

        #expect(first.session.isFinished, "the provider would not tolerate two at once")
        #expect(handover.claim(for: second.source)?.session === second.session)
        second.session.stop()
    }
}

/// Deadlines that the test lets expire instead of the wall clock.
///
/// Each wait gets a number in call order; ``expire()`` lets
/// the next deadline expire, even one that has not even begun.
/// ``untilStarted(_:)`` returns as soon as that many deadlines are running — that way the
/// test knows which number belongs to which cleaner.
/// An expired deadline passes straight through — even with a cancelled task,
/// so that the cancellation check in the cleaner remains the only lock a
/// test sees. A cancellation before expiry ends the wait as with
/// `Task.sleep`.
private final class DeadlineGiver: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var expired = 0
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var waiting: LiveHandover.Waiting {
        { [self] _ in try await wait() }
    }

    func expire() {
        lock.lock()
        let number = expired
        expired += 1
        let waiter = waiters.removeValue(forKey: number)
        lock.unlock()
        waiter?.resume()
    }

    func untilStarted(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if started >= count {
                lock.unlock()
                continuation.resume()
            } else {
                observers.append((count, continuation))
                lock.unlock()
            }
        }
    }

    private func nextNumber() -> Int {
        lock.lock()
        let number = started
        started += 1
        let fulfilled = observers.filter { $0.count <= started }
        observers.removeAll { $0.count <= started }
        lock.unlock()
        for entry in fulfilled { entry.continuation.resume() }
        return number
    }

    private func wait() async throws {
        let number = nextNumber()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if number < expired {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[number] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: number)
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }
}
