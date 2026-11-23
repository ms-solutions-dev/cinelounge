import CloudSync
import Core
import Foundation
import ProfileKit
import Testing

@testable import Flows

/// A changed name sticks (on-device test 2026-09-27): "Edit profile → Change name" was
/// not applied.
@MainActor
@Suite("Renaming a profile")
struct ProfileRenameTests {

    let server = MockCloud()

    func administration(_ store: InMemoryStore, cloud: ProfileCloud?) -> ProfileManagement {
        ProfileManagement(
            keychain: SecureStore(service: "probe.\(UUID().uuidString)"), store: store,
            cloud: { cloud }, startStore: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!,
            deviceLists: { nil })
    }

    func cloud(_ store: InMemoryStore) -> ProfileCloud {
        let hub = CloudHub(
            service: server.credential("alex"), file: nil,
            device: DeviceDescription(identifier: "tv", name: "tv", model: "Test rig"))
        let cloud = ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false)
        cloud.startStore = nil
        return cloud
    }

    @Test("Without the cloud the new name stays")
    func withoutCloud() throws {
        let store = InMemoryStore()
        let v = administration(store, cloud: nil)
        let identifier = try #require(v.create(name: "d", color: .amber, kind: .adult, avatar: nil))
        v.update(identifier, name: "Alex", color: .amber, avatar: nil)
        #expect(ProfileBook.read(from: store).profile.first { $0.identifier == identifier }?.name == "Alex")
    }

    @Test("After a sync the new name stays")
    func afterSync() async throws {
        let store = InMemoryStore()
        let w = cloud(store)
        let v = administration(store, cloud: w)
        let identifier = try #require(v.create(name: "d", color: .amber, kind: .adult, avatar: nil))
        _ = await w.syncAll()
        v.update(identifier, name: "Alex", color: .amber, avatar: nil)
        _ = await w.syncAll()
        v.load()
        #expect(ProfileBook.read(from: store).profile.first { $0.identifier == identifier }?.name == "Alex")
    }

    @Test("Before the first sync the new name stays")
    func beforeFirstSync() async throws {
        let store = InMemoryStore()
        let w = cloud(store)
        let v = administration(store, cloud: w)
        let identifier = try #require(v.create(name: "d", color: .amber, kind: .adult, avatar: nil))
        v.update(identifier, name: "Alex", color: .amber, avatar: nil)
        _ = await w.syncAll()
        v.load()
        #expect(ProfileBook.read(from: store).profile.first { $0.identifier == identifier }?.name == "Alex")
    }

    /// **The case from the simulator:** the zone was never at the server (no iCloud), but carries
    /// the records from creation. `handOff` therefore did not write the rename into the
    /// mirror — and when another record was added later (the portal person), the
    /// observer played the old name back into the book.
    @Test("Without server contact the mirror does not overwrite the new name")
    func withoutServerContact() throws {
        server.reachable = false
        let store = InMemoryStore()
        let w = cloud(store)
        let v = administration(store, cloud: w)
        let identifier = try #require(v.create(name: "d", color: .amber, kind: .adult, avatar: nil))
        let profile = try #require(
            ProfileBook.read(from: store).profile.first { $0.identifier == identifier })
        w.upload(profile)
        v.update(identifier, name: "Alex", color: .amber, avatar: nil)
        w.download(identifier)
        #expect(ProfileBook.read(from: store).profile.first { $0.identifier == identifier }?.name == "Alex")
    }

    /// **The same root, a different path** (simulator 2026-09-28): the choice of a person at the
    /// CL-Server writes directly into the book (``Household/PortalAssignment``), not via
    /// ``ProfileManagement/update``. On a profile switch the never-synced mirror
    /// played the access without a person back — and "Who is 'd'?" was there again.
    @Test("A mirror that was never synced does not overwrite the ledger")
    func mirrorWithoutServerContact() throws {
        server.reachable = false
        let store = InMemoryStore()
        let w = cloud(store)
        let v = administration(store, cloud: w)
        let identifier = try #require(v.create(name: "d", color: .amber, kind: .adult, avatar: nil))
        var ledger = ProfileBook.read(from: store)
        ledger.update(identifier) { $0.create(.portals(person: nil)) }
        ledger.write(in: store)
        w.upload(try #require(ProfileBook.read(from: store).profile.first { $0.identifier == identifier }))
        ledger = ProfileBook.read(from: store)
        ledger.update(identifier) { $0.create(.portals(person: "alex")) }
        ledger.write(in: store)
        w.download(identifier)
        #expect(
            ProfileBook.read(from: store).profile.first { $0.identifier == identifier }?.portalPerson
                == "alex")
    }
}
