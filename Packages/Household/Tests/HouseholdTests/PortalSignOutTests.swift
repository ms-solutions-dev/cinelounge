import Core
import Foundation
import PortalKit
import ProfileKit
import Testing

@testable import Household

/// **A failure must not throw the credential away** (finding 2026-09-27, e1,
/// security).
///
/// The finding: ``PortalSignOut/notify(from:basis:session:keychain:ledgerStore:)`` threw
/// the server error away with `try?` and forgot the credential anyway — without a server address
/// even without any attempt. At the server the access stayed valid; locally it was forgotten, so
/// never revocable again. Now only a confirmed server sign-out counts as signing out.
@Suite("Portal sign-out: forget only after a confirmed server sign-out")
@MainActor
struct PortalSignOutTests {

    let keychain = InMemoryStore()
    let ledgers = InMemoryStore()

    @Test("Without a server address the trait stays, result: failed")
    func withoutAddressTraitStays() async {
        DeviceTrait.save("PRUEF-merkmal-code", to: keychain)
        JoinNote(keychain).rememberRequest("abc", forItem: Profile.Identifier(rawValue: UUID().uuidString))

        let result = await PortalSignOut.notify(
            from: false, basis: nil, session: FakeConsole.session,
            keychain: keychain, ledgerStore: ledgers)

        #expect(result == .failed)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-code")
        #expect(JoinNote(keychain).openRequest != nil)
    }

    @Test("If the server sign-out fails, the trait stays, result: failed")
    func failedServerSignOutKeepsTrait() async {
        DeviceTrait.save("PRUEF-merkmal-code", to: keychain)
        // No `/logout` route set up — the console reports a network error,
        // just like a silent or refusing server.
        let line = FakeConsole.setUp([:])

        let result = await PortalSignOut.notify(
            from: false, basis: line.basis, session: FakeConsole.session,
            keychain: keychain, ledgerStore: ledgers)

        #expect(result == .failed)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-code")
    }

    @Test("Without a trait there is nothing to revoke — result: signed out, without a request")
    func withoutTraitCountsAsSignedOut() async {
        let result = await PortalSignOut.notify(
            from: false, basis: nil, session: FakeConsole.session,
            keychain: keychain, ledgerStore: ledgers)

        #expect(result == .signedOut)
    }

    @Test("A successful server sign-out forgets the trait — result: signed out")
    func successfulSignOutForgetsTrait() async {
        DeviceTrait.save("PRUEF-merkmal-code", to: keychain)
        let line = FakeConsole.setUp(["/logout": (200, Data("{}".utf8))])

        let result = await PortalSignOut.notify(
            from: false, basis: line.basis, session: FakeConsole.session,
            keychain: keychain, ledgerStore: ledgers)

        #expect(result == .signedOut)
        #expect(DeviceTrait.load(from: keychain) == nil)
    }

    @Test("A borrowed profile never touches the trait — result: geliehenZurueckgegeben")
    func borrowedProfileLeavesTraitAlone() async {
        DeviceTrait.save("PRUEF-merkmal-code", to: keychain)
        DeviceTrait.saveProfile("selin", to: keychain)

        let result = await PortalSignOut.notify(
            from: true, basis: nil, session: FakeConsole.session,
            keychain: keychain, ledgerStore: ledgers)

        #expect(result == .borrowedReturned)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-code")
        #expect(DeviceTrait.profile(from: keychain) == nil)
    }
}
