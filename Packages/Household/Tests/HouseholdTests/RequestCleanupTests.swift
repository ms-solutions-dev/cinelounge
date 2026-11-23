import Core
import Foundation
import PortalKit
import ProfileKit
import Testing

@testable import Household

/// **Every sign-in clears an open join request** (check of 2026-09-27, Portals B1).
///
/// The finding: On the TV someone asked for admission, the administrator paired via
/// code instead. The request stayed remembered, and a later approval replaced the credential of
/// the shared TV — it then silently belonged to one person. After an explicit
/// sign-out the device signed in again via the same request.
///
/// Counter-test: Without `forgetRequest()` in ``DeviceSignIn/create(_:own:in:)`` the
/// three sign-in paths go red, without the line in ``PortalSignOut`` the sign-out does.
@Suite("Sign-in clears the join request")
@MainActor
struct RequestCleanupTests {

    let keychain = InMemoryStore()
    let ledgers = InMemoryStore()
    let asking = Profile.Identifier(rawValue: UUID().uuidString)

    static let withPerson = Data(
        ##"{"device_token":"PRUEF-merkmal-person","person":{"id":"selin","name":"Selin","role":"adult","color":"#9871C4"}}"##
            .utf8)
    static let withoutPerson = Data(##"{"device_token":"PRUEF-merkmal-wohnzimmer"}"##.utf8)

    var pending: Bool { JoinNote(keychain).openRequest != nil }

    @Test("A pairing code clears the request")
    func code() async throws {
        JoinNote(keychain).rememberRequest("abc", forItem: asking)
        let line = FakeConsole.setUp(["/redeem": (200, Self.withoutPerson)])
        try await DeviceSignIn.redeem(
            try #require(Invitation(input: "K7M2QX")), basis: line.basis,
            session: FakeConsole.session, keychain: keychain,
            deviceName: "Wohnzimmer", kind: .tv)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-wohnzimmer")
        #expect(!pending)
    }

    @Test("An invitation with a person clears the request")
    func invitation() async throws {
        JoinNote(keychain).rememberRequest("abc", forItem: asking)
        let line = FakeConsole.setUp(["/redeem": (200, Self.withPerson)])
        try await DeviceSignIn.redeem(
            try #require(Invitation(input: "ABC123")), basis: line.basis,
            session: FakeConsole.session, keychain: keychain, kind: .web)
        #expect(!pending)
    }

    @Test("A sign-in with PIN clears the request")
    func pin() async throws {
        JoinNote(keychain).rememberRequest("abc", forItem: asking)
        let line = FakeConsole.setUp(["/login": (200, Self.withPerson)])
        try await DeviceSignIn.notify(
            on: "selin", pin: "1234", basis: line.basis, session: FakeConsole.session,
            keychain: keychain, deviceName: "iPhone Test rig")
        #expect(!pending)
    }

    @Test("A failed sign-in leaves the request in place")
    func rejection() async throws {
        JoinNote(keychain).rememberRequest("abc", forItem: asking)
        let line = FakeConsole.setUp([
            "/login": (401, Data(##"{"error":{"code":"auth.bad_credentials","values":{}}}"##.utf8))
        ])
        await #expect(throws: PortalBridge.TestError.self) {
            try await DeviceSignIn.notify(
                on: "selin", pin: "0000", basis: line.basis, session: FakeConsole.session,
                keychain: keychain)
        }
        #expect(pending)
    }

    /// A sign-out cancels no waiting queue: afterwards the request can no longer pick up an
    /// approval.
    @Test("Signing out clears the request")
    func signOut() async {
        DeviceSignIn.create("PRUEF-merkmal-wohnzimmer", own: false, in: keychain)
        JoinNote(keychain).rememberRequest("abc", forItem: asking)
        let line = FakeConsole.setUp(["/logout": (200, Data("{}".utf8))])
        await PortalSignOut.notify(
            from: false, basis: line.basis, session: FakeConsole.session,
            keychain: keychain, ledgerStore: ledgers)
        #expect(DeviceTrait.load(from: keychain) == nil)
        #expect(!pending)
    }

    @Test("The note only allows replacing a trait that was already there when asking")
    func mayReplace() {
        let note = JoinNote(keychain)
        note.rememberRequest("abc", forItem: asking)
        #expect(note.mayReplace(nil))
        #expect(!note.mayReplace("PRUEF-merkmal-neu"))
        note.rememberRequest("abc", forItem: asking, trait: "PRUEF-merkmal-alt")
        #expect(note.mayReplace("PRUEF-merkmal-alt"))
        #expect(!note.mayReplace("PRUEF-merkmal-neu"))
        note.forgetRequest()
        #expect((try? keychain.value(for: "beitritt.anfragemerkmal")) == nil)
    }
}
