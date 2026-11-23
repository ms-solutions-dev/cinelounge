import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// The profile picture on its way through the store and the cloud (AP49) — against the
/// ``CloudSync/MockCloud``, without network and without an account.
@Suite("The profile image in the cloud")
@MainActor
struct ProfileImageCloudTests {

    let server = MockCloud()
    let identifier = Profile.Identifier(rawValue: UUID().uuidString)

    func device(_ name: String) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        return (ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false), store)
    }

    func create(_ profile: Profile, in store: InMemoryStore) {
        var ledger = ProfileBook.read(from: store)
        ledger.create(profile)
        ledger.write(in: store)
    }

    func read(_ store: InMemoryStore) -> Profile? {
        ProfileBook.read(from: store).profile.first { $0.identifier == identifier }
    }

    // MARK: - Mapping

    @Test("Round trip keeps the image")
    func roundTripMapping() {
        let profile = Profile(identifier: identifier, name: "Oma", avatar: "strick-oma")
        let wordings = ProfileMapping.wordings(forItem: profile)
        #expect(ProfileMapping.profile(identifier: identifier, from: wordings) == profile)
    }

    /// **Deliberately flipped (cross-check of 2026-09-25):** Empty is no longer the same as none.
    /// `nil` means "never decided" and produces no record; `""` means "No picture" and
    /// produces a record with an empty value — the tombstone, which competes with a
    /// picture by timestamp. Round trip, each of the two stays what it was.
    @Test("Never decided yields no record, No image yields an empty one")
    func noRecordWithoutImage() {
        let never = ProfileMapping.wordings(forItem: Profile(identifier: identifier, name: "Oma"))
        #expect(!never.contains { $0.contentType == ProfileMapping.avatarType })
        #expect(ProfileMapping.profile(identifier: identifier, from: never)?.avatar == nil)

        let none = ProfileMapping.wordings(forItem: Profile(identifier: identifier, name: "Oma", avatar: ""))
        let message = none.first { $0.contentType == ProfileMapping.avatarType }
        #expect(message?[ProfileMapping.valueField]?.text == "")
        #expect(ProfileMapping.profile(identifier: identifier, from: none)?.avatar == "")
    }

    /// **A name from a newer version gets through.** Anyone who dropped it on reading
    /// would write "no picture" upward on the next sync pass and take the choice away from the other device.
    @Test("An unknown name round-trips unchanged")
    func unknownName() {
        let profile = Profile(identifier: identifier, name: "Oma", avatar: "drache-im-nebel")
        let back = ProfileMapping.profile(
            identifier: identifier, from: ProfileMapping.wordings(forItem: profile))
        #expect(back?.avatar == "drache-im-nebel")
        #expect(AvatarMotif.motif(forItem: back?.avatar) == nil)
    }

    /// **Profile ledgers from before AP49 do not have the field.** If reading failed on them,
    /// an empty ledger would be there after the update — and the next start would rebuild the profiles
    /// from the device, with fresh identifiers and without state.
    @Test("An old profile book without the field still reads")
    func oldBook() throws {
        let old = Profile(identifier: identifier, name: "Oma", color: .moss, kind: .adult)
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["avatar"] = nil
        #expect(json.keys.sorted() == ["art", "farbe", "kennung", "name", "zugaenge"])
        let ledger: [String: Any] = ["profile": [json], "aktiv": identifier.rawValue]
        let text = try #require(
            String(data: JSONSerialization.data(withJSONObject: ledger), encoding: .utf8))

        let store = InMemoryStore()
        try store.set(text, for: ProfileBook.key)

        let read = try #require(read(store))
        #expect(read.name == "Oma")
        #expect(read.avatar == nil)
    }

    // MARK: - Cloud

    /// **The round trip across two devices** — chosen on the TV, arrived on the phone;
    /// deselected on the TV, gone over there too.
    @Test("Chosen and deselected both arrive on the other device")
    func roundTripCloud() async throws {
        let tv = device("fernseher")
        var person = Profile(identifier: identifier, name: "Oma", color: .moss, avatar: "strick-oma")
        create(person, in: tv.store)
        await tv.cloud.reconcile(person)

        let phone = device("telefon")
        create(Profile(identifier: identifier, name: "Oma", color: .moss), in: phone.store)
        await phone.cloud.reconcile(try #require(read(phone.store)))
        #expect(read(phone.store)?.avatar == "strick-oma")

        person.avatar = ""
        create(person, in: tv.store)
        await tv.cloud.reconcile(person)
        await phone.cloud.reconcile(try #require(read(phone.store)))
        #expect(read(phone.store)?.avatar == "")
    }

    /// **Why the picture is not a `Profileinstellung` record.** A version from before AP49
    /// clears every `Profileinstellung` record it does not write itself on every sync pass
    /// — reproduced here with exactly its three keys. The picture has to survive that.
    @Test("A cleanup pass of an old version leaves the image alone")
    func oldVersionDoesNotCleanUp() async throws {
        let tv = device("fernseher")
        let person = Profile(identifier: identifier, name: "Oma", avatar: "popcorn-waschbaer")
        create(person, in: tv.store)
        await tv.cloud.reconcile(person)

        let old = device("altes-telefon")
        let zone = try #require(old.cloud.zone(forItem: identifier))
        await zone.reconcile()
        let known: Set = [
            ProfileMapping.nameKey, ProfileMapping.colorKey,
            ProfileMapping.kindKey,
        ]
        for message in zone.read(ProfileMapping.settingType) where !known.contains(message.name) {
            zone.delete(contentType: ProfileMapping.settingType, name: message.name)
        }
        await zone.reconcile()

        let later = device("zweiter-fernseher")
        create(Profile(identifier: identifier, name: "Oma"), in: later.store)
        await later.cloud.reconcile(try #require(read(later.store)))
        #expect(read(later.store)?.avatar == "popcorn-waschbaer")
    }

    /// **When merging, the picture does not get lost** — the upper one wins, including a "No
    /// picture" (`""`); only "never decided" (`nil`) lets this device's value stand.
    @Test("Merging keeps the image")
    func merge() {
        let here = Profile(name: "Oma", avatar: "strick-oma")
        let remoteWithout = Profile(identifier: identifier, name: "Oma")
        let remoteWith = Profile(identifier: identifier, name: "Oma", avatar: "opa-teekanne")
        #expect(ProfileSync.fuse(device: here, cloud: remoteWithout).avatar == "strick-oma")
        #expect(ProfileSync.fuse(device: here, cloud: remoteWith).avatar == "opa-teekanne")
        let remoteNone = Profile(identifier: identifier, name: "Oma", avatar: "")
        #expect(ProfileSync.fuse(device: here, cloud: remoteNone).avatar == "")
    }
}
