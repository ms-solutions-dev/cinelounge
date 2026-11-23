import Core
import Foundation
import PortalKit
import ProfileKit
import Testing

@testable import Household

/// **The revocation no longer depends on the active profile** (cross-check strand D, 2.1/2.2) —
/// since AP58 R2 here in the `Household` package, because the revocation is the same on both devices.
///
/// The check reproduced the cases on a copy; there "green" meant the revocation
/// stays stuck. Here it is the other way round: Every test was red at the state of `a8a4326`.
@Suite("Revoke the token, no matter who is sitting in front")
@MainActor
struct TokenRevocationTests {

    let keychain = InMemoryStore()
    let ledgers = InMemoryStore()
    let childProfile = Profile(
        identifier: Profile.Identifier(rawValue: UUID().uuidString), name: "Selin", color: .lilac,
        credentials: [.portals(person: "selin")])
    let max = Profile(
        identifier: Profile.Identifier(rawValue: UUID().uuidString), name: "Max", color: .lilac,
        credentials: [.portals(person: "max")])
    let childRequest = Profile(
        identifier: Profile.Identifier(rawValue: UUID().uuidString), name: "Emre", color: .lilac,
        credentials: [.portals(person: "emre")])

    static let ownerToken = Data(##"{"person":"max","mark":"PRUEF-max"}"##.utf8)

    func sync(_ line: FakeConsole.Wire) -> TokenReconciliation {
        TokenReconciliation(
            basis: line.basis, session: FakeConsole.session,
            keychain: keychain, ledgerStore: ledgers,
            deviceName: "Test rig", kind: .tv)
    }

    func ledger(_ profileEntry: [Profile], active: Profile) {
        var ledger = ProfileBook()
        for profileName in profileEntry { ledger.create(profileName) }
        ledger.switchTo(zu: active.identifier)
        ledger.write(in: ledgers)
    }

    var pending: [Profile.Identifier] { JoinNote(keychain).openRevocations }

    func deletions(_ line: FakeConsole.Wire) -> [String] {
        line.requestJoin.filter { $0.method == "DELETE" }.map(\.route)
    }

    /// The administrator is in front of the device and ends the sharing of another profile.
    @Test("2.1: The revocation for a non-active profile goes straight to the server")
    func revocationNotActive() async throws {
        ledger([childProfile, max], active: max)
        DeviceTrait.save("PRUEF-merkmal-max", to: keychain)
        PortalMarkerSlot(keychain).create(
            PersonMarker(value: "PRUEF-selin-alt")!, forItem: childProfile.identifier)
        let line = FakeConsole.setUp([
            "/household/people/selin/mark": (200, BrandMatchingTests.tag("PRUEF-selin-neu", route: 1))
        ])
        #expect(await sync(line).revoke(forItem: childProfile.identifier) == .fresh)
        #expect(deletions(line) == ["/household/people/selin/mark"])
        #expect(pending.isEmpty)
        #expect(PortalMarkerSlot(keychain).tag(forItem: childProfile.identifier)?.value == "PRUEF-selin-neu")
    }

    @Test("2.1b: Two failed revocations both stay noted and both run again")
    func twoRevocations() async throws {
        ledger([childProfile, max, childRequest], active: max)
        DeviceTrait.save("PRUEF-merkmal-max", to: keychain)
        PortalMarkerSlot(keychain).create(PersonMarker(value: "A")!, forItem: childProfile.identifier)
        PortalMarkerSlot(keychain).create(PersonMarker(value: "B")!, forItem: childRequest.identifier)
        let muted = FakeConsole.setUp([:])
        #expect(await sync(muted).revoke(forItem: childProfile.identifier) == .failed)
        #expect(await sync(muted).revoke(forItem: childRequest.identifier) == .failed)
        #expect(Set(pending) == [childProfile.identifier, childRequest.identifier])

        // The administrator may pair devices — their reconciliation catches up on both.
        let line = FakeConsole.setUp([
            "/household/me": (200, BrandMatchingTests.meMax),
            "/household/people/selin/mark": (200, BrandMatchingTests.tag("A2")),
            "/household/people/emre/mark": (200, BrandMatchingTests.tag("B2")),
            "/household/people/max/mark": (200, Self.ownerToken),
        ])
        _ = await sync(line).reconcile()
        #expect(Set(deletions(line)) == ["/household/people/selin/mark", "/household/people/emre/mark"])
        #expect(pending.isEmpty)
    }

    /// A profile without the right to pair devices does not even request foreign revocations.
    @Test("2.1: Without permission a foreign revocation stays pending and is not attempted")
    func withoutPermission() async throws {
        ledger([childProfile, max], active: childProfile)
        DeviceTrait.save("PRUEF-merkmal-selin", to: keychain)
        JoinNote(keychain).rememberRevocation(max.identifier)
        let line = FakeConsole.setUp([
            "/household/me": (200, BrandMatchingTests.meSelin),
            "/household/people/selin/mark": (200, BrandMatchingTests.tag("PRUEF-selin")),
        ])
        _ = await sync(line).reconcile()
        #expect(deletions(line).isEmpty)
        #expect(pending == [max.identifier])
    }

    /// A converted profile still carries an adult's token; it remains valid at the
    /// server.
    @Test("2.1: A child profile with a token is revoked and keeps none")
    func childRevocation() async throws {
        var kind = childProfile
        kind.kind = .kind
        ledger([kind], active: kind)
        DeviceTrait.save("PRUEF-merkmal", to: keychain)
        PortalMarkerSlot(keychain).create(PersonMarker(value: "PRUEF-alt")!, forItem: kind.identifier)
        let line = FakeConsole.setUp([
            "/household/people/selin/mark": (200, BrandMatchingTests.tag("PRUEF-neu", route: 1))
        ])
        _ = await sync(line).revoke(forItem: kind.identifier)
        #expect(deletions(line) == ["/household/people/selin/mark"])
        #expect(pending.isEmpty)
        #expect(PortalMarkerSlot(keychain).tag(forItem: kind.identifier) == nil)
    }

    @Test("2.2: A note for a deleted profile or a child is cleared")
    func deletedOrChild() async throws {
        var kind = childRequest
        kind.kind = .kind
        ledger([max, kind], active: max)
        DeviceTrait.save("PRUEF-merkmal-max", to: keychain)
        JoinNote(keychain).rememberRevocation(childProfile.identifier)
        JoinNote(keychain).rememberRevocation(kind.identifier)
        let line = FakeConsole.setUp([
            "/household/me": (200, BrandMatchingTests.meMax),
            "/household/people/max/mark": (200, Self.ownerToken),
        ])
        _ = await sync(line).reconcile()
        #expect(pending.isEmpty, "does not hang around forever")
        #expect(deletions(line).isEmpty)
    }

    @Test("A note from before the set existed is read as a set of one")
    func oldNote() throws {
        // Assembled, so that `scripts/strings.py` does not read it as a language key.
        try keychain.set(childProfile.identifier.rawValue, for: "beitritt" + ".widerrufOffen")
        #expect(pending == [childProfile.identifier])
        JoinNote(keychain).rememberRevocation(max.identifier)
        #expect(pending == [childProfile.identifier, max.identifier])
        JoinNote(keychain).forgetRevocation(childProfile.identifier)
        #expect(pending == [max.identifier])
    }
}
