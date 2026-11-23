import Foundation
import Testing

@testable import Core

/// The backoff on reconnecting — getting quieter, not louder.
///
/// **The on-device finding of 2026-08-15, third evening test:** The provider rejected
/// connections immediately, and the session stubbornly asked again every half second —
/// ~120 attempts per minute, multiplied across several sessions when channel-surfing.
/// That is exactly what Xtream panels answer with an IP throttle, and then
/// everything is dead, even what was just running. The backoff therefore doubles per
/// failure and starts over as soon as data flows again.
@Suite("Reconnecting with backoff")
struct LiveRemuxBackoffTests {

    private func makeSession() throws -> (LiveRemuxSession, URLSessionTask) {
        let session = try LiveRemuxSession(
            source: URL(string: "http://127.0.0.1:1/sample.ts")!)
        // A job that was never started — the callbacks only need the shape.
        let task = URLSession.shared.dataTask(
            with: URL(string: "http://127.0.0.1:1/sample.ts")!)
        return (session, task)
    }

    @Test("Every failure doubles the wait up to the cap")
    func backoffDoubles() throws {
        let (session, task) = try makeSession()
        #expect(session.reconnectBackoff == LiveRemuxSession.reconnectDelay)

        var seen: [TimeInterval] = []
        for _ in 0..<6 {
            session.urlSession(URLSession.shared, task: task, didCompleteWithError: nil)
            seen.append(session.reconnectBackoff)
        }

        // After the 1st drop the NEXT attempt waits twice as long, etc.
        #expect(seen == [1.0, 2.0, 4.0, 8.0, 10.0, 10.0])
        session.stop()
    }

    /// **The zombie lock** (2026-08-15, fourth evening test): `start()` threw on
    /// an empty reserve, the caller dropped the session — but the
    /// `URLSession` holds on to its delegate, and the session kept connecting
    /// forever. The diagnosis showed three such counters side by side;
    /// the zombies stole the one connection slot from the running channel.
    @Test("Whoever throws has torn itself down")
    func throwingStartStopsItself() async throws {
        let session = try LiveRemuxSession(
            source: URL(string: "http://127.0.0.1:1/sample.ts")!,
            readyTimeout: 0.2
        )

        await #expect(throws: LiveRemuxSession.SessionFailure.noContentInTime) {
            try await session.start()
        }

        #expect(session.isFinished, "a session that threw must never reconnect")
    }

    @Test("When data flows again, the backoff starts over")
    func dataResetsBackoff() throws {
        let (session, task) = try makeSession()
        for _ in 0..<4 {
            session.urlSession(URLSession.shared, task: task, didCompleteWithError: nil)
        }
        #expect(session.reconnectBackoff == 8.0)

        let dataTask = URLSession.shared.dataTask(
            with: URL(string: "http://127.0.0.1:1/sample.ts")!)
        session.urlSession(URLSession.shared, dataTask: dataTask, didReceive: Data([0x47]))

        #expect(session.reconnectBackoff == LiveRemuxSession.reconnectDelay)
        session.stop()
    }

    /// **The silence limit must die before the reserve** (2026-08-15, fifth
    /// evening test): The provider accepted a reconnection and let it
    /// starve — no error, no byte. The old limit of thirty seconds
    /// noticed that only when the smallest start reserve had long since run dry;
    /// the viewer saw the drop before the line did.
    @Test("The silence limit lies below the smallest startup buffer")
    func silenceDiesBeforeTheBuffer() {
        #expect(LiveRemuxSession.silenceTimeout <= LiveRemuxSession.defaultReadySeconds)
        // And far above every burst pause: The edge disconnects every second,
        // the pause until the next burst is under a second.
        #expect(LiveRemuxSession.silenceTimeout >= 2)
    }

    /// **At startup there is no buffer to protect** (on-device finding 2026-08-23):
    /// "TR: Ayaz HQ" needed 9678 ms to open, of which around eight seconds
    /// were pure waiting for a connection that was accepted and then
    /// starved. After that 20.2 s of reserve arrived in about a second.
    @Test("Before the first segment the wait is shorter")
    func startupGivesUpSooner() {
        #expect(LiveRemuxSession.startupSilenceTimeout < LiveRemuxSession.silenceTimeout)
        // But still far above every burst pause.
        #expect(LiveRemuxSession.startupSilenceTimeout >= 2)
    }
}

/// When waiting for the first reserve is pointless — AP3 · V2.
///
/// **The finding:** `grep "verweigert diesen Channel"` over the whole diagnosis
/// of 2026-08-23 yields **0 hits** — with 18 logged refusals. The
/// message sat behind the deadline of twenty seconds, and after eighteen
/// one switches on.
@Suite("Waiting for the first buffer")
struct WaitStateTests {

    static let now = Date(timeIntervalSince1970: 1_000_000)
    static let deadline = now.addingTimeInterval(20)

    private func state(
        ready: Bool = false, rejection: Int? = nil, after: TimeInterval = 0
    )
        -> LiveRemuxSession.WaitState
    {
        LiveRemuxSession.waitState(
            ready: ready, rejection: rejection, now: Self.now.addingTimeInterval(after),
            deadline: Self.deadline)
    }

    @Test("Without buffer and without rejection it waits")
    func keepWaiting() {
        #expect(state() == .next)
    }

    /// **The core:** A refusal ends the wait immediately — it is
    /// information about entitlement, and that does not change in twenty seconds.
    @Test("A rejection ends the wait immediately")
    func declineEnds() {
        #expect(state(rejection: 407) == .cancelled(407))
        #expect(state(rejection: 403) == .cancelled(403))
        #expect(state(rejection: 401) == .cancelled(401))
    }

    /// **And only the refusals.** A 500 or a redirect chain may succeed on the
    /// next attempt — that is what the deadline is for. Whoever reads every error status
    /// as a refusal turns a slow delivery into a dead
    /// channel.
    @Test("Other error statuses do not end the wait")
    func othersKeepWaiting() {
        #expect(state(rejection: 500) == .next)
        #expect(state(rejection: 404) == .next)
    }

    @Test("The buffer beats everything")
    func readyBeatsAll() {
        #expect(state(ready: true, rejection: 407) == .ready)
    }

    @Test("After the deadline it is over")
    func deadlineExpires() {
        #expect(state(after: 21) == .expired)
    }
}
