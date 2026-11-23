import CloudSync
import Core
import Foundation
import ParentalControls
import Testing

@testable import ProfileKit

/// **Move note, expiry, revocation, move bundle, open profile requests** — the new
/// paths from strand C2 (cross-check of strand C, 2026-09-25), each on its own connection.
@Suite("Move note and tombstone (C2)")
@MainActor
struct MoveNoteTests {

    let server = MockCloud()

    static let lowercased = Profile.Identifier(rawValue: "00000000-0000-4000-8000-000000000001")
    static let large = Profile.Identifier(rawValue: "FFFFFFFF-0000-4000-8000-000000000002")

    func device(
        _ name: String, sharedStore: InMemoryStore? = nil
    ) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max", name: name), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: store, moveBundle: sharedStore, automatic: false)
        cloud.startStore = nil
        return (cloud, store)
    }

    func create(_ profile: Profile, in store: InMemoryStore) {
        var ledger = ProfileBook.read(from: store)
        ledger.create(profile)
        ledger.write(in: store)
    }

    func state(_ location: Double, forItem identifier: Profile.Identifier, in store: any KeyValueStore) {
        var ledger = StillLedger.read(from: store, forItem: identifier.rawValue)
        ledger.record(.titlePosition(title: "film", location: location, duration: 7200))
        ledger.write(in: store, forItem: identifier.rawValue)
    }

    func location(_ identifier: Profile.Identifier, _ store: any KeyValueStore) -> Double? {
        StillLedger.read(from: store, forItem: identifier.rawValue).state.titlePositions["film"]?.location
    }

    // MARK: - Befund 5: der Umzugsbund

    /// **Without a marker store, with a move bundle** — the way the iPhone is connected after C2.
    /// Until C2 the move hung on ``ProfileCloud/brandStore``, and on the iPhone PIN and
    /// age limit stayed lying under the dead identifier.
    @Test("First contact moves PIN, age limit and preferences over via the move bundle")
    func moveBundle() {
        let sharedStore = InMemoryStore()
        let (cloud, store) = device("telefon", sharedStore: sharedStore)
        #expect(cloud.brandStore == nil)
        create(Profile(identifier: Self.large, name: "Selin"), in: store)
        ProfilePIN(store: sharedStore, forItem: Self.large).set("4711", now: Date())
        AgeLimit.write(.from12, in: sharedStore, forItem: Self.large.rawValue)

        cloud.adopt([Profile(identifier: Self.lowercased, name: "Selin")])

        #expect(ProfilePIN(store: sharedStore, forItem: Self.lowercased).matches("4711"))
        #expect(!ProfilePIN(store: sharedStore, forItem: Self.large).isSet)
        #expect(AgeLimit.read(from: sharedStore, forItem: Self.lowercased.rawValue) == .from12)
    }

    // MARK: - Nachziehen

    @Test("Catching up: source in the book, target unknown — the source gets the target's identifier")
    func followUpRename() {
        let store = InMemoryStore()
        let source = Profile(name: "Papa", color: .moss)
        create(Profile(name: "Oma"), in: store)
        create(source, in: store)
        var ledger = ProfileBook.read(from: store)
        ledger.switchTo(zu: source.identifier)
        ledger.write(in: store)
        state(500, forItem: source.identifier, in: store)
        let target = Profile.Identifier.fresh()

        let migrated = ProfileMove.episode(
            [.init(identifier: source.identifier, target: target, datum: Date())], ledgerStore: store,
            keychain: nil, startStore: nil)

        #expect(migrated == [source.identifier])
        let after = ProfileBook.read(from: store)
        #expect(after.profile.map(\.name) == ["Oma", "Papa"], "the order stays")
        #expect(after.profile.last?.identifier == target)
        #expect(after.profile.last?.color == .moss)
        #expect(after.active == target, "whoever was active in the source is active in the target")
        #expect(location(target, store) == 500)
        // A second run does nothing more.
        #expect(
            ProfileMove.episode(
                [.init(identifier: source.identifier, target: target, datum: Date())], ledgerStore: store,
                keychain: nil, startStore: nil
            ).isEmpty)
    }

    /// **Since the final check the cycle resolves at the winner** (C2-2): Until then
    /// X and Y both stayed, and two devices stayed split with one identifier each.
    @Test("Catching up: chains are followed to the end, cycles at the winner, notes without a target never")
    func followUpChains() {
        let store = InMemoryStore()
        let a = Profile(name: "A")
        let b = Profile.Identifier.fresh()
        let c = Profile(name: "C")
        let route = Profile(name: "Weg")
        let x = Profile(name: "X")
        let y = Profile(name: "Y")
        for p in [a, c, route, x, y] { create(p, in: store) }
        let now = Date()

        ProfileMove.episode(
            [
                .init(identifier: a.identifier, target: b, datum: now),
                .init(identifier: b, target: c.identifier, datum: now),
                .init(identifier: route.identifier, datum: now),
                .init(identifier: x.identifier, target: y.identifier, datum: now),
                .init(identifier: y.identifier, target: x.identifier, datum: now),
            ], ledgerStore: store, keychain: nil, startStore: nil)

        let names = ProfileBook.read(from: store).profile.map(\.name)
        #expect(!names.contains("A"), "A merges via B into C")
        #expect(names.contains("C"))
        #expect(names.contains("Weg"), "a note without a target takes nobody's profile")
        let winner = ProfileSync.wins(x.identifier, about: y.identifier) ? "X" : "Y"
        #expect(names.filter { $0 == "X" || $0 == "Y" } == [winner], "a cycle moves to the winner")
    }

    @Test("Catching up without a cloud at startup: the crash after the book is completed")
    func followUpAtStartup() {
        let store = InMemoryStore()
        let sharedStore = InMemoryStore()
        let papa = Profile(name: "Papa")
        let max = Profile(name: "Max")
        create(max, in: store)
        state(900, forItem: papa.identifier, in: store)
        ProfilePIN(store: sharedStore, forItem: papa.identifier).set("1234", now: Date())
        ProfileTombstone.create(papa.identifier, target: max.identifier, in: store)

        ProfileMove.episode(
            ProfileTombstone.all(from: store), ledgerStore: store, keychain: sharedStore,
            startStore: nil)

        #expect(location(max.identifier, store) == 900)
        #expect(ProfilePIN(store: sharedStore, forItem: max.identifier).matches("1234"))
    }

    @Test("After the merge the profile has a journal without duplicate events")
    func journalMerged() {
        let a = StillLedgerEntry(
            event: .titlePosition(title: "x", location: 5, duration: nil),
            time: Date(timeIntervalSince1970: 1))
        let b = StillLedgerEntry(
            event: .titlePosition(title: "x", location: 5, duration: nil),
            time: Date(timeIntervalSince1970: 2))
        #expect(ProfileMove.post([a, b], [a]) == [a, b], "equal is event and time")
        #expect(ProfileMove.post([b], [a]) == [a, b], "by time")
    }

    // MARK: - Befund 8: Verfall und Aufhebung

    /// **Since the final check (C2-3) against the server clock:** The first startup after the
    /// expiry writes the clock record, only the next one has the proof and clears.
    @Test("An expired tombstone goes together with the dead zone, a fresh one does not")
    func expiry() async {
        let tv = device("fernseher")
        let grandmother = Profile(name: "Oma")
        create(Profile(name: "Max"), in: tv.store)
        create(grandmother, in: tv.store)
        let then = Date()
        server.clock = then
        await tv.cloud.syncAll()
        var ledger = ProfileBook.read(from: tv.store)
        ledger.remove(grandmother.identifier)
        ledger.write(in: tv.store)
        tv.cloud.bury(grandmother.identifier, now: then)
        await tv.cloud.household()?.reconcile()
        let grandmaZone = {
            self.server.zoneList().contains {
                $0.name.hasSuffix(grandmother.identifier.rawValue.lowercased())
            }
        }

        // After 179 days it applies.
        #expect(await tv.cloud.find(now: then.addingTimeInterval(179 * 86_400)).isEmpty)
        #expect(grandmaZone())

        // After 181 days it is gone — and the zone with it, otherwise the grandparent's profile would come back.
        let later = then.addingTimeInterval(181 * 86_400)
        server.clock = later
        #expect(await tv.cloud.find(now: later).isEmpty, "Oma came back after expiry")
        await tv.cloud.household()?.reconcile()
        #expect(grandmaZone(), "without server proof the zone stays")
        #expect(await tv.cloud.find(now: later).isEmpty, "Oma came back after expiry")
        await tv.cloud.household()?.reconcile()
        #expect(!grandmaZone())
        #expect(ProfileTombstone.all(from: tv.store).isEmpty)
        let stillRemote = ProfileTombstone.entries(
            from: tv.cloud.household()?.read(ProfileTombstone.contentType) ?? [])
        #expect(stillRemote.isEmpty)
    }

    @Test("A note from before expiry gets stamped and then expires too")
    func oldFormat() throws {
        let store = InMemoryStore()
        let old = Profile.Identifier.fresh()
        try store.set("[{\"kennung\":\"\(old.rawValue)\"}]", for: ProfileTombstone.key)
        let now = Date()
        #expect(ProfileTombstone.cleanUp(now: now, in: store).isEmpty)
        #expect(ProfileTombstone.all(from: store).first?.datum == now)
        #expect(
            ProfileTombstone.cleanUp(now: now.addingTimeInterval(181 * 86_400), in: store).map(
                \.identifier) == [old])
    }

    /// **Revoked as a record and not as a deletion.** A device that still keeps the note on
    /// the device would write it upward again after a deletion on the next ``ProfileCloud/find(now:)``
    /// — and the restored profile would disappear from all devices again.
    @Test(
        "Lifting writes a record, and another device does not write the old note back up")
    func lift() async {
        let tv = device("fernseher")
        let grandmother = Profile(name: "Oma")
        create(Profile(name: "Max"), in: tv.store)
        create(grandmother, in: tv.store)
        await tv.cloud.syncAll()

        // The phone removed the grandparent's profile, the note is there on the device and up above.
        let phone = device("telefon")
        let then = Date().addingTimeInterval(-3600)
        phone.cloud.bury(grandmother.identifier, now: then)
        await phone.cloud.household()?.reconcile()

        // The TV explicitly restores the grandparent's profile.
        await tv.cloud.household()?.reconcile()
        tv.cloud.liftTombstone(grandmother.identifier)
        await tv.cloud.household()?.reconcile()
        #expect(
            tv.cloud.household()?.read(ProfileTombstone.contentType).first?[ProfileTombstone.liftedField]?
                .bool == true)

        // The phone finds it again and does not put its old note back.
        await phone.cloud.household()?.reconcile()
        #expect(await phone.cloud.find().contains { $0.identifier == grandmother.identifier })
        #expect(ProfileTombstone.all(from: phone.store).isEmpty, "the older note on the device drops")
        await phone.cloud.household()?.reconcile()
        let third = device("dritte")
        #expect(await third.cloud.find().contains { $0.identifier == grandmother.identifier })
    }

    // MARK: - Finding 6: open profile requests and the notification

    @Test("A request for a profile PIN reaches the other device and appears in the list")
    func openProfileRecoveries() async {
        server.clock = Date(timeIntervalSince1970: 1_758_400_000)
        let tv = device("fernseher")
        let childProfile = Profile.Identifier.fresh()
        tv.cloud.requestPinRecovery(forItem: .profile(childProfile), device: "Wohnzimmer")
        tv.cloud.requestPinRecovery(forItem: .parentalControls, device: "Wohnzimmer")
        await tv.cloud.household()?.reconcile()

        let phone = device("telefon")
        var reported = 0
        phone.cloud.pinEscape = { reported += 1 }
        await phone.cloud.household()?.reconcile()

        #expect(reported > 0, "the request does not wake the other device")
        #expect(Array(phone.cloud.openProfileRecoveries().keys) == [childProfile], "profile requests only")
        #expect(Array(tv.cloud.openProfileRecoveries().keys) == [childProfile])

        phone.cloud.cancelPinRecovery(forItem: .profile(childProfile))
        #expect(phone.cloud.openProfileRecoveries().isEmpty)
        await phone.cloud.household()?.reconcile()
        await tv.cloud.household()?.reconcile()
        #expect(tv.cloud.openProfileRecoveries().isEmpty, "the cancellation does not reach the TV")
    }

    @Test("The name of a profile request reads back")
    func requestName() {
        let k = Profile.Identifier.fresh()
        #expect(PINFallback.profile(fromName: PINFallback.name(forItem: .profile(k))) == k)
        #expect(PINFallback.profile(fromName: PINFallback.name(forItem: .parentalControls)) == nil)
        #expect(PINFallback.profile(fromName: "profil-") == nil)
    }
}
