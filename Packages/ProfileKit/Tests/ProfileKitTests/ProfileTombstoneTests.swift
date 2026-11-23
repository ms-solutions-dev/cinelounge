import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// **B5: A removed profile does not come back from iCloud** (AP43, 2026-09-25).
///
/// Two devices of the same Apple ID against the ``CloudSync/MockCloud``. The tests target
/// ``ProfileCloud/find()`` and ``ProfileCloud/download(_:)`` — the two paths by which
/// a profile gets into the ledger without anyone creating it.
@Suite("Tombstones: a removed profile stays gone")
@MainActor
struct ProfileTombstoneTests {

    let server = MockCloud()

    func device(_ name: String) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false)
        cloud.startStore = nil
        return (cloud, store)
    }

    func create(_ profile: Profile, in store: InMemoryStore) {
        var ledger = ProfileBook.read(from: store)
        ledger.create(profile)
        ledger.write(in: store)
    }

    func remove(_ identifier: Profile.Identifier, from store: InMemoryStore) {
        var ledger = ProfileBook.read(from: store)
        ledger.remove(identifier)
        ledger.write(in: store)
    }

    /// A profile that is up there: created on the TV and reconciled once.
    func remoteExisting(
        on tv: (cloud: ProfileCloud, store: InMemoryStore), name: String = "Oma"
    ) async -> Profile {
        let profile = Profile(name: name, color: .moss)
        create(Profile(name: "Max"), in: tv.store)
        create(profile, in: tv.store)
        await tv.cloud.syncAll()
        return profile
    }

    @Test("Without a tombstone a removed profile comes back — the finding")
    func finding() async {
        let tv = device("fernseher")
        let grandmother = await remoteExisting(on: tv)
        remove(grandmother.identifier, from: tv.store)

        let found = await tv.cloud.find()
        #expect(found.map(\.identifier) == [grandmother.identifier], "this is how it came back until today")
    }

    @Test("With a tombstone neither this device nor another on the same Apple ID finds it")
    func twoDevices() async throws {
        let tv = device("fernseher")
        let grandmother = await remoteExisting(on: tv)
        remove(grandmother.identifier, from: tv.store)
        tv.cloud.bury(grandmother.identifier)

        // **No `find()` on the TV before the sync pass** — it would write the device's own note
        // upward and obscure whether ``ProfileCloud/bury(_:target:now:)`` does it.
        await tv.cloud.household()?.reconcile()

        let phone = device("telefon")
        let found = await phone.cloud.find()
        #expect(await tv.cloud.find().isEmpty)
        #expect(
            !found.contains { $0.identifier == grandmother.identifier },
            "the phone fetches the removed profile back from iCloud")
        #expect(found.contains { $0.name == "Max" }, "a living profile is still found")
        // The zone itself stays — see ``ProfileTombstone``.
        #expect(
            server.zoneList().contains { $0.name.hasSuffix(grandmother.identifier.rawValue.lowercased()) })
    }

    @Test("What is noted only on the device goes up when finding")
    func removedWithoutCloud() async {
        let tv = device("fernseher")
        let grandmother = await remoteExisting(on: tv)
        remove(grandmother.identifier, from: tv.store)
        // Removed when there was no Apple account yet — only the note on the device.
        ProfileTombstone.create(grandmother.identifier, in: tv.store)

        #expect(await tv.cloud.find().isEmpty)
        await tv.cloud.household()?.reconcile()

        let phone = device("telefon")
        #expect(!(await phone.cloud.find()).contains { $0.identifier == grandmother.identifier })
    }

    @Test("A push from a device that still has the profile does not put it back into the book")
    func remotePush() async throws {
        let tv = device("fernseher")
        let grandmother = await remoteExisting(on: tv)

        // The phone still has the grandparent's profile — for example with an older version.
        let phone = device("telefon")
        create(grandmother, in: phone.store)
        await phone.cloud.reconcile(grandmother)

        remove(grandmother.identifier, from: tv.store)
        tv.cloud.bury(grandmother.identifier)

        var state = StillLedger.read(from: phone.store, forItem: grandmother.identifier.rawValue)
        state.record(.titlePosition(title: "film", location: 100, duration: 1000))
        state.write(in: phone.store, forItem: grandmother.identifier.rawValue)
        await phone.cloud.reconcile(grandmother)

        // The zone is up again on the TV — after a restart from the mirror file,
        // or because a view asks for it —, and the silent push pulls it down. This is
        // the path via observation, not a manual call.
        await tv.cloud.zone(forItem: grandmother.identifier)?.reconcile()
        #expect(
            !ProfileBook.read(from: tv.store).profile.contains { $0.identifier == grandmother.identifier },
            "the push put the removed profile back into the book")
        // On the phone, where it still exists, it keeps being reconciled.
        #expect(
            ProfileBook.read(from: phone.store).profile.contains { $0.identifier == grandmother.identifier })
    }

    @Test("An explicitly restored profile counts again")
    func retrieved() async {
        let tv = device("fernseher")
        let grandmother = await remoteExisting(on: tv)
        remove(grandmother.identifier, from: tv.store)
        tv.cloud.bury(grandmother.identifier)

        tv.cloud.liftTombstone(grandmother.identifier)
        #expect(ProfileTombstone.all(from: tv.store).isEmpty)
        #expect(await tv.cloud.find().map(\.identifier) == [grandmother.identifier])
    }

    @Test("The spelling of the identifier does not separate")
    func spelling() {
        let lowercased = Profile.Identifier(rawValue: "0f8c2a3e-1111-4222-8333-944455556666")
        let large = Profile.Identifier(rawValue: lowercased.rawValue.uppercased())
        #expect(ProfileCloud.norm(lowercased) == ProfileCloud.norm(large))
    }

    @Test("Device notes: put, replace, lift")
    func deviceNote() {
        let store = InMemoryStore()
        let a = Profile.Identifier.fresh()
        let b = Profile.Identifier.fresh()
        ProfileTombstone.create(a, in: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ProfileTombstone.create(a, target: b, now: now, in: store)
        #expect(ProfileTombstone.all(from: store) == [.init(identifier: a, target: b, datum: now)])
        ProfileTombstone.lift(a, in: store)
        #expect(ProfileTombstone.all(from: store).isEmpty)
        #expect((try? store.value(for: ProfileTombstone.key)) == nil)
    }

    @Test("The record carries the target and reads back")
    func record() {
        let entry = ProfileTombstone.ContentEntryRecord(
            identifier: .fresh(), target: .fresh(), datum: Date(timeIntervalSince1970: 1_800_000_000))
        let foreign = CloudRecord(contentType: "Pinruecksetzung", name: "aktuell", fields: [:])
        #expect(
            ProfileTombstone.entries(from: [ProfileTombstone.message(forItem: entry), foreign])
                == [entry])
    }
}
