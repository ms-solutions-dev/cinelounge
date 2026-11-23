import Core
import Foundation
import PortalKit
import ProfileKit
import Testing

@testable import Household

/// **After a revocation the new token reaches the app** (AP47, 2026-09-25) — **on
/// TV and phone through the same version** (AP58 R2, finding P3). The checks of both programs
/// live together here: `BrandMatchingTests` of the TV and
/// `MarkReconciliationPhoneTests` of the phone. Each program checks its own wiring.
///
/// Through the whole integration: Every answer goes through
/// ``PortalKit/PortalBridge`` and the ``FakeConsole``. What is checked is the **slot afterwards** —
/// that is where the self-enrollment of the dropped devices reads, and the zone carries it across.
@Suite("Bring the token up to date, on both devices")
@MainActor
struct BrandMatchingTests {

    let keychain = InMemoryStore()
    let ledgers = InMemoryStore()
    let childProfile = Profile(
        identifier: Profile.Identifier(rawValue: UUID().uuidString), name: "Selin", color: .lilac,
        credentials: [.portals(person: "selin")])

    init() {
        var ledger = ProfileBook()
        ledger.create(childProfile)
        ledger.switchTo(zu: childProfile.identifier)
        ledger.write(in: ledgers)
    }

    static let meSelin = Data(
        ##"{"id":"selin","name":"Selin","role":"adult","color":"#9871C4","adult":true,"rights":{"watch":true}}"##
            .utf8)
    static let meMax = Data(
        ##"{"id":"max","name":"Max","role":"admin","color":"#000000","adult":true,"rights":{"pair_devices":true}}"##
            .utf8)
    static func tag(_ value: String, route: Int? = nil) -> Data {
        let devices = route.map { ##","devices_removed":\##($0)"## } ?? ""
        return Data(##"{"person":"selin","mark":"\##(value)"\##(devices)}"##.utf8)
    }
    static let enrollOK = Data(
        ##"{"device_token":"PRUEF-merkmal-enroll","person":{"id":"selin","name":"Selin","role":"adult","color":"#9871C4"}}"##
            .utf8)

    func sync(
        _ line: FakeConsole.Wire, keychain: InMemoryStore? = nil
    )
        -> TokenReconciliation
    {
        TokenReconciliation(
            basis: line.basis, session: FakeConsole.session,
            keychain: keychain ?? self.keychain, ledgerStore: ledgers,
            deviceName: "Apple TV Test rig", kind: .tv)
    }

    var bucket: PersonMarker? { PortalMarkerSlot(keychain).tag(forItem: childProfile.identifier) }

    // ── The bug ───────────────────────────────────────────────────────────────

    /// **The guard in question:** A device of the person that is still signed in asks the
    /// server for their token, and after a revocation the new one is in the slot.
    /// And a second device that came in via the old one signs in with it — the path
    /// the zone carries between the two is, here, flipping the slot.
    @Test("After a revocation the app holds the new token — and the dropped device comes back with it")
    func newTokenArrives() async throws {
        DeviceTrait.save("PRUEF-merkmal-code", to: keychain)
        PortalMarkerSlot(keychain).create(
            PersonMarker(value: "PRUEF-marke-alt")!, forItem: childProfile.identifier)
        let line = FakeConsole.setUp([
            "/household/me": (200, Self.meSelin),
            "/household/people/selin/mark": (200, Self.tag("PRUEF-marke-neu")),
            "/device/enroll": (200, Self.enrollOK),
        ])

        #expect(await sync(line).reconcile() == .fresh)
        #expect(bucket?.value == "PRUEF-marke-neu")
        let fetched = try #require(line.requestJoin.first { $0.route.hasSuffix("/mark") })
        #expect(fetched.method == "POST")
        // This device came in via a code and is alive: no new sign-in.
        #expect(!line.requestJoin.contains { $0.route == "/device/enroll" })
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-code")

        // A second time: the same token, nothing new.
        #expect(await sync(line).reconcile() == .unchanged)

        // The second device came in via the old token and dropped with it.
        let secondOne = InMemoryStore()
        DeviceTrait.save("PRUEF-merkmal-tot", to: secondOne)
        JoinNote(secondOne).rememberUsed(PersonMarker(value: "PRUEF-marke-alt")!)
        let fresh = try #require(bucket)
        PortalMarkerSlot(secondOne).create(fresh, forItem: childProfile.identifier)
        let back = await SelfSignIn(
            basis: line.basis, session: FakeConsole.session, keychain: secondOne,
            ledgerStore: ledgers, deviceName: "Apple TV Selin", kind: .tv
        ).attempts(.dismissed)
        #expect(back == .signedIn)
        #expect(DeviceTrait.load(from: secondOne) == "PRUEF-merkmal-enroll")
    }

    /// An administrator credential would also receive another profile's token — but it does not belong in a
    /// profile that happens to be in front of the device.
    @Test("Trait of another person: no request, no slot")
    func otherPerson() async {
        DeviceTrait.save("PRUEF-merkmal-max", to: keychain)
        let line = FakeConsole.setUp([
            "/household/me": (200, Self.meMax),
            "/household/people/selin/mark": (200, Self.tag("PRUEF-marke-neu")),
        ])
        #expect(await sync(line).reconcile() == .notNeeded)
        #expect(bucket == nil)
        #expect(line.requestJoin.map(\.route) == ["/household/me"])
    }

    @Test("Borrowed profile or child: never asked")
    func borrowedAndChild() async {
        DeviceTrait.save("PRUEF-merkmal", to: keychain)
        DeviceTrait.saveProfile("selin", to: keychain)
        let line = FakeConsole.setUp([
            "/household/me": (200, Self.meSelin),
            "/household/people/selin/mark": (200, Self.tag("PRUEF-marke-neu")),
        ])
        #expect(await sync(line).reconcile() == .notNeeded)
        #expect(line.requestJoin.isEmpty)

        var kind = childProfile
        kind.kind = .kind
        #expect(!TokenReconciliation.expectedValue(profile: kind, me: "selin", isBorrowed: false))
        #expect(!TokenReconciliation.expectedValue(profile: childProfile, me: "selin", isBorrowed: true))
        #expect(TokenReconciliation.expectedValue(profile: childProfile, me: "selin", isBorrowed: false))
    }

    // ── The revocation from the app ───────────────────────────────────────────

    /// **Decision 8.4:** Whoever ends the sharing revokes the token. If this
    /// device itself came in via it, it drops with it — and signs in at once with the new one.
    @Test("Sharing ended: DELETE, new token in the slot, the own device signs in again")
    func revocationFromTheApp() async throws {
        let old = PersonMarker(value: "PRUEF-marke-alt")!
        DeviceTrait.save("PRUEF-merkmal-ueber-marke", to: keychain)
        JoinNote(keychain).rememberUsed(old)
        PortalMarkerSlot(keychain).create(old, forItem: childProfile.identifier)
        let line = FakeConsole.setUp([
            "/household/me": (200, Self.meSelin),
            "/household/people/selin/mark": (200, Self.tag("PRUEF-marke-neu", route: 2)),
            "/device/enroll": (200, Self.enrollOK),
        ])

        #expect(await sync(line).revoke(forItem: childProfile.identifier) == .fresh)
        #expect(bucket?.value == "PRUEF-marke-neu")
        #expect(JoinNote(keychain).openRevocations.isEmpty)
        let revoke = try #require(line.requestJoin.first { $0.route.hasSuffix("/mark") })
        #expect(revoke.method == "DELETE")
        let login = try #require(line.requestJoin.first { $0.route == "/device/enroll" })
        let bodyContent = try #require(login.bodyContent)
        let object = try JSONSerialization.jsonObject(with: bodyContent)
        let mainContent = try #require(object as? [String: Any])
        #expect(mainContent["mark"] as? String == "PRUEF-marke-neu")
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-enroll")
    }

    /// The sharing has already ended in CloudKit — a failed revocation must not leave the
    /// old token silently valid.
    @Test("A failed revocation stays noted and runs again on the next reconciliation")
    func revocationCatchesUp() async throws {
        DeviceTrait.save("PRUEF-merkmal-code", to: keychain)
        PortalMarkerSlot(keychain).create(
            PersonMarker(value: "PRUEF-marke-alt")!, forItem: childProfile.identifier)
        let muted = FakeConsole.setUp([:])
        #expect(await sync(muted).revoke(forItem: childProfile.identifier) == .failed)
        #expect(JoinNote(keychain).openRevocations == [childProfile.identifier])
        #expect(bucket?.value == "PRUEF-marke-alt")

        let line = FakeConsole.setUp([
            "/household/me": (200, Self.meSelin),
            "/household/people/selin/mark": (200, Self.tag("PRUEF-marke-neu", route: 1)),
        ])
        #expect(await sync(line).reconcile() == .fresh)
        #expect(line.requestJoin.last?.method == "DELETE")
        #expect(JoinNote(keychain).openRevocations.isEmpty)
        #expect(bucket?.value == "PRUEF-marke-neu")
    }

    /// Without a token in the slot the participant has not received one either.
    @Test("Profile without a token: no revocation")
    func withoutTokenNoRevocation() async {
        DeviceTrait.save("PRUEF-merkmal-code", to: keychain)
        let line = FakeConsole.setUp([:])
        #expect(await sync(line).revoke(forItem: childProfile.identifier) == .notNeeded)
        #expect(line.requestJoin.isEmpty)
        #expect(JoinNote(keychain).openRevocations.isEmpty)
    }

    /// **Finding 2026-09-27, e2:** When the active profile needs nothing,
    /// ``TokenReconciliation/reconcile(me:isBorrowed:)`` returned `revoked.values.first` — the
    /// outcome of a FOREIGN revocation. `MainView.loadPortals()` checks `== .fresh` and
    /// then needlessly rebuilt the portal source every time, although the profile in front of
    /// the device (here without a portal wish) wanted nothing at all.
    @Test(
        "A revocation for another profile leaves the active one untouched instead of taking over its outcome")
    func foreignRevocationHasNoEffectOnActive() async throws {
        // The administrator is in front of the device but wants no portals — `Self.expectedValue` is wrong for them.
        let max = Profile(name: "Max")
        var ledger = ProfileBook.read(from: ledgers)
        ledger.create(max)
        ledger.switchTo(zu: max.identifier)
        ledger.write(in: ledgers)

        // A second profile (not in front of the device) has an open revocation request, and the
        // administrator may handle it (`meMax` carries `pair_devices`).
        DeviceTrait.save("PRUEF-merkmal-max", to: keychain)
        JoinNote(keychain).rememberRevocation(childProfile.identifier)
        let line = FakeConsole.setUp([
            "/household/people/selin/mark": (200, Self.tag("PRUEF-marke-neu"))
        ])
        let me = try JSONDecoder().decode(HouseholdPerson.self, from: Self.meMax)

        #expect(await sync(line).reconcile(me: me, isBorrowed: false) == .notNeeded)
        // The revocation ran anyway — only the administrator's own outcome is `.notNeeded`.
        #expect(JoinNote(keychain).openRevocations.isEmpty)
        #expect(PortalMarkerSlot(keychain).tag(forItem: childProfile.identifier)?.value == "PRUEF-marke-neu")
    }

    // ── The phone ─────────────────────────────────────────────────────────────

    /// **From `MarkReconciliationPhoneTests`:** A phone signed in via PIN is exactly the
    /// device that can fetch the new token after a revocation — its credential never depended on the
    /// token, so it stays, and the self-enrollment afterwards has nothing to do.
    @Test("A phone signed in via PIN fetches the new token and keeps its trait")
    func phoneWithPin() async throws {
        DeviceSignIn.create("PRUEF-merkmal-pin", own: true, in: keychain)
        PortalMarkerSlot(keychain).create(
            PersonMarker(value: "PRUEF-marke-alt")!, forItem: childProfile.identifier)
        let line = FakeConsole.setUp([
            "/household/me": (200, Self.meSelin),
            "/household/people/selin/mark": (200, Self.tag("PRUEF-marke-neu")),
            "/device/enroll": (200, Self.enrollOK),
        ])
        let phone = TokenReconciliation(
            basis: line.basis, session: FakeConsole.session, keychain: keychain,
            ledgerStore: ledgers, deviceName: "iPhone Test rig", kind: .web)
        #expect(await phone.reconcile() == .fresh)
        #expect(bucket?.value == "PRUEF-marke-neu")
        #expect(await phone.reconcile() == .unchanged)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-pin")
        #expect(!line.requestJoin.contains { $0.route == "/device/enroll" })
    }

    /// **Finding P3:** The phone did not check for a borrowed device. Since it switches via
    /// ``ProfileKit/ProfileSwitch``, a header can be present there too — and then it does
    /// not ask, otherwise the borrowed person's token would sit in this device's slot.
    @Test("A loaner device never asks, whichever device it is", arguments: [DeviceKind.tv, .web])
    func loanDevice(kind: DeviceKind) async {
        DeviceTrait.save("PRUEF-merkmal", to: keychain)
        DeviceTrait.saveProfile("selin", to: keychain)
        let line = FakeConsole.setUp([
            "/household/me": (200, Self.meSelin),
            "/household/people/selin/mark": (200, Self.tag("PRUEF-marke-neu")),
        ])
        let sync = TokenReconciliation(
            basis: line.basis, session: FakeConsole.session, keychain: keychain,
            ledgerStore: ledgers, deviceName: "Test rig", kind: kind)
        #expect(await sync.reconcile() == .notNeeded)
        #expect(line.requestJoin.isEmpty)
        #expect(bucket == nil)
    }
}
