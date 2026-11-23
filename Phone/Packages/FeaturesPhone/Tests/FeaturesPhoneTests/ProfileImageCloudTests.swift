import CloudSync
import Core
import Foundation
import ProfileKit
import Testing

@testable import FeaturesPhone

/// **The picture choice on the phone survives a push** (counter-check AP49, B2): Checked
/// via ``ProfilePictureState/save(_:)`` — the connection the app uses —, not
/// via `ProfileCloud.upload` directly.
@MainActor
@Suite("AP49 · Profile picture on the phone and the cloud")
struct ProfileImageCloudTests {

    let server = MockCloud()

    func device(_ name: String) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("adult"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        return (
            ProfileCloud(
                hub: hub, store: store, moveBundle: nil, automatic: false), store
        )
    }

    func read(_ store: InMemoryStore, _ identifier: Profile.Identifier) -> Profile? {
        ProfileBook.read(from: store).profile.first { $0.identifier == identifier }
    }

    @Test("A push between choice and run does not take the picture choice away")
    func pushAfterChoice() async throws {
        let phone = device("telefon")
        let person = Profile(name: "Grandma", color: .moss)
        var ledger = ProfileBook.read(from: phone.store)
        ledger.create(person)
        ledger.write(in: phone.store)
        await phone.cloud.reconcile(person)

        let tv = device("fernseher")
        var otherSide = ProfileBook.read(from: tv.store)
        otherSide.create(person)
        otherSide.write(in: tv.store)
        await tv.cloud.reconcile(person)

        let pictureState = ProfilePictureState(store: phone.store, cloud: { phone.cloud })
        var choice = ProfilePictureChoice(profile: person)
        choice.select(try #require(AvatarMotif.motif(forItem: "strick-oma")))
        pictureState.save(choice)

        // The TV writes a state, the silent push arrives on the phone.
        var stillLedger = StillLedger.read(from: tv.store, forItem: person.identifier.rawValue)
        stillLedger.record(.titlePosition(title: "film", location: 100, duration: 1000))
        stillLedger.write(in: tv.store, forItem: person.identifier.rawValue)
        await tv.cloud.reconcile(person)
        let zone = try #require(phone.cloud.zone(forItem: person.identifier))
        await zone.reconcile()
        #expect(read(phone.store, person.identifier)?.avatar == "strick-oma", "choice overwritten")

        // And the choice arrives over there.
        await tv.cloud.reconcile(try #require(read(tv.store, person.identifier)))
        #expect(read(tv.store, person.identifier)?.avatar == "strick-oma")
    }
}
