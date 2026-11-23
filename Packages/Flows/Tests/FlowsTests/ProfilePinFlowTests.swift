import CloudSync
import Core
import Foundation
import ProfileKit
import Testing

@testable import Flows

/// **Profile PIN and "Forgot PIN" as one flow for TV and phone** (AP58 R2,
/// finding P2).
///
/// The gap from the report: *"one flow request → running → due → resolve against a
/// cloud dummy, for both platforms"*. Two devices on the same Apple account, one is called
/// TV, one phone — the same flow on both.
///
/// Counter-check: without the fresh check in ``PinRecoveryFlow/redeem()`` (`guard state.resolves`)
/// ``runningDeadlineDoesNotRelease()`` resolves the PIN, and ``cancelledDoesNotRelease()`` resolves a
/// request that the other device has just cancelled.
@MainActor
@Suite("Profile PIN: the shared flow")
struct ProfilePinFlowTests {

    let server = MockCloud()
    let person = Profile(
        identifier: .init(rawValue: "3A7A0000-0000-4000-8000-00000000BEEF"), name: "Alex")
    let today = Date()
    var tomorrow: Date { today.addingTimeInterval(PINFallback.deadline + 60) }

    /// **The server's clock is set to `today`** (2026-09-27): without it the
    /// dummy stamped with the real time on saving. Under load in the full run the stamp
    /// lay more than the 60 seconds of leeway of ``tomorrow`` behind `today`, and
    /// ``deadlineExpires(tvRequested:)`` still saw the deadline running.
    init() {
        server.clock = today
    }

    struct Device {
        let name: String
        let cloud: ProfileCloud
        let secureStore: InMemoryStore
    }

    func device(_ name: String) -> Device {
        let store = InMemoryStore()
        let secureStore = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("alex"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: store, moveBundle: secureStore, automatic: false)
        cloud.startStore = nil
        var ledger = ProfileBook.read(from: store)
        ledger.create(person)
        ledger.write(in: store)
        return Device(name: name, cloud: cloud, secureStore: secureStore)
    }

    func flow(
        _ g: Device, _ state: ProfilePinFlow.Situation = .maintain, now: Date? = nil
    ) -> ProfilePinFlow {
        let flow = ProfilePinFlow(
            profile: person, state: state, keychain: g.secureStore, cloud: g.cloud, device: g.name)
        let clock = now ?? today
        flow.now = { clock }
        return flow
    }

    func isSet(_ g: Device) -> Bool { ProfilePIN(store: g.secureStore, forItem: person.identifier).isSet }

    /// Sets "4711" on the first device and syncs both.
    func withPin(_ a: Device, _ b: Device) async {
        #expect(flow(a).set("4711") == .isSet)
        await a.cloud.reconcile(person)
        await b.cloud.reconcile(person)
        #expect(isSet(b))
    }

    // MARK: - The steps

    @Test("Without PIN straight to setting, with PIN first the choice, at the latch the block")
    func start() async {
        let tv = device("tv")
        #expect(flow(tv).step == .fresh(old: nil))
        #expect(flow(tv, .lock).step == .lock)
        flow(tv).set("4711")
        #expect(flow(tv).step == .choice)
    }

    @Test("Changing requires the old one, removing too — without it nothing changes")
    func oldOneRequired() {
        let tv = device("tv")
        flow(tv).set("4711")

        let change = flow(tv)
        #expect(change.acceptOld("4711") == .wrong, "the choice first")
        change.chooseChange()
        #expect(change.acceptOld("0000") == .wrong)
        #expect(change.step == .oldPinForChange)
        #expect(change.acceptOld("4711") == .next)
        #expect(change.step == .fresh(old: "4711"))
        #expect(change.set("2580") == .isSet)

        let remove = flow(tv)
        remove.chooseRemoval()
        #expect(remove.acceptOld("4711") == .wrong, "the old one no longer applies")
        #expect(isSet(tv))
        #expect(remove.acceptOld("2580") == .removed)
        #expect(!isSet(tv))
    }

    @Test("The fallback leads back to where it came from — and never when setting")
    func escapeBack() {
        let tv = device("tv")
        let set = flow(tv)
        set.openRecovery()
        #expect(set.step == .fresh(old: nil), "where there is no PIN, there is nothing to forget")

        flow(tv).set("4711")
        let lock = flow(tv, .lock)
        lock.openRecovery()
        #expect(lock.step == .recovery)
        lock.back()
        #expect(lock.step == .lock)
    }

