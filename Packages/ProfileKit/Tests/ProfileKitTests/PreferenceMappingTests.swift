import CloudSync
import Foundation
import Testing

@testable import Core
@testable import ProfileKit

/// Audio preference and subtitles travel via the zone — owner decision 4 of
/// 2026-09-24. Against the ``CloudSync/MockCloud``, without network and without an account.
@Suite("Playback preferences in the cloud")
@MainActor
struct PreferenceMappingTests {

    let server = MockCloud()
    let identifier = Profile.Identifier(rawValue: UUID().uuidString)

    /// A device: cloud, ledger store and Keychain substitute for the preferences.
    /// - Parameter fuehrtVorzuege: `false` is the already installed phone — it manages
    ///   the channel lists (and thereby clears all ``ProfileCloud/allTypes``) but does not know
    ///   the preferences.
    func device(
        _ name: String, keepsPreferences: Bool = true
    ) -> (cloud: ProfileCloud, ledgers: InMemoryStore, keychain: InMemoryStore) {
        let ledgers = InMemoryStore()
        let keychain = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(hub: hub, store: ledgers, moveBundle: nil, automatic: false)
        if keepsPreferences {
            cloud.preferenceStore = keychain
        } else {
            cloud.channelLists = { [] }
        }
        var ledger = ProfileBook.read(from: ledgers)
        ledger.create(Profile(identifier: identifier, name: "Max", color: .turquoise))
        ledger.write(in: ledgers)
        return (cloud, ledgers, keychain)
    }

    var person: Profile { Profile(identifier: identifier, name: "Max", color: .turquoise) }

    func bucket(_ keychain: InMemoryStore) -> ProfileStore {
        ProfileStore(keychain, forItem: identifier.rawValue)
    }

