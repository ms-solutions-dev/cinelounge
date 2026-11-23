import Core
import Foundation
import ProfileKit
import Testing

@testable import Household

/// **A switcher** (AP45, 2026-09-25): The person choice in Settings → Portals is an
/// assignment to the active profile — switching only happens in "Who's watching?". Shared
/// since AP58 R7: The TV borrows, the phone only records after sign-in.
@MainActor
@Suite("The server person belongs to the profile")
struct PortalAssignmentTests {

    @Test("The chosen person is in the active profile, and the switch sets the head from it")
    func assignment() throws {
        ProfilePointer.als(nil) {
            let ledger = InMemoryStore()
            let sharedStore = SecureStore(service: "probe.\(UUID().uuidString)")
            var start = ProfileBook()
            let max = Profile(name: "Max")
            let grandmother = Profile(name: "Oma")
            start.create(max)
            start.create(grandmother)
            start.switchTo(zu: grandmother.identifier)
            start.write(in: ledger)

            #expect(PortalAssignment.borrow("oma-am-server", ledgerStore: ledger, keychain: sharedStore))
            #expect(ProfileBook.read(from: ledger).activeProfile?.portalPerson == "oma-am-server")
            #expect(DeviceTrait.profile(from: sharedStore) == "oma-am-server")

            // Switch to a profile without a person: The header drops.
            var read = ProfileBook.read(from: ledger)
            _ = ProfileSwitch.switchTo(
                zu: max.identifier, in: &read, keychain: sharedStore, deviceStore: sharedStore,
                ledgerStore: ledger)
            #expect(DeviceTrait.profile(from: sharedStore) == nil)

            // And back: It comes from the profile without anyone choosing in the settings.
            _ = ProfileSwitch.switchTo(
                zu: grandmother.identifier, in: &read, keychain: sharedStore, deviceStore: sharedStore,
                ledgerStore: ledger)
            #expect(
                DeviceTrait.profile(from: sharedStore) == "oma-am-server",
                "the person was attached to the device and not to the profile — the old second switcher")
        }
    }

    @Test("Without a profile nothing is assigned")
    func withoutProfile() {
        let sharedStore = SecureStore(service: "probe.\(UUID().uuidString)")
        #expect(!PortalAssignment.borrow("x", ledgerStore: InMemoryStore(), keychain: sharedStore))
        #expect(DeviceTrait.profile(from: sharedStore) == nil, "without a profile no head either")
    }

    /// **The phone's path:** it is already signed in (own), only the person is
    /// recorded — without a borrowed header, otherwise the next switch would turn the phone's own
    /// sign-in into a borrowed one.
    @Test("The assignment without a loan only writes into the profile")
    func onlyRecord() {
        let ledger = InMemoryStore()
        let sharedStore = SecureStore(service: "probe.\(UUID().uuidString)")
        var start = ProfileBook()
        let max = Profile(name: "Max")
        start.create(max)
        start.switchTo(zu: max.identifier)
        start.write(in: ledger)
        DeviceTrait.saveOwn(true, to: sharedStore)

        #expect(PortalAssignment.assign("max-am-server", ledgerStore: ledger))
        #expect(ProfileBook.read(from: ledger).activeProfile?.portalPerson == "max-am-server")
        #expect(DeviceTrait.profile(from: sharedStore) == nil)
        #expect(DeviceTrait.own(in: sharedStore))
    }

    /// **Finding, test Apple TV, 2026-09-28:** Code redeemed, server knew device and person, and
    /// the app did nothing — the profile carried no CL-Server access.
    @Test("After redeeming, the active profile wants the CL-Server")
    func afterRedemption() {
        ProfilePointer.als(nil) {
            let ledger = InMemoryStore()
            var start = ProfileBook()
            let fresh = Profile(name: "Neu")
            start.create(fresh)
            start.switchTo(zu: fresh.identifier)
            start.write(in: ledger)
            #expect(ProfileBook.read(from: ledger).activeProfile?.wantsPortals == false)

            // Without a person: the access is there, the person is chosen afterwards.
            #expect(PortalAssignment.afterRedemption(person: nil, ledgerStore: ledger))
            #expect(ProfileBook.read(from: ledger).activeProfile?.wantsPortals == true)
            #expect(ProfileBook.read(from: ledger).activeProfile?.portalPerson == nil)

            // With a person: it is in the profile.
            #expect(PortalAssignment.afterRedemption(person: "max", ledgerStore: ledger))
            #expect(ProfileBook.read(from: ledger).activeProfile?.portalPerson == "max")

            // A new code without a person does not erase the choice.
            #expect(PortalAssignment.afterRedemption(person: nil, ledgerStore: ledger))
            #expect(ProfileBook.read(from: ledger).activeProfile?.portalPerson == "max")
        }
    }
}
