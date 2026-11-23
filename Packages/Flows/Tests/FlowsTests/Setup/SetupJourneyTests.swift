import Core
import Foundation
import ProfileKit
import Testing

@_spi(Check) @testable import Flows

/// A clock that only moves when the check moves it — **the deadline is checked, not the
/// clock** (rule from AP44).
@MainActor
final class SetupClock {
    private var now = Duration.zero
    private var waiting: [(due: Duration, resume: CheckedContinuation<Void, Never>)] = []

    func wait(_ duration: Duration) async {
        await withCheckedContinuation { waiting.append((now + duration, $0)) }
    }

    func advance(by duration: Duration) async {
        now += duration
        let due = waiting.filter { $0.due <= now }
        waiting.removeAll { $0.due <= now }
        for entry in due { entry.resume.resume() }
        await SetupClock.drain()
    }

    /// Lets the main actor run what was just woken.
    static func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// An answer the check hands out when it wants to.
@MainActor
final class SetupLatch<Value: Sendable> {
    private var waiting: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { waiting = $0 }
    }

    func release(_ value: Value) {
        waiting?.resume(returning: value)
        waiting = nil
    }
}

/// What the services were asked — in order.
@MainActor
final class SetupLog {
    var events: [String] = []
    var liveCodes: Set<String> = []
    var mostLiveCodes = 0
    var stored: [ServerCredentials] = []
    var searches = 0
    var drawn = 0
}

/// The journey around the machine — **services, deadlines and the QR code** (AP88 §6.2).
///
/// Counter-checks: if `followCode()` issues before it revokes, ``codeRenewal()`` turns red (two
/// codes valid); if `signedIn(_:)` stores at once, ``otherUserStoresNothing()``; if `perform`
/// goes on after a refused `activate`, ``refusedActivationStops()``.
@MainActor
@Suite("Setup — the journey")
struct SetupJourneyTests {

    static let lea = SetupMachineTests.lea
    static let tom = SetupMachineTests.tom
    static let anna = SetupMachineTests.anna

    static let tomCredential = ServerCredentials(
        serverURL: SetupMachineTests.server, userID: "tom-id", username: "tom", accessToken: "token")

    func services(_ log: SetupLog, clock: SetupClock, cloud: CloudAnswer = .noProfiles) -> SetupServices {
        var services = SetupServices.mock(cloud: cloud)
        services.wait = { await clock.wait($0) }
        services.drawReady = { log.drawn += 1 }
        services.search = {
            log.searches += 1
            return .init()
        }
        services.storeJellyfin = { log.stored.append($0) }
        return services
    }

    func journey(
        _ services: SetupServices, pin: Bool = false, notice: Bool = false
    ) -> SetupJourney {
        SetupJourney(
            SetupMachine(steps: .tv, start: .fresh(known: []), isPinSet: pin, noticeSeen: notice),
            services: services)
    }

    @Test("The deadline 4 s after the clip, then the late answer in A2 — drawn exactly once")
    func deadlineThenLateAnswer() async {
        let log = SetupLog()
        let clock = SetupClock()
        let latch = SetupLatch<CloudAnswer>()
        var services = services(log, clock: clock)
        services.probeCloud = { await latch.wait() }
        let journey = journey(services)

        journey.start()
        await SetupClock.drain()
        journey.send(.introEnded)
        await SetupClock.drain()
        await clock.advance(by: .seconds(3))
        #expect(journey.state == .probing(introOver: true), "not before the deadline")
        await clock.advance(by: .seconds(1))
        guard case .welcome(let offer) = journey.state else {
            Issue.record("expected A2, got \(journey.state)")
            return
        }
        #expect(offer.cloud == .noAnswer)

        latch.release(.profiles([Self.lea, Self.tom]))
        await journey.settle()
        guard case .welcome(let late) = journey.state else {
            Issue.record("expected A2, got \(journey.state)")
            return
        }
        #expect(late.cards.count == 2)
        #expect(late.focus == offer.focus)
        #expect(log.drawn == 1)
        journey.stop()
    }

