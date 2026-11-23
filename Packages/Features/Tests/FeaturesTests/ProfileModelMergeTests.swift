import CloudSync
import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **Removing and merging from "Manage profiles"** (AP45, AP43 · B5, 2026-09-25).
///
/// Via ``ProfileModel`` and not via ``ProfileKit/ProfileCloud/bury(_:target:now:)``: the
/// bug was that the model removed without telling the cloud. A test that buries
/// itself would stay green even if the model forgot it again.
@MainActor
@Suite("Managing profiles: remove and merge")
struct ProfileModelMergeTests {

    let server = MockCloud()
    static let jellyfin = URL(string: "https://haus-a.example/")!

    func device(_ name: String) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false)
        cloud.startStore = nil
        return (cloud, store)
    }

    func model(
        _ store: InMemoryStore, cloud: ProfileCloud? = nil,
        secureStore: SecureStore = SecureStore(service: "probe.\(UUID().uuidString)")
    ) -> ProfileModel {
        ProfileModel(
            keychain: secureStore, store: store, cloud: { cloud },
            startStore: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!)
    }

    @Test("A removed profile does not come back on the other device via find()")
    func removalWithCloud() async throws {
        try await ProfilePointer.als(nil) {
            let tv = device("fernseher")
            let administration = model(tv.store, cloud: tv.cloud)
            _ = administration.create(name: "Max", color: .turquoise, kind: .adult, avatar: nil)
            let grandmother = try #require(
                administration.create(name: "Oma", color: .moss, kind: .adult, avatar: nil))
            await tv.cloud.syncAll()

            #expect(administration.remove(grandmother) == .removed)
            await tv.cloud.household()?.reconcile()

            let phone = device("telefon")
            let found = await phone.cloud.find()
            #expect(!found.contains { $0.identifier == grandmother }, "grandma came back from iCloud")
            #expect(found.contains { $0.name == "Max" })
        }
    }

    @Test("Removed without the cloud, the note stays on the device")
    func removalWithoutCloud() throws {
        try ProfilePointer.als(nil) {
            let store = InMemoryStore()
            let administration = model(store)
            _ = administration.create(name: "Max", color: .turquoise, kind: .adult, avatar: nil)
            let grandmother = try #require(
                administration.create(name: "Oma", color: .moss, kind: .adult, avatar: nil))
            administration.remove(grandmother)
            #expect(ProfileTombstone.all(from: store).map(\.identifier) == [grandmother])
        }
    }

    @Test("Merging asks for the PIN, merges and clears the orphaned account")
    func merge() throws {
        try ProfilePointer.als(nil) {
            let store = InMemoryStore()
            let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
            let administration = model(store, secureStore: secureStore)
            let max = try #require(
                administration.create(name: "Max", color: .turquoise, kind: .adult, avatar: nil))
            let papa = try #require(
                administration.create(name: "Papa", color: .coral, kind: .adult, avatar: nil))
            for (identifier, user) in [(max, "max"), (papa, "papa")] {
                let credential = ServerCredentials(
                    serverURL: Self.jellyfin, userID: user, username: user,
                    accessToken: "marke-\(user)")
                try secureStore.memorize(credential)
                var ledger = ProfileBook.read(from: store)
                ledger.update(identifier) {
                    $0.create(
                        .jellyfin(server: Self.jellyfin, userID: user, username: user))
                }
                ledger.write(in: store)
            }
            administration.load()
            ProfilePIN(store: secureStore, forItem: papa).set("4711", now: Date())

            #expect(
                administration.merge(papa, in: max)
                    == .pinRequired(try #require(administration.profile.first { $0.identifier == papa })))
            #expect(administration.profile.count == 2)

            let outcome = administration.merge(papa, in: max, pins: [papa: "4711"])
            guard case .merged(let combined, _) = outcome else {
                Issue.record("not merged: \(outcome)")
                return
            }
            #expect(administration.profile.map(\.identifier) == [max])
            #expect(
                combined.jellyfin
                    == .jellyfin(server: Self.jellyfin, userID: "max", username: "max"))
            #expect(
                !secureStore.allAccounts().contains { $0.userID == "papa" },
                "the account that no longer belongs to any profile is still in the Keychain")
            #expect(secureStore.allAccounts().contains { $0.userID == "max" })
            #expect(ProfilePIN(store: secureStore, forItem: max).matches("4711"))
            #expect(ProfileTombstone.all(from: store).map(\.identifier) == [papa])
        }
    }

    /// Two profiles with one media-server account each in the Keychain.
    func withAccounts(
        _ administration: ProfileModel, _ store: InMemoryStore, _ secureStore: SecureStore,
        _ pairs: [(Profile.Identifier, String)]
    ) throws {
        for (identifier, user) in pairs {
            try secureStore.memorize(
                ServerCredentials(
                    serverURL: Self.jellyfin, userID: user, username: user,
                    accessToken: "marke-\(user)"))
            var ledger = ProfileBook.read(from: store)
            ledger.update(identifier) {
                $0.create(
                    .jellyfin(server: Self.jellyfin, userID: user, username: user))
            }
            ledger.write(in: store)
        }
        administration.load()
    }

    /// **Merged into the active profile, and it thereby becomes a child** (counter-check
    /// strand C). Until C2 it switched anew only if the viewer sat in the **leaving** profile
    /// — in the remaining one the adult's session kept running, although the profile is now
    /// a child with the child's account.
    @Test("A child merges into the active profile: the session is the child's immediately")
    func childIntoActive() throws {
        try ProfilePointer.als(nil) {
            let store = InMemoryStore()
            let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
            let administration = model(store, secureStore: secureStore)
            let max = try #require(
                administration.create(name: "Max", color: .turquoise, kind: .adult, avatar: nil))
            let childProfile = try #require(
                administration.create(name: "Selin", color: .coral, kind: .kind, avatar: nil))
            try withAccounts(administration, store, secureStore, [(max, "max"), (childProfile, "selin")])
            administration.switchTo(zu: max)
            #expect((try? secureStore.loadCredentials())?.userID == "max")

            let outcome = administration.merge(childProfile, in: max)
            guard case .merged(let combined, let wasActive) = outcome else {
                Issue.record("not merged: \(outcome)")
                return
            }
            #expect(!wasActive)
            #expect(combined.kind == .kind)
            #expect(administration.active == max)
            #expect((try? secureStore.loadCredentials())?.userID == "selin", "the session stayed the adult's")
        }
    }

    /// **Removing with a PIN, and afterwards nothing lies under the identifier** (finding 8).
    @Test("Removing requires the PIN and clears PIN, age limit, state and shelves")
    func removalWithPin() throws {
        try ProfilePointer.als(nil) {
            let store = InMemoryStore()
            let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
            let administration = model(store, secureStore: secureStore)
            _ = administration.create(name: "Max", color: .turquoise, kind: .adult, avatar: nil)
            let grandmother = try #require(
                administration.create(name: "Oma", color: .moss, kind: .adult, avatar: nil))
            ProfilePIN(store: secureStore, forItem: grandmother).set("2468", now: Date())
            AgeLimit.write(.from12, in: secureStore, forItem: grandmother.rawValue)
            var stillLedger = StillLedger()
            stillLedger.record(.titlePosition(title: "film", location: 10, duration: 100))
            stillLedger.write(in: store, forItem: grandmother.rawValue)
            ShelfOrder(order: ["weiter"]).write(in: store, forItem: grandmother.rawValue)

            #expect(
                administration.remove(grandmother) == .pinRequired(try #require(administration.profile.last)))
            #expect(administration.remove(grandmother, pin: "0000") != .removed)
            #expect(administration.profile.count == 2, "removed without PIN")

            #expect(administration.remove(grandmother, pin: "2468") == .removed)
            #expect(administration.profile.count == 1)
            #expect(!ProfilePIN(store: secureStore, forItem: grandmother).isSet)
            #expect(AgeLimit.read(from: secureStore, forItem: grandmother.rawValue) == nil)
            #expect(StillLedger.read(from: store, forItem: grandmother.rawValue) == StillLedger())
            #expect(ShelfOrder.read(from: store, forItem: grandmother.rawValue) == ShelfOrder())
        }
    }

    /// **A borrowed profile is left, not buried** (finding 8). Its tombstone
    /// would stand in this account's household zone — and it belongs to someone else.
    @Test("A borrowed profile gets no tombstone")
    func isBorrowed() throws {
        let tv = device("fernseher")
        let administration = model(tv.store, cloud: tv.cloud)
        _ = administration.create(name: "Max", color: .turquoise, kind: .adult, avatar: nil)
        let borrow = try #require(
            administration.create(name: "Tante", color: .moss, kind: .adult, avatar: nil))
        tv.cloud.zone(forItem: borrow)?.sharedBy = "Tante Anna"

        guard case .isBorrowed = administration.remove(borrow) else {
            Issue.record("a borrowed profile was buried")
            return
        }
        #expect(ProfileTombstone.all(from: tv.store).isEmpty)
        #expect(tv.cloud.household()?.read(ProfileTombstone.contentType).isEmpty == true)
        #expect(administration.profile.count == 2, "leaving goes through CloudKit, not here")
    }

    @Test("\"Keep both\" removes the question")
    func keepTwo() throws {
        let store = InMemoryStore()
        let administration = model(store)
        let a = try #require(
            administration.create(name: "Max", color: .turquoise, kind: .adult, avatar: nil))
        let b = try #require(administration.create(name: "Papa", color: .coral, kind: .adult, avatar: nil))
        let pair = ProfileSync.Pair(device: a, cloud: b)
        ProfileSync.memorize([pair], in: store)
        #expect(administration.openQuestions == [pair])
        administration.keepBoth(pair)
        #expect(administration.openQuestions.isEmpty)
    }
}

