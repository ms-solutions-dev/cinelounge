import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// **The cross-check for AP49 (2026-09-25)** — the profile picture between old mirrors,
/// offline choices and the younger writer.
///
/// Finding B2 (a push between choice and sync pass) is tested by `FeaturesTests/ProfileModelCloudTests`
/// via ``ProfileModel``, because the bug was there and not in the reconciliation.
@Suite("Profile image: cross-check AP49")
@MainActor
struct ProfileImageCrossCheckTests {

    let server = MockCloud()
    let identifier = Profile.Identifier(rawValue: UUID().uuidString)

    func device(_ name: String, mirrorFolder: URL? = nil) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        return (
            ProfileCloud(
                hub: hub, store: store, moveBundle: nil, mirrorFolder: mirrorFolder,
                automatic: false), store
        )
    }

    func create(_ profile: Profile, in store: InMemoryStore) {
        var ledger = ProfileBook.read(from: store)
        ledger.create(profile)
        ledger.write(in: store)
    }

    func read(_ store: InMemoryStore) -> Profile? {
        ProfileBook.read(from: store).profile.first { $0.identifier == identifier }
    }

    /// Finding B1: A device on an old version pulls the `ProfileImage` record into its mirror
    /// (unknown type, stored anyway). After the update to AP49 the ledger does not have
    /// the field, the mirror has the record — and `upload` runs before `download`.
    @Test("Old mirror with a record and a book without the field does not delete the image")
    func oldMirrorDeletes() async throws {
        let tv = device("fernseher")
        let person = Profile(identifier: identifier, name: "Oma", avatar: "strick-oma")
        create(person, in: tv.store)
        await tv.cloud.reconcile(person)

        let folder = FileManager.default.temporaryDirectory.appending(
            path: "ap49-\(UUID().uuidString)")
        let marker = try #require(ProfileMapping.zone(forItem: identifier))
        let oldZone = ProfileZone(
            file: folder.appending(path: "wolke-\(identifier.rawValue).json"),
            service: server.credential("max"), zone: marker, automatic: false)
        for message in ProfileMapping.settings(forItem: Profile(identifier: identifier, name: "Oma")) {
            oldZone.write(message)
        }
        await oldZone.reconcile()
        #expect(
            oldZone.read(contentType: ProfileMapping.avatarType, name: ProfileMapping.avatarKey)
                != nil)
        #expect(oldZone.recent != nil)

        // Update: new version, same mirror on disk, ledger without avatar.
        let phone = device("telefon", mirrorFolder: folder)
        create(Profile(identifier: identifier, name: "Oma"), in: phone.store)
        await phone.cloud.reconcile(try #require(read(phone.store)))

        await tv.cloud.reconcile(try #require(read(tv.store)))
        #expect(read(tv.store)?.avatar == "strick-oma", "image gone on the TV")
        #expect(read(phone.store)?.avatar == "strick-oma", "image never arrived on the phone")
    }

    /// Finding B3: Offline choice against a younger "No picture" — the younger writer wins,
    /// because "No picture" is a record with a timestamp (`""`) and not a deletion.
    @Test("Image chosen offline against a later No image")
    func offlineImageVersusNoImage() async throws {
        let person = Profile(identifier: identifier, name: "Oma", avatar: "strick-oma")
        let a = device("a")
        create(person, in: a.store)
        await a.cloud.reconcile(person)
        let b = device("b")
        create(person, in: b.store)
        await b.cloud.reconcile(person)

        var bChoice = person
        bChoice.avatar = "opa-teekanne"
        create(bChoice, in: b.store)
        b.cloud.upload(bChoice, now: Date(timeIntervalSinceNow: -3600))  // 10:00, offline

        var aChoice = person
        aChoice.avatar = ""
        create(aChoice, in: a.store)
        await a.cloud.reconcile(aChoice)  // 11:00, online: No picture

        await b.cloud.reconcile(bChoice)  // 12:00: B comes online
        await a.cloud.reconcile(try #require(read(a.store)))
        #expect(read(a.store)?.avatar == "", "the younger writer (No image) should win")
        #expect(read(b.store)?.avatar == "")
    }

    /// Conversely: offline "No picture" against a younger picture.
    @Test("Offline No image against a later image")
    func offlineNoImageVersusImage() async throws {
        let person = Profile(identifier: identifier, name: "Oma", avatar: "strick-oma")
        let a = device("a")
        create(person, in: a.store)
        await a.cloud.reconcile(person)
        let b = device("b")
        create(person, in: b.store)
        await b.cloud.reconcile(person)

        var bChoice = person
        bChoice.avatar = ""
        create(bChoice, in: b.store)
        b.cloud.upload(bChoice, now: Date(timeIntervalSinceNow: -3600))  // 10:00 offline: No picture

        var aChoice = person
        aChoice.avatar = "opa-teekanne"
        create(aChoice, in: a.store)
        await a.cloud.reconcile(aChoice)  // 11:00 online

        await b.cloud.reconcile(bChoice)  // 12:00
        await a.cloud.reconcile(try #require(read(a.store)))
        #expect(read(a.store)?.avatar == "opa-teekanne", "the younger writer (image) should win")
        #expect(read(b.store)?.avatar == "opa-teekanne")
    }

    /// Control test for finding B1 without an old version: two new devices, ledger without the field —
    /// nothing may get lost here (the push path writes the ledger before the next `upload`).
    @Test("Two new devices: image arrives and stays")
    func twoNewDevices() async throws {
        let tv = device("fernseher")
        let person = Profile(identifier: identifier, name: "Oma")
        create(person, in: tv.store)
        await tv.cloud.reconcile(person)
        let phone = device("telefon")
        create(person, in: phone.store)
        await phone.cloud.reconcile(person)

        var withImage = person
        withImage.avatar = "strick-oma"
        create(withImage, in: tv.store)
        await tv.cloud.reconcile(withImage)

        await phone.cloud.reconcile(try #require(read(phone.store)))
        #expect(read(phone.store)?.avatar == "strick-oma")
        await tv.cloud.reconcile(try #require(read(tv.store)))
        #expect(read(tv.store)?.avatar == "strick-oma")
    }
}