    @Test("An answer before the deadline: A2 at once, the deadline later changes nothing")
    func answerBeforeDeadline() async {
        let log = SetupLog()
        let clock = SetupClock()
        let journey = journey(services(log, clock: clock, cloud: .profiles([Self.lea])))
        journey.start()
        await journey.settle()
        journey.send(.introEnded)
        await SetupClock.drain()
        guard case .welcome(let offer) = journey.state else {
            Issue.record("expected A2, got \(journey.state)")
            return
        }
        await clock.advance(by: SetupMachine.cloudGrace)
        #expect(journey.state == .welcome(offer))
        #expect(log.drawn == 1)
        journey.stop()
    }

    @Test("The QR code on A2: the old one is withdrawn before the new one is valid")
    func codeRenewal() async {
        let log = SetupLog()
        let clock = SetupClock()
        var services = services(log, clock: clock)
        var issued = 0
        services.issueCode = {
            issued += 1
            let code = "c\(issued)"
            log.events.append("issue \(code)")
            log.liveCodes.insert(code)
            log.mostLiveCodes = max(log.mostLiveCodes, log.liveCodes.count)
            return code
        }
        services.revokeCode = {
            log.events.append("revoke \($0)")
            log.liveCodes.remove($0)
        }
        let journey = journey(services)

        journey.start()
        await journey.settle()
        await SetupClock.drain()
        #expect(journey.pairingCode == "c1")
        await clock.advance(by: .seconds(180))
        #expect(journey.pairingCode == "c2")

        journey.send(.choseNew)
        #expect(journey.pairingCode == nil, "A3 shows no code")
        #expect(log.events == ["issue c1", "revoke c1", "issue c2", "revoke c2"])
        #expect(log.mostLiveCodes == 1)
        #expect(log.liveCodes.isEmpty)
        journey.stop()
    }

    @Test("No code without a network")
    func noCodeOffline() async {
        let log = SetupLog()
        let clock = SetupClock()
        var services = services(log, clock: clock)
        services.watchNetwork = { $0(false) }
        services.issueCode = {
            log.events.append("issue")
            return "c"
        }
        let journey = journey(services)
        journey.start()
        await journey.settle()
        await SetupClock.drain()
        #expect(journey.pairingCode == nil)
        #expect(log.events.isEmpty)
        journey.stop()
    }

    @Test("G6 Quick Connect for another user: a question and no sign-in until it is answered")
    func otherUserStoresNothing() async {
        let log = SetupLog()
        let journey = journey(
            services(log, clock: SetupClock(), cloud: .profiles([Self.lea])), notice: true)
        journey.start()
        await journey.settle()
        journey.send(.chose(Self.lea.id))
        journey.send(.openSource(.jellyfin))

        journey.signedIn(Self.tomCredential)
        #expect(log.stored.isEmpty)
        journey.send(.acceptOtherUser)
        #expect(log.stored == [Self.tomCredential])
        journey.stop()
    }

    @Test("A refused switch stops everything behind it")
    func refusedActivationStops() async {
        let log = SetupLog()
        var services = services(log, clock: SetupClock(), cloud: .profiles([Self.lea]))
        services.activate = { _ in false }
        let journey = journey(services, notice: true)
        journey.start()
        await journey.settle()
        journey.send(.chose(Self.lea.id))
        await journey.settle()
        guard case .welcome = journey.state else {
            Issue.record("expected A2, got \(journey.state)")
            return
        }
        #expect(log.searches == 0)
        journey.stop()
    }

    @Test("G8 No search before the notice, exactly one after")
    func searchAfterNotice() async {
        let log = SetupLog()
        let journey = journey(services(log, clock: SetupClock()))
        journey.start()
        await journey.settle()
        journey.send(.choseNew)
        journey.send(.draftSaved(Self.anna))
        journey.send(.openSource(.jellyfin))
        await journey.settle()
        #expect(log.searches == 0)
        journey.send(.noticeAcknowledged)
        await journey.settle()
        #expect(log.searches == 1)
        journey.stop()
    }
}