    @Test("Without the cloud there is no fallback")
    func withoutCloud() {
        let secureStore = InMemoryStore()
        ProfilePIN(store: secureStore, forItem: person.identifier).set("4711", now: today)
        let flow = ProfilePinFlow(
            profile: person, state: .lock, keychain: secureStore, cloud: nil, device: "x")
        #expect(flow.recovery == nil)
        flow.openRecovery()
        #expect(flow.step == .lock)
    }

    // MARK: - Request → running → due → resolve

    /// **The same path on both devices** — once the TV makes the request, once
    /// the phone. The deadline runs by the server's clock; it resolves only when it has
    /// elapsed, and then household-wide.
    @Test("Requested, running, due, resolved — the PIN drops on both devices", arguments: [true, false])
    func deadlineExpires(tvRequested: Bool) async throws {
        let tv = device("tv")
        let phone = device("phone")
        await withPin(tv, phone)
        let requester = tvRequested ? tv : phone
        let other = tvRequested ? phone : tv

        let todaySheet = flow(requester, .lock)
        todaySheet.openRecovery()
        let recovery = try #require(todaySheet.recovery)
        recovery.request()
        await recovery.read()
        guard case .isRunning(_, let who) = recovery.state else {
            Issue.record("expected running, was \(recovery.state)")
            return
        }
        #expect(who == requester.name)
        #expect(await !todaySheet.redeemRecovery())
        #expect(isSet(requester))

        let tomorrowSheet = flow(requester, .lock, now: tomorrow)
        tomorrowSheet.openRecovery()
        #expect(await tomorrowSheet.redeemRecovery())
        #expect(!isSet(requester))

        await requester.cloud.reconcile(person)
        _ = await requester.cloud.household()?.reconcile()
        await other.cloud.reconcile(person)
        #expect(!isSet(other), "household-wide")
        let rest = try #require(flow(other, .lock).recovery)
        await rest.read()
        #expect(rest.state == .none, "and the request with it")
    }

    @Test("A confirmation from the other device resolves immediately — read after the sync")
    func confirmedReleases() async throws {
        let tv = device("tv")
        let phone = device("phone")
        await withPin(tv, phone)
        let sheet = flow(tv, .lock)
        let recovery = try #require(sheet.recovery)
        recovery.request()
        _ = await tv.cloud.household()?.reconcile()
        _ = await phone.cloud.household()?.reconcile()
        #expect(phone.cloud.confirmPinRecovery(forItem: .profile(person.identifier), device: "phone"))
        _ = await phone.cloud.household()?.reconcile()

        // **The finding on the TV:** read synchronously, it still said "running" here.
        await recovery.read()
        #expect(recovery.state == .confirmed(device: "tv"), "the name is that of the requester")
        #expect(await sheet.redeemRecovery())
        #expect(!isSet(tv))
    }

    @Test("A running deadline resolves nothing, even if the button is pressed")
    func runningDeadlineDoesNotRelease() async throws {
        let tv = device("tv")
        flow(tv).set("4711")
        let recovery = try #require(flow(tv, .lock).recovery)
        recovery.request()
        #expect(await !recovery.redeem())
        #expect(await !flow(tv, .lock).redeemRecovery())
        #expect(isSet(tv))
    }

    /// **Freshly read:** the phone cancels while the TV shows "due" —
    /// pressing "Resolve" must then open nothing.
    @Test("A request the other device has canceled resolves nothing any more")
    func cancelledDoesNotRelease() async throws {
        let tv = device("tv")
        let phone = device("phone")
        await withPin(tv, phone)
        let sheet = flow(tv, .lock, now: tomorrow)
        let recovery = try #require(sheet.recovery)
        recovery.request()
        _ = await tv.cloud.household()?.reconcile()
        await recovery.read()

        _ = await phone.cloud.household()?.reconcile()
        phone.cloud.cancelPinRecovery(forItem: .profile(person.identifier))
        _ = await phone.cloud.household()?.reconcile()

        #expect(await !sheet.redeemRecovery())
        #expect(isSet(tv))
    }
}
