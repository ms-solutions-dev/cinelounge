import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// The recovery path "PIN forgotten" — the evaluation on its own, without zone and without account.
@Suite("The forgotten-PIN way out")
struct PinRecoveryTests {

    /// **The parental controls and not a profile.** These checks date from AP43
    /// and belong to the household's one lock; that the recovery path has also worked per
    /// profile since AP45 changes nothing about that.
    static let who = PINFallback.Lock.parentalControls

    let now = Date(timeIntervalSince1970: 1_758_400_000)

    /// A request as the server returns it — with a stamp.
    func stamped(_ when: Date, device: String = "Wohnzimmer") -> CloudRecord {
        var message = PINFallback.request(forItem: Self.who, device: device, now: when)
        message.serverTime = when
        return message
    }

    @Test("Without a request nothing is open")
    func withoutRequest() {
        #expect(PINFallback.state(from: nil, now: now) == .none)
        #expect(PINFallback.state(from: nil, now: now).pending == false)
        #expect(PINFallback.state(from: nil, now: now).resolves == false)
    }

    /// **The case that decided the whole design.**
    ///
    /// tvOS's system clock is in *its* settings and not behind this
    /// lock. Whoever calculated the deadline against the device time would have one that a child
    /// skips in two minutes. The calculation is against the server's stamp — the
    /// advanced clock then only makes the display wrong.
    @Test("A device clock set ahead does not shorten the deadline")
    func advancedClock() {
        let message = stamped(now)

        // The device claims it is a week later.
        let lied = now.addingTimeInterval(7 * 24 * 3600)
        // And the deadline runs anyway — the stamp is from just now.
        #expect(PINFallback.state(from: message, now: lied).resolves == true)

        // Only the counter-proof makes the check valuable: Without the server's stamp
        // nothing runs at all, whatever the device claims.
        var without = message
        without.serverTime = nil
        #expect(PINFallback.state(from: without, now: lied) == .wartetAufServer(device: "Wohnzimmer"))
        #expect(PINFallback.state(from: without, now: lied).resolves == false)
    }

    /// **Without a network no deadline expires** — inconvenient and right. A device without a
    /// connection has no credible time anchor, and a deadline that can be sped up with
    /// airplane mode is none.
    @Test("A request the server never saw triggers nothing")
    func withoutServer() {
        let message = PINFallback.request(forItem: Self.who, device: "Wohnzimmer", now: now)
        #expect(message.serverTime == nil)
        let late = now.addingTimeInterval(PINFallback.deadline * 10)
        #expect(PINFallback.state(from: message, now: late).resolves == false)
    }

    @Test("Before the deadline it is running, afterwards it is due")
    func deadline() {
        let message = stamped(now)
        let justBefore = now.addingTimeInterval(PINFallback.deadline - 1)
        #expect(
            PINFallback.state(from: message, now: justBefore)
                == .isRunning(due: now.addingTimeInterval(PINFallback.deadline), device: "Wohnzimmer"))
        #expect(
            PINFallback.state(from: message, now: now.addingTimeInterval(PINFallback.deadline))
                == .due(device: "Wohnzimmer"))
    }

    /// **The deadline is in the record and not in the code** — the same rule as with
    /// ``Pairing``: The reviewer should see it and not only the one who set it.
    @Test("The deadline from the record is used for the calculation")
    func deadlineFromRecord() {
        var message = stamped(now)
        message.fields[PINFallback.deadlineField] = .double(60)
        #expect(PINFallback.state(from: message, now: now.addingTimeInterval(61)).resolves)
        // And a row without a deadline falls back to the agreed one instead of releasing immediately.
        message.fields[PINFallback.deadlineField] = nil
        #expect(PINFallback.state(from: message, now: now.addingTimeInterval(61)).resolves == false)
    }

    /// The quick way — and it overrides the deadline, because a human has agreed.
    @Test("A confirmation takes effect immediately")
    func confirmation() {
        let message = PINFallback.confirmation(zu: stamped(now), finished: "Maxs iPhone")
        #expect(PINFallback.state(from: message, now: now).resolves)
        #expect(PINFallback.confirmedBy(message) == "Maxs iPhone")
        // The name of the requesting device stays — it is shown on the TV.
        #expect(PINFallback.state(from: message, now: now) == .confirmed(device: "Wohnzimmer"))
    }

    /// **A confirmation without a stamp works too** — it is a human's agreement
    /// and not a calculation with a clock.
    @Test("The confirmation needs no server stamp")
    func confirmationWithoutStamp() {
        let raw = PINFallback.request(forItem: Self.who, device: "Wohnzimmer", now: now)
        #expect(raw.serverTime == nil)
        let confirmed = PINFallback.confirmation(zu: raw, finished: "iPad")
        #expect(PINFallback.state(from: confirmed, now: now).resolves)
    }

    @Test("The device name travels along")
    func deviceName() {
        let message = stamped(now, device: "Kinderzimmer")
        #expect(
            PINFallback.state(from: message, now: now)
                == .isRunning(
                    due: now.addingTimeInterval(PINFallback.deadline), device: "Kinderzimmer"))
    }

    /// **The zone is not a profile zone**, and that is what ensures no participant sees it.
    @Test("The way out lies outside every profile zone")
    func ownZone() {
        #expect(!PINFallback.zone.isProfile)
        #expect(!PINFallback.zone.shared)
    }
}

// MARK: - Two locks (AP45, 2026-09-24)

