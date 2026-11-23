import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// **The new paths of the final review of 2026-09-25** — the parts that did not exist
/// before and could therefore not compile in the red run (``didClearSession``,
/// ``ProfileCloud/arrived``, the clock record).
@Suite("Final check: new paths")
@MainActor
struct FinalCheckNewPathsTests {

    let server = MockCloud()

    @Test("N-1: The result says the session was emptied")
    func sessionClearedReported() throws {
        try ProfilePointer.als(nil) {
            let sharedStore = SecureStore(service: "abschluss.\(UUID().uuidString)")
            defer { try? sharedStore.clearCredentials() }
            let address = URL(string: "https://jf.example")!
            try sharedStore.memorize(
                ServerCredentials(serverURL: address, userID: "papa", username: "Papa", accessToken: "m"))
            try sharedStore.switchTo(server: address, user: "papa")
            var papa = Profile(name: "Papa")
            papa.create(.jellyfin(server: address, userID: "papa", username: "Papa"))
            let without = Profile(name: "Gast")
            var ledger = ProfileBook()
            ledger.create(papa)
            ledger.create(without)
            ledger.switchTo(zu: papa.identifier)

            let hin = try #require(
                ProfileSwitch.switchTo(
                    zu: without.identifier, in: &ledger, keychain: sharedStore,
                    deviceStore: InMemoryStore(), ledgerStore: InMemoryStore()
                ).result)
            #expect(hin.didClearSession)
            let back = try #require(
                ProfileSwitch.switchTo(
                    zu: papa.identifier, in: &ledger, keychain: sharedStore,
                    deviceStore: InMemoryStore(), ledgerStore: InMemoryStore()
                ).result)
            #expect(!back.didClearSession)
        }
    }

    /// **The connection C2-5 hinged on:** A move note from remote reports itself without
    /// anyone having connected ``ProfileCloud/arrival``.
    @Test("C2-5: A remote move note reports itself without a connected callback")
    func remoteMoveReportsIn() async {
        func device(_ name: String) -> (ProfileCloud, InMemoryStore) {
            let store = InMemoryStore()
            let hub = CloudHub(
                service: server.credential("max", name: name), file: nil,
                device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
            let cloud = ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false)
            cloud.startStore = nil
            return (cloud, store)
        }
        let a = Profile(name: "Selin")
        let b = Profile(name: "Selin Kind", kind: .kind)
        let (tv, ablageTV) = device("fernseher")
        var ledger = ProfileBook()
        ledger.create(a)
        ledger.create(b)
        ledger.switchTo(zu: a.identifier)
        ledger.write(in: ablageTV)
        _ = tv.household()

        let reported = TallyCounter()
        let observers = NotificationCenter.default.addObserver(
            forName: ProfileCloud.arrived, object: nil, queue: nil
        ) { _ in reported.tally() }
        defer { NotificationCenter.default.removeObserver(observers) }

        let (phone, _) = device("telefon")
        phone.bury(a.identifier, target: b.identifier)
        await phone.household()?.reconcile()
        await tv.household()?.reconcile()

        #expect(ProfileBook.read(from: ablageTV).active == b.identifier)
        #expect(reported.value > 0, "UI and rule switch over only later")
    }

    @Test("C2-3: The server date beats that of the writing device")
    func serverDateBeatsDevice() {
        let now = Date()
        let postponed = ProfileTombstone.ContentEntryRecord(
            identifier: .fresh(), datum: now.addingTimeInterval(-365 * 86_400), serverTime: now)
        #expect(!postponed.expired(now: now.addingTimeInterval(86_400)))
        #expect(!ProfileTombstone.isOldEnough(postponed, serverClock: now.addingTimeInterval(86_400)))
        #expect(
            ProfileTombstone.isOldEnough(postponed, serverClock: now.addingTimeInterval(181 * 86_400))
        )
        #expect(!ProfileTombstone.isOldEnough(postponed, serverClock: nil))
    }

    @Test("C2-3: The clock record is not a note")
    func clockRecordIsNoNote() {
        var message = ProfileTombstone.clockRecord()
        message.serverTime = Date()
        #expect(ProfileTombstone.entries(from: [message]).isEmpty)
        #expect(ProfileTombstone.serverClock(from: [message]) == message.serverTime)
    }
}
