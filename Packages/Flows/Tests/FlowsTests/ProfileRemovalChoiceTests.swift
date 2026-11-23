import CloudSync
import Core
import Foundation
import PlaylistKit
import ProfileKit
import Testing

@testable import Flows

/// **A new profile is new** (on-device test build 1332, 2026-09-27, finding 1) and **removing
/// is a choice** — "from this device" or "everywhere" (owner requirement from the same evening).
///
/// Counter-checks (run against the code before the fix):
/// - without ``ProfileManagement/cleanUpLists(from:ledger:)`` ``listsFollow()`` turns red;
/// - without `created` at the call of `ProfileStates.adopt` in ``ProfileStartup``
///   ``baseOnlyOnCreation()`` turns red;
/// - without ``ProfileKit/ProfileHiding`` in `find()` ``hereOnly()`` turns red;
/// - without ``ProfileKit/ProfileCloud/deleteZone(_:)`` and `followDeletions` ``everywhere()`` turns red.
@MainActor
@Suite("Removing a profile: data goes with it, and how far it reaches")
struct ProfileRemovalChoiceTests {

    let server = MockCloud()

    func device(_ name: String) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("alex"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: store, moveBundle: nil, automatic: false)
        cloud.startStore = nil
        return (cloud, store)
    }

    func administration(
        _ store: InMemoryStore, cloud: ProfileCloud? = nil, listen: PlaylistStore? = nil
    ) -> ProfileManagement {
        ProfileManagement(
            keychain: SecureStore(service: "probe.\(UUID().uuidString)"), store: store,
            cloud: { cloud }, startStore: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!,
            deviceLists: { listen })
    }

    func zone(_ identifier: Profile.Identifier) -> Bool {
        server.zoneList().contains { $0.name.hasSuffix(identifier.rawValue.lowercased()) }
    }

    // MARK: - Finding 1: what stays on the device

    @Test("Removing clears the channel lists that only the departing profile carried")
    func listsFollow() throws {
        let store = InMemoryStore()
        let catalog = PlaylistStore(
            store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        for id in ["y-iptv", "shared"] {
            catalog.add(
                Playlist(
                    id: id, name: id,
                    kind: .xtream(server: URL(string: "http://anbieter.example")!, username: id)),
                password: "secret")
        }
        let v = administration(store, listen: catalog)
        try ProfilePointer.als(nil) {
            let legacy = try #require(v.create(name: "Alt", color: .turquoise, kind: .adult, avatar: nil))
            let parent = try #require(v.create(name: "Parent", color: .moss, kind: .adult, avatar: nil))
            var ledger = ProfileBook.read(from: store)
            ledger.update(legacy) {
                $0.create(.channelList(identifier: "y-iptv"))
                $0.create(.channelList(identifier: "shared"))
            }
            ledger.update(parent) { $0.create(.channelList(identifier: "shared")) }
            ledger.write(in: store)
            v.load()

            #expect(v.remove(legacy, mode: .hereOnly) == .removed)
            #expect(catalog.playlists.map(\.id) == ["shared"], "Y-IPTV stayed on the device")
            #expect(catalog.password(for: "y-iptv") == nil, "the password stayed in the Keychain")
        }
    }

    @Test("The device base goes into the profile only in the startup that creates the profiles")
    func baseOnlyOnCreation() throws {
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let ledger = InMemoryStore()
        let standard = UserDefaults(suiteName: "probe.\(UUID().uuidString)")!
        let credential = ServerCredentials(
            serverURL: URL(string: "https://media.example:8096")!, userID: "alex",
            username: "Alex", accessToken: "token")
        try secureStore.memorize(credential)
        try secureStore.saveCredentials(credential)
        var base = StillLedger()
        base.record(.titlePosition(title: "film", location: 4350, duration: 7200))
        base.write(in: ledger)
        func fetch() {
            ProfileStartup.fetch(
                .tv,
                device: .init(
                    channelLists: [], wantsPortals: false, fallbackName: "Home", version: "1.0"),
                keychain: secureStore, ledgerStore: ledger, startStore: standard, legacyStore: standard)
        }
        ProfilePointer.als(nil) { fetch() }
        var profile = ProfileBook.read(from: ledger)
        let first = try #require(profile.profile.first)
        #expect(StillLedger.read(from: ledger, forItem: first.identifier.rawValue) != StillLedger())

        // The old profile goes, a new one comes and sits in front of it.
        let fresh = Profile(name: "Neu")
        profile.create(fresh)
        profile.switchTo(zu: fresh.identifier)
        profile.remove(first.identifier)
        profile.write(in: ledger)
        StillLedger().write(in: ledger, forItem: first.identifier.rawValue)

        ProfilePointer.als(nil) { fetch() }
        #expect(
            StillLedger.read(from: ledger, forItem: fresh.identifier.rawValue) == StillLedger(),
            "the new profile inherited the favorites and movies from before the profiles")
    }

    // MARK: - The choice

    @Test("From this device: no tombstone, does not come back by itself, but can be fetched deliberately")
    func hereOnly() async throws {
        let tv = device("tv")
        let v = administration(tv.store, cloud: tv.cloud)
        try await ProfilePointer.als(nil) {
            _ = v.create(name: "Alex", color: .turquoise, kind: .adult, avatar: nil)
            let grandmother = try #require(v.create(name: "Grandma", color: .moss, kind: .adult, avatar: nil))
            await tv.cloud.syncAll()

            #expect(v.remove(grandmother, mode: .hereOnly) == .removed)
            #expect(ProfileTombstone.all(from: tv.store).isEmpty, "no tombstone")
            #expect(zone(grandmother), "the zone stays in iCloud")
            #expect(
                !(await tv.cloud.find()).contains { $0.identifier == grandmother },
                "the grandmother profile came back by itself at the next start")

            // On the phone of the same Apple ID it is still there.
            let phone = device("phone")
            #expect((await phone.cloud.find()).contains { $0.identifier == grandmother })

            // Deliberately brought back: "add existing profiles".
            let hidden = await v.hiddenProfiles()
            #expect(hidden.map(\.identifier) == [grandmother])
            v.restore(hidden)
            #expect(v.profile.contains { $0.identifier == grandmother })
            #expect(!ProfileHiding.contains(grandmother, in: tv.store))
        }
    }

    @Test("Everywhere: tombstone, the zone is gone at once, and the other device removes it")
    func everywhere() async throws {
        let tv = device("tv")
        let phone = device("phone")
        let v = administration(tv.store, cloud: tv.cloud)
        try await ProfilePointer.als(nil) {
            _ = v.create(name: "Alex", color: .turquoise, kind: .adult, avatar: nil)
            let grandmother = try #require(v.create(name: "Grandma", color: .moss, kind: .adult, avatar: nil))
            await tv.cloud.syncAll()
            // The phone already has another profile in the book.
            phone.cloud.adopt(await phone.cloud.find())
            #expect(ProfileBook.read(from: phone.store).profile.contains { $0.identifier == grandmother })

            #expect(v.remove(grandmother, mode: .everywhere) == .removed)
            await v.zoneDeletion?.value
            await tv.cloud.household()?.reconcile()
            #expect(!zone(grandmother), "the zone remained in iCloud")

            // The note arrives via the household zone (silent push), then one pass.
            await phone.cloud.household()?.reconcile()
            await phone.cloud.syncAll()
            #expect(
                !ProfileBook.read(from: phone.store).profile.contains { $0.identifier == grandmother },
                "the phone kept the profile deleted everywhere")
            #expect(!zone(grandmother), "the phone recreated the deleted zone")
        }
    }
}
