import CloudSync
import Core
import Foundation
import ParentalControls
import Testing

@testable import ProfileKit

/// **Carry out merging** (AP45, 2026-09-25) — two profiles into one, with logins,
/// state, preferences and picture, and the one that disappeared does not come back from iCloud.
@Suite("Two profiles into one")
@MainActor
struct ProfileMergeTests {

    let server = MockCloud()
    nonisolated static let jellyfin = URL(string: "https://vault.example:8096")!

    func device(_ name: String) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false)
        cloud.startStore = nil
        return (cloud, store)
    }

    /// Two profiles of the same person: "Parent" with Jellyfin server, state and picture, "Viewer A"
    /// with channel list and own state. Parent is active, Viewer A stays.
    @MainActor
    struct Situation {
        let papa: Profile
        let max: Profile
        let keychain = InMemoryStore()
        let startStore = UserDefaults(suiteName: "probe.\(UUID().uuidString)")!

        init(in store: InMemoryStore) {
            var papa = Profile(name: "Papa", color: .coral, avatar: "fuchs")
            papa.create(
                .jellyfin(
                    server: ProfileMergeTests.jellyfin, userID: "papa",
                    username: "Papa"))
            var max = Profile(name: "Max", color: .turquoise)
            max.create(.channelList(identifier: "iptv"))
            self.papa = papa
            self.max = max

            var ledger = ProfileBook()
            ledger.create(max)
            ledger.create(papa)
            ledger.switchTo(zu: papa.identifier)
            ledger.write(in: store)

            var legacyState = StillLedger()
            legacyState.record(.titlePosition(title: "film", location: 4000, duration: 7200))
            legacyState.record(.titlePosition(title: "nur-papa", location: 900, duration: 3000))
            legacyState.record(.senderfavorit(key: "iptv#ahorn", true))
            legacyState.write(in: store, forItem: papa.identifier.rawValue)

            var targetState = StillLedger()
            targetState.record(.titlePosition(title: "film", location: 1200, duration: 7200))
            targetState.record(.senderfavorit(key: "iptv#zinne", true))
            targetState.write(in: store, forItem: max.identifier.rawValue)

            ShelfOrder(order: ["weiter", "filme"]).write(
                in: store, forItem: papa.identifier.rawValue)
            try? ProfileStore(keychain, forItem: papa.identifier.rawValue)
                .set("de", for: ProfileStore.playbackKeys[0])
            ProfilePIN(store: keychain, forItem: papa.identifier).set("1234", now: Date())
            StartChoice(store: startStore).set(papa.identifier)
            ProfileSync.memorize(
                [ProfileSync.Pair(device: papa.identifier, cloud: max.identifier)], in: store)
        }
    }

    @Test("Without the protected profile's PIN nothing is merged")
    func pinRequired() {
        let store = InMemoryStore()
        let state = Situation(in: store)
        let outcome = ProfileMerge.perform(
            state.papa.identifier, in: state.max.identifier, ledgerStore: store,
            keychain: state.keychain, startStore: state.startStore, cloud: nil)
        #expect(outcome == .pinRequired(state.papa))
        #expect(ProfileBook.read(from: store).profile.count == 2, "nothing may change without the PIN")
        #expect(StillLedger.read(from: store, forItem: state.papa.identifier.rawValue) != StillLedger())
    }

    @Test("Credentials, state, preferences, image, PIN and start choice move to the surviving profile")
    func everything() throws {
        let store = InMemoryStore()
        let state = Situation(in: store)
        let outcome = ProfileMerge.perform(
            state.papa.identifier, in: state.max.identifier, pins: [state.papa.identifier: "1234"],
            ledgerStore: store, keychain: state.keychain,
            startStore: state.startStore, cloud: nil)
        guard case .merged(let combined, let wasActive) = outcome else {
            Issue.record("not merged: \(outcome)")
            return
        }
        #expect(wasActive)

        let ledger = ProfileBook.read(from: store)
        #expect(ledger.profile.map(\.identifier) == [state.max.identifier])
        #expect(ledger.active == state.max.identifier, "the viewer was in the vanished profile")
        #expect(combined.name == "Max")
        #expect(combined.color == .turquoise)
        #expect(combined.avatar == "fuchs", "the other's image, because Max chose none")
        #expect(combined.jellyfin == state.papa.jellyfin)
        #expect(combined.channelLists == state.max.channelLists)

        let status = StillLedger.read(from: store, forItem: state.max.identifier.rawValue).state
        #expect(status.titlePositions["film"]?.location == 1200, "on conflict the earlier position wins")
        #expect(status.titlePositions["nur-papa"]?.location == 900)
        #expect(status.channelFavorites == ["iptv#ahorn", "iptv#zinne"])
        #expect(StillLedger.read(from: store, forItem: state.papa.identifier.rawValue) == StillLedger())

        #expect(
            ShelfOrder.read(from: store, forItem: state.max.identifier.rawValue).order
                == ["weiter", "filme"])
        #expect(
            ProfileStore(state.keychain, forItem: state.max.identifier.rawValue).own()
                == [ProfileStore.playbackKeys[0]: "de"])
        #expect(ProfileStore(state.keychain, forItem: state.papa.identifier.rawValue).own().isEmpty)
        #expect(
            ProfilePIN(store: state.keychain, forItem: state.max.identifier).matches("1234"),
            "otherwise the history of a protected profile sits openly in the unprotected one")
        #expect(!ProfilePIN(store: state.keychain, forItem: state.papa.identifier).isSet)
        #expect(StartChoice(store: state.startStore).identifier == state.max.identifier)
        #expect(ProfileSync.openQuestions(from: store).isEmpty, "the question is answered")
        #expect(
            ProfileTombstone.all(from: store).map { [$0.identifier, $0.target] }
                == [[state.papa.identifier, state.max.identifier]])
    }

    /// **Same kind: the Jellyfin server of the one who stays.** Whoever chooses "merge into X"
    /// means X with everything X has.
    @Test("With two media servers of the same kind the survivor's one stays")
    func collision() {
        var remains = Profile(name: "Max")
        remains.create(.jellyfin(server: Self.jellyfin, userID: "max", username: "Max"))
        var leaving = Profile(name: "Papa")
        leaving.create(.jellyfin(server: Self.jellyfin, userID: "papa", username: "Papa"))
        leaving.create(.channelList(identifier: "iptv"))
        let combined = ProfileMerge.merge(leaving, in: remains)
        #expect(combined.jellyfin == remains.jellyfin)
        #expect(combined.channelLists.count == 1)
        #expect(combined.kind == .adult)
        #expect(combined.identifier == remains.identifier)
    }

    /// **Different kind: the Jellyfin server of the child** (finding 4 of the cross-check of strand C,
    /// owner's decision). The result is a child; with the adult's account
    /// it would see the adult's whole library.
    @Test("With different kinds the child's media server stays — in both directions")
    func childCollision() {
        var adult = Profile(name: "Max")
        adult.create(.jellyfin(server: Self.jellyfin, userID: "max", username: "Max"))
        adult.create(.channelList(identifier: "iptv"))
        var kind = Profile(name: "Selin", kind: .kind)
        kind.create(.jellyfin(server: Self.jellyfin, userID: "selin", username: "Selin"))

        let childLeaves = ProfileMerge.merge(kind, in: adult)
        #expect(childLeaves.kind == .kind)
        #expect(childLeaves.jellyfin == kind.jellyfin)
        #expect(childLeaves.identifier == adult.identifier)
        #expect(childLeaves.name == "Max")
        #expect(childLeaves.channelLists.count == 1)

        let childRemains = ProfileMerge.merge(adult, in: kind)
        #expect(childRemains.kind == .kind)
        #expect(childRemains.jellyfin == kind.jellyfin)
    }

    @Test("State: only a record that says something about watching counts for watching")
    func titlePosition() {
        typealias T = StateRecording.TitlePosition
        #expect(ProfileMove.merge(T(seen: true), T(location: 600)).location == 600)
        #expect(ProfileMove.merge(T(seen: true), T(location: 600)).seen == false)
        #expect(ProfileMove.merge(T(seen: true), T(favorite: true)).seen == true)
        #expect(ProfileMove.merge(T(favorite: true), T(seen: true)).seen == true)
        #expect(ProfileMove.merge(nil, T(location: 5)).location == 5)
    }

    /// A store that swallows the profile ledger.
    final class SwallowingStore: KeyValueStore, @unchecked Sendable {
        let inside = InMemoryStore()
        func value(for key: String) throws -> String { try inside.value(for: key) }
        func set(_ value: String, for key: String) throws {
            guard key != ProfileBook.key else { return }
            try inside.set(value, for: key)
        }
        func remove(_ key: String) throws { try inside.remove(key) }
    }

    @Test("If the book cannot be written, nothing moves")
    func failed() throws {
        let store = InMemoryStore()
        let state = Situation(in: store)
        let swallowing = SwallowingStore()
        for key in [
            ProfileBook.key, StillLedger.key(forItem: state.papa.identifier.rawValue),
        ] {
            try swallowing.inside.set(try store.value(for: key), for: key)
        }
        let outcome = ProfileMerge.perform(
            state.papa.identifier, in: state.max.identifier, pins: [state.papa.identifier: "1234"],
            ledgerStore: swallowing, keychain: state.keychain,
            startStore: state.startStore, cloud: nil)
        #expect(outcome == .impossible)
        #expect(StillLedger.read(from: swallowing, forItem: state.papa.identifier.rawValue) != StillLedger())
        #expect(ProfilePIN(store: state.keychain, forItem: state.papa.identifier).isSet)
    }

    @Test("Two devices: the vanished profile does not come back on the other via finde()")
    func cloud() async throws {
        let tv = device("fernseher")
        let state = Situation(in: tv.store)
        await tv.cloud.syncAll()

        let outcome = ProfileMerge.perform(
            state.papa.identifier, in: state.max.identifier, pins: [state.papa.identifier: "1234"],
            ledgerStore: tv.store, keychain: state.keychain,
            startStore: state.startStore, cloud: tv.cloud)
        guard case .merged = outcome else {
            Issue.record("not merged")
            return
        }
        await tv.cloud.household()?.reconcile()
        await tv.cloud.syncAll()

        let phone = device("telefon")
        let found = await phone.cloud.find()
        #expect(found.map(\.identifier) == [state.max.identifier], "Papa came back from iCloud")
        phone.cloud.adopt(found)
        let max = try #require(ProfileBook.read(from: phone.store).profile.first)
        await phone.cloud.reconcile(max)
        let status = StillLedger.read(from: phone.store, forItem: state.max.identifier.rawValue).state
        #expect(status.titlePositions["nur-papa"]?.location == 900, "the merged state was not uploaded")
        #expect(ProfileBook.read(from: phone.store).profile.first?.avatar == "fuchs")
    }

    /// **The first iCloud contact now moves everything, not only the marker.** The same
    /// "Viewer A" on the TV (device identifier) and in the cloud (other identifier): Until today
    /// the TV's state stayed behind under the device identifier.
    @Test("On first contact the state under the device identifier moves along")
    func firstContact() async throws {
        let (cloud, store) = device("fernseher")
        // The cloud identifier is the smaller one and wins (``ProfileSync/wins(_:about:)``).
        let here = Profile(identifier: .init(rawValue: "FFFFFFFF-0000-4000-8000-000000000001"), name: "Max")
        var ledger = ProfileBook()
        ledger.create(here)
        ledger.write(in: store)
        var status = StillLedger()
        status.record(.titlePosition(title: "film", location: 4000, duration: 7200))
        status.write(in: store, forItem: here.identifier.rawValue)

        let top = Profile(identifier: .init(rawValue: "00000000-0000-4000-8000-000000000001"), name: "max ")
        #expect(cloud.adopt([top]) > 0)

        #expect(ProfileBook.read(from: store).profile.map(\.identifier) == [top.identifier])
        #expect(
            StillLedger.read(from: store, forItem: top.identifier.rawValue).state.titlePositions["film"]?
                .location == 4000,
            "after first contact the state under the device identifier sits under a dead name")
        #expect(StillLedger.read(from: store, forItem: here.identifier.rawValue) == StillLedger())
    }
}
