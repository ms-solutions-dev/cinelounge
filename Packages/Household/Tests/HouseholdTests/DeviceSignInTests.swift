import Core
import Foundation
import PortalKit
import Testing

@testable import Household

/// **What a sign-in leaves on the device — the same store on both devices** (AP58 R2,
/// findings P3 and E4).
///
/// Until R2 only the TV set the own-credential; the phone, after invitation and
/// PIN sign-in, only stored the credential. Since the phone switches via ``ProfileKit/ProfileSwitch``,
/// the portal header depends on the own-credential — without it the first switch turned the own
/// sign-in into a loan.
///
/// Counter-test: Without `saveOwn` in ``DeviceSignIn/create(_:own:in:)``
/// ``invitationWithPerson()`` and ``signInWithPin()`` go red.
@Suite("Device sign-in")
@MainActor
struct DeviceSignInTests {

    let keychain = InMemoryStore()

    static let withPerson = Data(
        ##"{"device_token":"PRUEF-merkmal-person","person":{"id":"selin","name":"Selin","role":"adult","color":"#9871C4"}}"##
            .utf8)
    static let withoutPerson = Data(##"{"device_token":"PRUEF-merkmal-geraet"}"##.utf8)

    @Test("Invitation with person: trait, no loaner head, own", arguments: [DeviceKind.tv, .web])
    func invitationWithPerson(kind: DeviceKind) async throws {
        DeviceTrait.saveProfile("irgendwer", to: keychain)
        let line = FakeConsole.setUp(["/redeem": (200, Self.withPerson)])
        let invitation = try #require(Invitation(input: "ABC123"))
        try await DeviceSignIn.redeem(
            invitation, basis: line.basis, session: FakeConsole.session,
            keychain: keychain, deviceName: "Test rig", kind: kind)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-person")
        #expect(DeviceTrait.profile(from: keychain) == nil)
        #expect(DeviceTrait.own(in: keychain))
    }

    /// **A pairing code without a person makes a shared device** — the family iPad just
    /// like the living-room TV.
    @Test("Invitation without person: shared device")
    func invitationWithoutPerson() async throws {
        DeviceTrait.saveOwn(true, to: keychain)
        let line = FakeConsole.setUp(["/redeem": (200, Self.withoutPerson)])
        try await DeviceSignIn.redeem(
            try #require(Invitation(input: "ABC123")), basis: line.basis,
            session: FakeConsole.session, keychain: keychain, kind: .web)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-geraet")
        #expect(!DeviceTrait.own(in: keychain))
    }

    @Test("Sign-in with person and PIN: the device belongs to them")
    func signInWithPin() async throws {
        let line = FakeConsole.setUp(["/login": (200, Self.withPerson)])
        try await DeviceSignIn.notify(
            on: "selin", pin: "1234", basis: line.basis, session: FakeConsole.session,
            keychain: keychain, deviceName: "iPhone Test rig")
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-person")
        #expect(DeviceTrait.own(in: keychain))
        #expect(DeviceTrait.profile(from: keychain) == nil)
    }

    @Test("A rejection stores nothing")
    func rejection() async throws {
        let line = FakeConsole.setUp([
            "/login": (401, Data(##"{"error":{"code":"auth.bad_credentials","values":{}}}"##.utf8))
        ])
        await #expect(throws: PortalBridge.TestError.self) {
            try await DeviceSignIn.notify(
                on: "selin", pin: "0000", basis: line.basis, session: FakeConsole.session,
                keychain: keychain)
        }
        #expect(DeviceTrait.load(from: keychain) == nil)
        #expect(!DeviceTrait.own(in: keychain))
    }

    /// **An old phone belongs to its person — backfilled once, then never again.**
    @Test("The follow-up runs exactly once and only without a loaner head")
    func backfillOnce() {
        #expect(!DeviceSignIn.adoptsLegacySignIn(in: keychain), "without trait")

        let old = InMemoryStore()
        DeviceTrait.save("PRUEF-merkmal-alt", to: old)
        #expect(DeviceSignIn.adoptsLegacySignIn(in: old))
        #expect(DeviceTrait.own(in: old))

        // Later a pairing code without a person: stays shared, even after the next start.
        DeviceSignIn.create("PRUEF-merkmal-neu", own: false, in: old)
        #expect(!DeviceSignIn.adoptsLegacySignIn(in: old))
        #expect(!DeviceTrait.own(in: old))

        let isBorrowed = InMemoryStore()
        DeviceTrait.save("PRUEF-merkmal", to: isBorrowed)
        DeviceTrait.saveProfile("selin", to: isBorrowed)
        #expect(!DeviceSignIn.adoptsLegacySignIn(in: isBorrowed))
        #expect(!DeviceTrait.own(in: isBorrowed))
    }
}
