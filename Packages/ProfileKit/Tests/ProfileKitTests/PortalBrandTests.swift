import CloudSync
import Foundation
import Testing

@testable import Core
@testable import ProfileKit

/// The person token (AP47, owner decision A): **on the device in the Keychain, encrypted
/// across the zone with the profile.** Against the ``CloudSync/MockCloud``, without a network and
/// without an account.
@Suite("The person brand in the profile")
@MainActor
struct PortalBrandTests {

    let server = MockCloud()
    /// **Fixed and small**: In the name match the smaller ID wins
    /// (``ProfileSync/wins(_:about:)``) — here it should be the cloud's.
    let identifier = Profile.Identifier(rawValue: "00000000-0000-4000-8000-0000000000A1")

    /// Made up, begins with `PRUEF-` as in `JoinTests`.
    static let old = PersonMarker(value: "PRUEF-marke-alt-Zq0XbYl7u2")!
    static let fresh = PersonMarker(value: "PRUEF-marke-neu-Hk2Wm9Rr4s")!

    var person: Profile { Profile(identifier: identifier, name: "Selin", color: .lilac) }

    /// - Parameter fuehrtMarken: `false` is the already installed phone — it manages the
    ///   channel lists (and thus clears all ``ProfileCloud/allTypes``) but does not know the
    ///   token.
    func device(
        _ name: String, keepsBrands: Bool = true
    ) -> (cloud: ProfileCloud, ledgers: InMemoryStore, keychain: InMemoryStore) {
        let ledgers = InMemoryStore()
        let keychain = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("selin"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        // **The move bundle is the same Keychain** — the way the app connects it.
        let cloud = ProfileCloud(
            hub: hub, store: ledgers, moveBundle: keychain, automatic: false)
        if keepsBrands {
            cloud.brandStore = keychain
        } else {
            cloud.channelLists = { [] }
        }
        var ledger = ProfileBook.read(from: ledgers)
        ledger.create(person)
        ledger.write(in: ledgers)
        return (cloud, ledgers, keychain)
    }

    // MARK: - Der Wert

    @Test("An empty brand is none")
    func empty() {
        #expect(PersonMarker(value: "") == nil)
        #expect(PersonMarker(value: "  \n") == nil)
    }

    /// **The token never in a log line** — on none of the three ways by which
    /// Swift writes a value out by itself, and not via the digest either.
    @Test("The brand appears in no output")
    func isSecret() {
        let tag = Self.old
        var dumped = ""
        dump(tag, to: &dumped)
        for output in ["\(tag)", String(reflecting: tag), dumped, tag.digest] {
            #expect(!output.contains("PRUEF-marke"), "brand in: \(output.prefix(40))")
        }
        #expect(tag.digest.count == 64)
        #expect(tag.digest != Self.fresh.digest)
    }

    // MARK: - Das Fach

    @Test("The bucket is per profile and clears itself")
    func bucket() {
        let keychain = InMemoryStore()
        let bucket = PortalMarkerSlot(keychain)
        let other = Profile.Identifier(rawValue: UUID().uuidString)
        #expect(bucket.tag(forItem: identifier) == nil)
        #expect(bucket.create(Self.old, forItem: identifier))
        #expect(bucket.create(Self.old, forItem: identifier) == false, "the same brand is not a change")
        #expect(bucket.tag(forItem: identifier) == Self.old)
        #expect(bucket.tag(forItem: other) == nil)
        bucket.forget(forItem: identifier)
        #expect(bucket.tag(forItem: identifier) == nil)
    }

    /// **It is not in the profile value** — that travels as JSON into the book file and into the
    /// second screen's setup bundle, whose wire runs without TLS.
    @Test("The brand is in neither the book file nor the profile JSON")
    func notInProfile() throws {
        let ledgers = InMemoryStore()
        var ledger = ProfileBook()
        ledger.create(
            Profile(identifier: identifier, name: "Selin", credentials: [.portals(person: "selin")]))
        ledger.write(in: ledgers)
        PortalMarkerSlot(ledgers).create(Self.old, forItem: identifier)
        let file = try ledgers.value(for: ProfileBook.key)
        #expect(!file.contains("PRUEF-marke"))
        let json = String(decoding: try JSONEncoder().encode(ledger.profile), as: UTF8.self)
        #expect(!json.contains("PRUEF-marke"))
    }

    // MARK: - Die Zone

    /// **The sentence this is about:** The share on the phone stores the token, and the
    /// Apple TV with the same profile has it afterwards — without a pairing code.
    @Test("The brand travels via the zone to the second device")
    func migrates() async {
        let phone = device("telefon")
        PortalMarkerSlot(phone.keychain).create(Self.old, forItem: identifier)
        await phone.cloud.reconcile(person)

        let tv = device("fernseher")
        await tv.cloud.reconcile(person)
        #expect(PortalMarkerSlot(tv.keychain).tag(forItem: identifier) == Self.old)
    }

    /// **Diagnosis F-025 (2026-09-28):** Token and CL-Server access were both called
    /// `portals`; CloudKit rejected every pass of the profile.
    @Test("The brand is named differently from the CL-Server access")
    func ownName() {
        #expect(PortalMarkerMapping.name != ProfileMapping.recordName(forItem: .portals(person: nil)))
        #expect(PortalMarkerMapping.name != ProfileMapping.recordName(forItem: .portals(person: "p")))
    }

    @Test("The field is encrypted, and the record carries only the value")
    func encrypted() async throws {
        let phone = device("telefon")
        PortalMarkerSlot(phone.keychain).create(Self.old, forItem: identifier)
        await phone.cloud.reconcile(person)
        let message = try #require(
            phone.cloud.zone(forItem: identifier)?.read(
                contentType: PortalMarkerMapping.contentType, name: PortalMarkerMapping.name))
        #expect(message.encrypted == PortalMarkerMapping.isSecret)
        #expect(Set(message.fields.keys) == PortalMarkerMapping.isSecret)
    }