/// **The find that made ``PINFallback/Lock`` necessary.**
///
/// The recovery path was built for the **parental controls**, and there "one request per
/// household" is right — there is exactly one. AP45 demands a recovery path for
/// **profile** PINs, and those exist per person. Run through a single name, a
/// request for the child profile would have taken the adult's deadline with it.
@Test("Parental controls and profile are two different requests")
func twoLocks() {
    let childProfile = Profile.Identifier(rawValue: "selin")
    let max = Profile.Identifier(rawValue: "max")

    #expect(PINFallback.name(forItem: .parentalControls) != PINFallback.name(forItem: .profile(childProfile)))
    #expect(PINFallback.name(forItem: .profile(childProfile)) != PINFallback.name(forItem: .profile(max)))
}

/// **The parental controls keep "current"**, and that is not a convenience: A
/// running request lies in the cloud under this name. Renaming it would mean losing a
/// deadline that someone set hours ago.
@Test("The parental controls' name stays as it was")
func parentalControlsKeepTheirName() {
    #expect(PINFallback.name(forItem: .parentalControls) == "aktuell")
}

/// And a profile name can never become "current" — otherwise both would collide.
@Test("A profile cannot hit the parental controls' name")
func profileDoesNotHitCurrent() {
    // Even a profile that calls itself "current" lies under a different name.
    let malicious = Profile.Identifier(rawValue: "aktuell")
    #expect(PINFallback.name(forItem: .profile(malicious)) != "aktuell")
}

/// The path via the zone — against the fake, with two devices on one Apple ID.
@Suite("The way out between two devices")
@MainActor
struct PinRecoveryTwoDevicesTests {

    /// The same lock as above — the household's parental controls.
    static let who = PINFallback.Lock.parentalControls

    let server = MockCloud()
    let now = Date(timeIntervalSince1970: 1_758_400_000)

    func device(_ name: String) -> ProfileCloud {
        let hub = CloudHub(
            service: server.credential("max", name: name), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        return ProfileCloud(hub: hub, store: InMemoryStore(), moveBundle: nil, automatic: false)
    }

    /// **The whole quick path:** The TV requests, the phone sees it and
    /// confirms, the TV may open.
    @Test("The second device confirms, the lock falls")
    func confirmationPath() async throws {
        server.clock = now
        let tv = device("Wohnzimmer")
        tv.requestPinRecovery(forItem: Self.who, device: "Wohnzimmer", now: now)
        _ = await tv.household()?.reconcile()

        let phone = device("Maxs iPhone")
        _ = await phone.household()?.reconcile()
        #expect(
            phone.pinState(forItem: Self.who, now: now)
                == .isRunning(
                    due: now.addingTimeInterval(PINFallback.deadline), device: "Wohnzimmer"))

        #expect(phone.confirmPinRecovery(forItem: Self.who, device: "Maxs iPhone", now: now))
        _ = await phone.household()?.reconcile()

        _ = await tv.household()?.reconcile()
        #expect(tv.pinState(forItem: Self.who, now: now).resolves)
    }

    /// **The server stamps, not the writer.** Before the first pass the request
    /// carries no stamp — and thus no deadline runs.
    @Test("Only the trip to the server starts the clock")
    func stampComesFromServer() async throws {
        server.clock = now
        let tv = device("Wohnzimmer")
        tv.requestPinRecovery(forItem: Self.who, device: "Wohnzimmer", now: now)

        let late = now.addingTimeInterval(PINFallback.deadline * 3)
        #expect(tv.pinState(forItem: Self.who, now: late) == .wartetAufServer(device: "Wohnzimmer"))

        _ = await tv.household()?.reconcile()
        #expect(tv.pinState(forItem: Self.who, now: late).resolves)
    }

    /// **A second request extends nothing.** Otherwise every press of the button would reset
    /// the clock — by the same human who wants to get rid of it.
    @Test("A second request does not reset the clock")
    func noRefill() async throws {
        server.clock = now
        let tv = device("Wohnzimmer")
        tv.requestPinRecovery(forItem: Self.who, device: "Wohnzimmer", now: now)
        _ = await tv.household()?.reconcile()

        // Pressed again twelve hours later.
        let later = now.addingTimeInterval(12 * 3600)
        server.clock = later
        tv.requestPinRecovery(forItem: Self.who, device: "Wohnzimmer", now: later)
        _ = await tv.household()?.reconcile()

        // The deadline keeps running from the first request.
        #expect(tv.pinState(forItem: Self.who, now: now.addingTimeInterval(PINFallback.deadline)).resolves)
    }

    /// Cancelling works from any device — and without a PIN.
    @Test("The phone cancels, the TV sees it")
    func abort() async throws {
        server.clock = now
        let tv = device("Wohnzimmer")
        tv.requestPinRecovery(forItem: Self.who, device: "Wohnzimmer", now: now)
        _ = await tv.household()?.reconcile()

        let phone = device("Maxs iPhone")
        _ = await phone.household()?.reconcile()
        phone.cancelPinRecovery(forItem: Self.who)
        _ = await phone.household()?.reconcile()

        _ = await tv.household()?.reconcile()
        #expect(tv.pinState(forItem: Self.who, now: now) == .none)
    }

    /// Without iCloud there is no household zone — and no screen that pretends otherwise.
    @Test("Without an account there is no way out via the cloud")
    func withoutAccount() {
        let hub = CloudHub(
            service: nil, file: nil,
            device: DeviceDescription(identifier: "x", name: "x", model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: InMemoryStore(), moveBundle: nil, automatic: false)
        #expect(cloud.household() == nil)
        #expect(cloud.pinState(forItem: Self.who, now: now) == .none)
        #expect(cloud.requestPinRecovery(forItem: Self.who, device: "Wohnzimmer", now: now) == .none)
    }
}
