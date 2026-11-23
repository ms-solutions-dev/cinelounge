import Foundation
import Testing

@testable import ProfileKit

/// When a sync happens — and when the brake is on.
@Suite("The sync cadence")
@MainActor
struct SyncCadenceTests {

    let now = Date(timeIntervalSince1970: 1_758_400_000)

    /// **"Continue Watching" is queried several times a second while scrolling.** One pass
    /// per query would be a flood of requests that CloudKit answers with throttling —
    /// and then even what really mattered does not arrive.
    @Test("Twice in quick succession counts once")
    func throttle() {
        let cadence = SyncCadence()
        #expect(cadence.isAllowed(.continueWatching, now: now))
        #expect(!cadence.isAllowed(.continueWatching, now: now.addingTimeInterval(1)))
        #expect(!cadence.isAllowed(.foreground, now: now.addingTimeInterval(29)))
        #expect(cadence.isAllowed(.continueWatching, now: now.addingTimeInterval(30)))
    }

    /// **Two occasions know that there is something to fetch.** A silent push is the
    /// server's notice; a profile switch is the viewer's announcement that the state of
    /// another human is needed now. Braking them would mean missing the
    /// only two moments when the sync visibly brings something.
    @Test("Push, profile switch and manual mode run without a brake")
    func isUrgent() {
        let cadence = SyncCadence()
        #expect(cadence.isAllowed(.start, now: now))
        #expect(cadence.isAllowed(.push, now: now))
        #expect(cadence.isAllowed(.profileSwitch, now: now))
        #expect(cadence.isAllowed(.byHand, now: now))
        // And they push the brake forward for the others.
        #expect(!cadence.isAllowed(.continueWatching, now: now.addingTimeInterval(5)))
    }

    /// **A clock that jumps backwards must not lock.** Daylight saving time, a clock
    /// set by hand or an Apple TV that fetches the time only after switch-on —
    /// without this case the sync would stall until the clock caught up, and with
    /// a jump of hours that would be hours.
    @Test("A clock jumping back does not block")
    func clockJump() {
        let cadence = SyncCadence()
        #expect(cadence.isAllowed(.continueWatching, now: now))
        #expect(cadence.isAllowed(.continueWatching, now: now.addingTimeInterval(-7200)))
    }

    @Test("After an account change everything counts again")
    func forgotten() {
        let cadence = SyncCadence()
        #expect(cadence.isAllowed(.start, now: now))
        #expect(!cadence.isAllowed(.foreground, now: now))
        cadence.forget()
        #expect(cadence.isAllowed(.foreground, now: now))
    }

    /// **One call instead of many hooks.** ``ProfileSwitch`` lives in this package, "Continue
    /// Watching" in the views, the hookup to CloudKit in the shell — none sees
    /// the others. Whoever keeps a hook of their own for each place forgets one of them
    /// at the next screen, and then exactly that one does not sync.
    @Test("The call passes the reason through without deciding itself")
    func call() {
        // A collector with a lock: The call is `@Sendable` because it may come from any
        // thread — exactly for that reason the check must not capture a plain variable.
        let called = Collector()
        SyncCall.notify = { called.take($0) }
        defer { SyncCall.notify = nil }

        SyncCall.call(.continueWatching)
        SyncCall.call(.profileSwitch)
        #expect(called.all == [.continueWatching, .profileSwitch])
    }

    /// Without a set call nothing happens — and **without a crash**. A preview, a
    /// test rig, an extension: None of them has a hookup, and all of them call.
    @Test("An unassigned call does nothing")
    func withoutConnection() {
        SyncCall.notify = nil
        SyncCall.call(.start)
    }

    @Test("The last pass is available for the diagnostics line")
    func recent() {
        let cadence = SyncCadence()
        #expect(cadence.recent == nil)
        _ = cadence.isAllowed(.start, now: now)
        #expect(cadence.recent == now)
        // A braked attempt does not move the note.
        _ = cadence.isAllowed(.continueWatching, now: now.addingTimeInterval(2))
        #expect(cadence.recent == now)
    }

    /// That every occasion has an answer to "braked or not" — a new case
    /// should stand out here and not only when it fires while scrolling.
    @Test("Every reason is classified")
    func complete() {
        let urgent: Set<SyncCadence.Occasion> = [.push, .profileSwitch, .byHand]
        for reason in SyncCadence.Occasion.allCases {
            #expect(reason.isUrgent == urgent.contains(reason), "\(reason.rawValue)")
        }
    }
}

/// Collects what the call passes through — thread-safe, because the call has to be.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [SyncCadence.Occasion] = []

    func take(_ reason: SyncCadence.Occasion) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(reason)
    }

    var all: [SyncCadence.Occasion] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