    /// **An app with the old type catalog takes the token away from nobody.** The
    /// installed iPhone clears on every pass every record of its types that it does not
    /// write itself — if the token stood as `Profileinstellung` or as a field on `Access`, it
    /// would be gone afterwards.
    @Test("A cleanup pass with the old type catalog leaves the brand alone")
    func oldPhoneDoesNotCleanUp() async {
        let tv = device("fernseher")
        PortalMarkerSlot(tv.keychain).create(Self.old, forItem: identifier)
        await tv.cloud.reconcile(person)

        let oldPhone = device("altes-telefon", keepsBrands: false)
        await oldPhone.cloud.reconcile(person)
        await oldPhone.cloud.reconcile(person)

        let later = device("zweiter-fernseher")
        await later.cloud.reconcile(person)
        #expect(PortalMarkerSlot(later.keychain).tag(forItem: identifier) == Self.old)
    }

    /// **Revocation:** The new token replaces the old one — on the device that still has it.
    @Test("A new brand replaces the old one on the other device")
    func newTokenArrives() async {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let phone = device("telefon")
        let tv = device("fernseher")
        PortalMarkerSlot(phone.keychain).create(Self.old, forItem: identifier)
        await phone.cloud.reconcile(person, now: t0)
        await tv.cloud.reconcile(person, now: t0)
        #expect(PortalMarkerSlot(tv.keychain).tag(forItem: identifier) == Self.old)

        PortalMarkerSlot(phone.keychain).create(Self.fresh, forItem: identifier)
        await phone.cloud.reconcile(person, now: t0.addingTimeInterval(10))
        await tv.cloud.reconcile(person, now: t0.addingTimeInterval(20))
        #expect(PortalMarkerSlot(tv.keychain).tag(forItem: identifier) == Self.fresh)
    }

    /// **The race:** A share stores a new token while the old one is still
    /// up there. A fetch must not overwrite it with the old one.
    @Test("Downloading does not overwrite a locally newer brand")
    func noOverwrite() async {
        let tv = device("fernseher")
        PortalMarkerSlot(tv.keychain).create(Self.old, forItem: identifier)
        await tv.cloud.reconcile(person)

        // Newly stored, but not yet written up — then a push comes.
        PortalMarkerSlot(tv.keychain).create(Self.fresh, forItem: identifier)
        tv.cloud.download(identifier)
        #expect(PortalMarkerSlot(tv.keychain).tag(forItem: identifier) == Self.fresh)
    }

    /// **B5 of the cross-check, across the whole pass:** A device gets a fresh token via a share
    /// before it has ever seen the cloud; the older one lies up there. On first
    /// contact the older one must not overwrite the fresh one.
    @Test("On first contact the fresh local brand wins")
    func firstContactKeepsFreshBrand() async {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let oldDevice = device("altes")
        PortalMarkerSlot(oldDevice.keychain).create(Self.old, forItem: identifier)
        await oldDevice.cloud.reconcile(person, now: t0)

        let newProfile = device("neues")
        PortalMarkerSlot(newProfile.keychain).create(Self.fresh, forItem: identifier)
        await newProfile.cloud.reconcile(person, now: t0.addingTimeInterval(10))
        #expect(PortalMarkerSlot(newProfile.keychain).tag(forItem: identifier) == Self.fresh)

        await oldDevice.cloud.reconcile(person, now: t0.addingTimeInterval(20))
        #expect(PortalMarkerSlot(oldDevice.keychain).tag(forItem: identifier) == Self.fresh)
    }

    /// **B1:** The one hookup sets both slots.
    @Test("schliesseSchluesselbundAn sets preferences and brands")
    func connection() async {
        let ledgers = InMemoryStore()
        let keychain = InMemoryStore()
        let cloud = ProfileCloud(
            hub: CloudHub(
                service: server.credential("selin"), file: nil,
                device: DeviceDescription(identifier: "x", name: "x", model: "Test rig")),
            store: ledgers, moveBundle: nil, automatic: false)
        cloud.attachKeychain(keychain)
        #expect(cloud.brandStore != nil)
        #expect(cloud.preferenceStore != nil)
    }

    /// **The ID migrates on first iCloud contact (AP48) — the token with it.**
    @Test("The merge moves the brand to the cloud's identifier")
    func merging() async {
        let tv = device("fernseher")
        let deviceID = Profile.Identifier(rawValue: "FFFFFFFF-0000-4000-8000-0000000000A2")
        var ledger = ProfileBook()
        ledger.create(Profile(identifier: deviceID, name: "Selin"))
        ledger.write(in: tv.ledgers)
        PortalMarkerSlot(tv.keychain).create(Self.old, forItem: deviceID)

        tv.cloud.adopt([person])

        let bucket = PortalMarkerSlot(tv.keychain)
        #expect(bucket.tag(forItem: identifier) == Self.old)
        #expect(bucket.tag(forItem: deviceID) == nil)
    }
}
