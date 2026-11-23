import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// **Deleted iCloud data stays deleted** — on-device test build 1332, finding 10.
///
/// The owner had deleted the app's data in the iOS settings, and the profile
/// was still there: The next sync pass recreated the zone and wrote everything upward again.
@Suite("Finding 10 · Delete iCloud data")
@MainActor
struct CloudDeletionTests {

    let server = MockCloud()
    let identifier = Profile.Identifier(rawValue: UUID().uuidString)

    func device(_ name: String) -> (ProfileCloud, InMemoryStore, InMemoryStore) {
        let store = InMemoryStore()
        let keychain = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: store, moveBundle: keychain, automatic: false)
        return (cloud, store, keychain)
    }

    func create(_ profile: Profile, in store: InMemoryStore) {
        var ledger = ProfileBook.read(from: store)
        ledger.create(profile)
        ledger.write(in: store)
    }

    /// Two devices of the same Apple ID, both reconciled, with state and PIN.
    func twoDevices() async -> (
        tv: (ProfileCloud, InMemoryStore, InMemoryStore),
        phone: (ProfileCloud, InMemoryStore, InMemoryStore)
    ) {
        let tv = device("tv")
        let person = Profile(identifier: identifier, name: "Test", color: .turquoise)
        create(person, in: tv.1)
        var state = StillLedger.read(from: tv.1, forItem: identifier.rawValue)
        state.record(.senderfavorit(key: "das erste hd", true))
        state.write(in: tv.1, forItem: identifier.rawValue)
        await tv.0.syncAll()
        tv.0.requestPinRecovery(forItem: .profile(identifier), device: "tv")
        await tv.0.household()?.reconcile()

        let phone = device("telefon")
        create(Profile(identifier: identifier, name: "Test", color: .turquoise), in: phone.1)
        await phone.0.syncAll()
        await phone.0.household()?.reconcile()
        #expect(server.zoneList().count == 2, "profile zone and household")
        return (tv, phone)
    }

    /// **The control test against the old code:** Another device deletes the zones, this one
    /// sees only `zoneNotFound` — and until today recreated them with its state.
    @Test("Another device deletes the zones — this one does not revive them and clears the profile")
    func fromRemote() async throws {
        let (tv, _) = await twoDevices()
        for zone in try await server.credential("max").zones(shared: false) {
            try await server.credential("max").delete(zone)
        }
        await tv.0.syncAll()
        await tv.0.household()?.reconcile()
        #expect(server.zoneList().isEmpty, "nothing revived")
        #expect(ProfileBook.read(from: tv.1).profile.isEmpty, "the profile is cleared on the device")
        #expect(StillLedger.read(from: tv.1, forItem: identifier.rawValue).state == StateRecording())
        #expect(tv.0.household()?.read(PINFallback.contentType).isEmpty == true)
    }

    @Test("Deleted in iOS Settings: the profile does not stay, nothing goes back up")
    func byUser() async {
        let (tv, _) = await twoDevices()
        for zone in server.zoneList() {
            server.deleteByUser(ZoneID(name: zone.name), user: "max")
        }
        await tv.0.syncAll()
        await tv.0.household()?.reconcile()
        #expect(server.zoneList().isEmpty)
        #expect(ProfileBook.read(from: tv.1).profile.isEmpty)
        // Another sync pass stays silent.
        await tv.0.syncAll()
        #expect(server.zoneList().isEmpty)
    }

    /// "Delete all my iCloud data" in the app: the zones gone, this device cleared —
    /// and the other device also clears on the next sync pass instead of reviving.
    @Test("Delete all iCloud data: zones gone, cleared here, the other device follows")
    func deleteAll() async throws {
        let (tv, phone) = await twoDevices()
        _ = ProfilePIN(store: phone.2, forItem: identifier).set("1234", now: Date())
        #expect(ProfilePIN(store: phone.2, forItem: identifier).isSet)
        ProfileTombstone.create(Profile.Identifier(rawValue: UUID().uuidString), in: phone.1)

        let deleted = try await phone.0.deleteAllCloudData()
        #expect(ProfileTombstone.all(from: phone.1).isEmpty, "no tombstone goes back up")
        #expect(deleted == 2)
        #expect(server.zoneList().isEmpty)
        #expect(ProfileBook.read(from: phone.1).profile.isEmpty)
        #expect(!ProfilePIN(store: phone.2, forItem: identifier).isSet, "the PIN on the device too")

        // The phone keeps reconciling — without a profile no profile zone is recreated.
        await phone.0.syncAll()
        #expect(server.zoneList().isEmpty)

        await tv.0.syncAll()
        await tv.0.household()?.reconcile()
        #expect(server.zoneList().isEmpty, "the TV revives nothing")
        #expect(ProfileBook.read(from: tv.1).profile.isEmpty)
    }

    /// After deleting, things continue normally: A new profile gets a new zone.
    @Test("Afterwards a new profile is created as the first time")
    func newAfterwards() async throws {
        let (_, phone) = await twoDevices()
        try await phone.0.deleteAllCloudData()
        let fresh = Profile(identifier: Profile.Identifier(rawValue: UUID().uuidString), name: "Neu")
        create(fresh, in: phone.1)
        await phone.0.syncAll()
        #expect(server.zoneList().count == 1)
    }
}
