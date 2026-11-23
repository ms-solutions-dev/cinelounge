import CloudSync
import Core
import Foundation
import ProfileKit
import Testing

@testable import Features

/// **A choice in Settings survives the next push** — counter-check AP49 of
/// 2026-09-25, finding B2.
///
/// Via ``ProfileModel`` and not via ``ProfileKit/ProfileCloud/upload(_:now:onlyNew:)``:
/// the bug was that the model wrote only into the book. A test that writes up
/// itself would stay green even if the model forgot it again.
@MainActor
@Suite("Profile model and cloud")
struct ProfileModelCloudTests {

    let server = MockCloud()

    func device(_ name: String) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        return (ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false), store)
    }

    func read(_ store: InMemoryStore, _ identifier: Profile.Identifier) -> Profile? {
        ProfileBook.read(from: store).profile.first { $0.identifier == identifier }
    }

    /// Choice on the TV, no run yet — the phone writes state, the silent push
    /// arrives, and the observation fetches down. Picture, name and color must stay.
    @Test("A push between choice and step does not take the choice away")
    func pushAfterChoice() async throws {
        let tv = device("fernseher")
        let model = ProfileModel(
            keychain: SecureStore(service: "probe.\(UUID().uuidString)"),
            store: tv.store, cloud: { tv.cloud })
        let identifier = try #require(
            model.create(name: "Oma", color: .moss, kind: .adult, avatar: nil))
        let person = try #require(read(tv.store, identifier))
        await tv.cloud.reconcile(person)

        let phone = device("telefon")
        var ledger = ProfileBook.read(from: phone.store)
        ledger.create(person)
        ledger.write(in: phone.store)
        await phone.cloud.reconcile(person)

        model.update(identifier, name: "Omi", color: .amber, avatar: "strick-oma")

        var stillLedger = StillLedger.read(from: phone.store, forItem: identifier.rawValue)
        stillLedger.record(.titlePosition(title: "film", location: 100, duration: 1000))
        stillLedger.write(in: phone.store, forItem: identifier.rawValue)
        await phone.cloud.reconcile(person)

        // The silent push on the TV: the zone fetches, the observation writes down.
        let zone = try #require(tv.cloud.zone(forItem: identifier))
        await zone.reconcile()
        let following = try #require(read(tv.store, identifier))
        #expect(following.avatar == "strick-oma", "fresh picture choice overwritten")
        #expect(following.name == "Omi", "fresh name overwritten")
        #expect(following.color == .amber, "fresh color overwritten")

        // And the choice arrives over there.
        await phone.cloud.reconcile(try #require(read(phone.store, identifier)))
        #expect(read(phone.store, identifier)?.avatar == "strick-oma")
        #expect(read(phone.store, identifier)?.name == "Omi")
    }
}