    @Test("What is set on the TV applies on the phone afterwards")
    func backAndForth() async {
        let tv = device("fernseher")
        AudioPreference(language: "jpn", animeOriginal: true).save(to: bucket(tv.keychain))
        SubtitleStyle(size: .large, color: .yellow).save(to: bucket(tv.keychain))
        await tv.cloud.reconcile(person)

        let phone = device("telefon")
        await phone.cloud.reconcile(person)

        #expect(AudioPreference.load(from: bucket(phone.keychain)).language == "jpn")
        #expect(AudioPreference.load(from: bucket(phone.keychain)).animeOriginal)
        #expect(
            SubtitleStyle.load(from: bucket(phone.keychain))
                == SubtitleStyle(size: .large, color: .yellow))
        // **In the person's compartment, not on the device** — otherwise it would apply there to everyone.
        #expect((try? phone.keychain.value(for: AudioPreference.languageKey)) == nil)
    }

    /// **The device value does not go upward.** It is the setting of *this* TV
    /// from before the update; with the timestamp *now* it would beat every choice
    /// the person made elsewhere.
    @Test("The fallback to the device stays on the device")
    func deviceValueStays() async {
        let tv = device("fernseher")
        AudioPreference(language: "eng").save(to: tv.keychain)
        await tv.cloud.reconcile(person)

        let zone = tv.cloud.zone(forItem: identifier)
        let top = PreferenceMapping.values(from: zone?.read(PreferenceMapping.contentType) ?? [])
        #expect(top.isEmpty)
    }

    /// **The collision rule is that of name and colour:** the younger writer wins,
    /// per key.
    @Test("Two devices, two choices: the younger pass wins, per key")
    func newerWins() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let tv = device("fernseher")
        let phone = device("telefon")
        AudioPreference(language: "deu").save(to: bucket(tv.keychain))
        await tv.cloud.reconcile(person, now: t0)
        await phone.cloud.reconcile(person, now: t0)

        // Both change the audio language, the phone additionally the subtitle size.
        AudioPreference(language: "tur").save(to: bucket(tv.keychain))
        AudioPreference(language: "eng").save(to: bucket(phone.keychain))
        SubtitleStyle(size: .small).save(to: bucket(phone.keychain))
        await tv.cloud.reconcile(person, now: t0.addingTimeInterval(10))
        await phone.cloud.reconcile(person, now: t0.addingTimeInterval(20))
        await tv.cloud.reconcile(person, now: t0.addingTimeInterval(30))

        #expect(AudioPreference.load(from: bucket(tv.keychain)).language == "eng")
        #expect(AudioPreference.load(from: bucket(phone.keychain)).language == "eng")
        #expect(SubtitleStyle.load(from: bucket(tv.keychain)).size == .small)
    }

    /// **A program with the old type catalogue takes nothing away from anyone.** The
    /// installed phone clears on every sync pass every record of its types that it does not
    /// write itself. If the preferences were stored as `Profileinstellung`, they were gone
    /// afterwards — hence the own type.
    @Test("A cleanup pass with the old type catalog leaves the preferences alone")
    func noDeletionWithoutConnection() async {
        let tv = device("fernseher")
        AudioPreference.writeLanguage("jpn", in: bucket(tv.keychain))
        await tv.cloud.reconcile(person)

        let phone = device("telefon", keepsPreferences: false)
        await phone.cloud.reconcile(person)
        await phone.cloud.reconcile(person)
        let top = phone.cloud.zone(forItem: identifier)?.read(PreferenceMapping.contentType) ?? []
        #expect(top.count == 1)

        let later = device("zweiter-fernseher")
        await later.cloud.reconcile(person)
        #expect(AudioPreference.load(from: bucket(later.keychain)).language == "jpn")
    }

    // MARK: - Nur, was die Person wirklich gesetzt hat

    /// **The finding of the cross-check:** The view wrote the whole bundle after every single toggle.
    /// Whoever only toggled the anime rule then had the inherited audio
    /// language of the device as their own value — it went upward with the timestamp *now*,
    /// and the fallback to the device was dead for this person.
    @Test("Device de, profile switches only anime: no audio language in the cloud")
    func onlyTheChangedKey() async {
        let tv = device("fernseher")
        AudioPreference.writeLanguage("de", in: tv.keychain)
        AudioPreference.writeAnimeOriginal(true, in: bucket(tv.keychain))
        await tv.cloud.reconcile(person)

        let zone = tv.cloud.zone(forItem: identifier)
        #expect(
            zone?.read(contentType: PreferenceMapping.contentType, name: AudioPreference.languageKey) == nil)
        #expect(zone?.read(contentType: PreferenceMapping.contentType, name: AudioPreference.animeKey) != nil)

        // And afterwards the device keeps applying for the audio language — even if it changes.
        AudioPreference.writeLanguage("eng", in: tv.keychain)
        #expect(AudioPreference.load(from: bucket(tv.keychain)).language == "eng")
    }

    // MARK: - Der Wettlauf

    /// **Between upward and downward there is an `await`**, and exactly there — right after
    /// the profile switch — the person writes. Downward then fetched the old value that had just
    /// been uploaded and wrote it over the new one; the next sync pass saw
    /// no difference any more. A silent push between writing and the next sync pass does
    /// the same, and it is reproduced here that way: ``ProfileCloud/download(_:)`` is exactly
    /// the step that runs after the `await`.
    @Test("What is written during a pass is not overwritten by the download")
    func race() async {
        let tv = device("fernseher")
        AudioPreference.writeLanguage("deu", in: bucket(tv.keychain))
        await tv.cloud.reconcile(person)

        AudioPreference.writeLanguage("eng", in: bucket(tv.keychain))
        tv.cloud.download(identifier)
        #expect(AudioPreference.load(from: bucket(tv.keychain)).language == "eng")

        // And the next sync pass brings the choice upward.
        await tv.cloud.reconcile(person)
        let phone = device("telefon")
        await phone.cloud.reconcile(person)
        #expect(AudioPreference.load(from: bucket(phone.keychain)).language == "eng")
    }

    /// **What really changed in the cloud arrives anyway** — the protection
    /// must not turn into "the device always wins".
    @Test("A change from the other device still arrives")
    func foreignChangeArrives() async {
        let tv = device("fernseher")
        AudioPreference.writeLanguage("deu", in: bucket(tv.keychain))
        await tv.cloud.reconcile(person)
        let phone = device("telefon")
        await phone.cloud.reconcile(person)

        AudioPreference.writeLanguage("tur", in: bucket(phone.keychain))
        await phone.cloud.reconcile(person)
        await tv.cloud.reconcile(person)
        #expect(AudioPreference.load(from: bucket(tv.keychain)).language == "tur")
    }

    @Test("Name, colour and stamp do not see the preferences")
    func disturbsNothing() {
        let wordings =
            PreferenceMapping.wordings(forItem: [AudioPreference.languageKey: "jpn"], now: Date())
            + ProfileMapping.settings(forItem: person)
        #expect(ProfileMapping.profile(identifier: identifier, from: wordings) == person)
        #expect(StillMapping.state(from: wordings) == StateRecording())
        #expect(PreferenceMapping.values(from: wordings) == [AudioPreference.languageKey: "jpn"])
    }
}