/// **The open "Forgot PIN" requests** (counter-check strand C, finding 6) — the
/// list that the switcher, management screen and PIN sheets show.
@MainActor
@Suite("Open profile requests: visible")
struct ProfileWayOutTests {

    let server = MockCloud()

    @Test("A request from the other device is in the list — in the book's order, known ones only")
    func isVisible() async {
        server.clock = Date(timeIntervalSince1970: 1_758_400_000)
        func cloud(_ name: String) -> ProfileCloud {
            ProfileCloud(
                hub: CloudHub(
                    service: server.credential("max", name: name), file: nil,
                    device: DeviceDescription(identifier: name, name: name, model: "Test rig")),
                store: InMemoryStore(), moveBundle: nil, automatic: false)
        }
        let childProfile = Profile(name: "Selin", kind: .kind)
        let max = Profile(name: "Max")
        let phone = cloud("telefon")
        phone.requestPinRecovery(forItem: .profile(childProfile.identifier), device: "Kinderzimmer")
        phone.requestPinRecovery(forItem: .profile(.fresh()), device: "Kinderzimmer")
        phone.requestPinRecovery(forItem: .parentalControls, device: "Kinderzimmer")
        await phone.household()?.reconcile()

        let tv = cloud("fernseher")
        await tv.household()?.reconcile()
        let escapes = ProfileEscapes.read(cloud: tv, profile: [max, childProfile])
        #expect(escapes.entries.map(\.name) == ["Selin"])
        #expect(escapes.state(forItem: childProfile.identifier)?.pending == true)
        #expect(escapes.state(forItem: max.identifier) == nil)
        #expect(ProfileEscapes.read(cloud: nil, profile: [childProfile]).isEmpty)
    }
}
