import Foundation
import Testing

@testable import Core

/// Audio preference and subtitles **per person** — product decision 4 of 2026-09-24.
///
/// The checks run via ``ProfilePointer/als(_:_:)`` and ``ProfileStore/active(_:)``,
/// that is, via the same path that ``ProfileStore/playback`` takes in the
/// program — only with an in-memory store instead of the Keychain.
@Suite("Playback preferences per profile")
struct ProfileStoreTests {

    let personA = UUID().uuidString
    let personB = UUID().uuidString

    /// A file with a German, an English and a Japanese audio track.
    static var film: MediaSource {
        MediaSource(
            container: .mkv,
            videoCodec: "h264",
            audioTracks: [
                .init(id: "1", kind: .audio, title: "German", language: "deu", codec: "aac", isDefault: true),
                .init(id: "2", kind: .audio, title: "English", language: "eng", codec: "aac"),
                .init(id: "3", kind: .audio, title: "Japanese", language: "jpn", codec: "aac"),
            ],
            subtitleTracks: []
        )
    }

    /// What the player chooses at startup — read the way ``MainView`` does it.
    func startTrack(as profile: String?, in device: any KeyValueStore) -> String? {
        ProfilePointer.als(profile) {
            StartingTracks.select(
                for: Self.film, isAnime: false,
                preference: AudioPreference.load(from: ProfileStore.active(device)),
                interfaceLanguage: "de"
            ).audio?.language
        }
    }

    @Test("Profile A plays with A's audio preference, profile B with B's")
    func eachPersonTheirTone() {
        let device = InMemoryStore()
        ProfilePointer.als(personA) {
            AudioPreference(language: "jpn").save(to: ProfileStore.active(device))
        }
        ProfilePointer.als(personB) {
            AudioPreference(language: "eng").save(to: ProfileStore.active(device))
        }

        #expect(startTrack(as: personA, in: device) == "jpn")
        #expect(startTrack(as: personB, in: device) == "eng")
        // **And the device stayed untouched** — otherwise B would have switched A as well.
        #expect((try? device.value(for: AudioPreference.languageKey)) == nil)
    }

    @Test("Without its own value the device's applies — nobody loses their setting")
    func fallbackToDevice() {
        let device = InMemoryStore()
        AudioPreference(language: "eng", subtitles: .always).save(to: device)
        SubtitleStyle(size: .large, color: .yellow).save(to: device)
        SubtitleStyle.setPrefersPlainSubtitles(true, in: device)

        let bucket = ProfileStore(device, forItem: personA)
        #expect(AudioPreference.load(from: bucket) == AudioPreference(language: "eng", subtitles: .always))
        #expect(SubtitleStyle.load(from: bucket) == SubtitleStyle(size: .large, color: .yellow))
        #expect(SubtitleStyle.prefersPlainSubtitles(from: bucket))
        #expect(startTrack(as: personA, in: device) == "eng")
    }

    /// **"Automatic" is a choice.** If an empty audio preference fell back to the
    /// device, nobody could choose it as long as the device says "English".
    @Test("An own empty value beats the device's")
    func emptyIsAChoice() {
        let device = InMemoryStore()
        AudioPreference(language: "eng").save(to: device)
        AudioPreference(language: nil).save(to: ProfileStore(device, forItem: personA))

        #expect(AudioPreference.load(from: ProfileStore(device, forItem: personA)).language == nil)
        // No chosen track means: the default track of the file — and not English.
        #expect(startTrack(as: personA, in: device) == nil)
    }

    /// **The reason why "off" is now a value.** With `remove`, a value switched on at
    /// the device would show through.
    @Test("Off stays off, even if the device says on")
    func offIsAValue() {
        let device = InMemoryStore()
        SubtitleStyle.setPrefersPlainSubtitles(true, in: device)
        let bucket = ProfileStore(device, forItem: personA)
        SubtitleStyle.setPrefersPlainSubtitles(false, in: bucket)

        #expect(!SubtitleStyle.prefersPlainSubtitles(from: bucket))
        #expect(SubtitleStyle.prefersPlainSubtitles(from: device))
    }

    @Test("Without a profile the store is the device")
    func withoutProfileTheDevice() {
        let device = InMemoryStore()
        AudioPreference(language: "jpn").save(to: ProfileStore(device, forItem: nil))
        #expect(AudioPreference.load(from: device).language == "jpn")
        #expect(ProfileStore(device, forItem: nil).own().isEmpty)
        #expect(startTrack(as: nil, in: device) == "jpn")
    }

    // MARK: - Was in die Wolke geht

    @Test("Only what the person set themselves goes to the cloud")
    func ownWithoutFallback() {
        let device = InMemoryStore()
        AudioPreference(language: "eng", animeOriginal: true).save(to: device)
        let bucket = ProfileStore(device, forItem: personA)
        #expect(bucket.own().isEmpty)

        SubtitleStyle(size: .small, color: .white).save(to: bucket)
        #expect(
            bucket.own() == [SubtitleStyle.sizeKey: "small", SubtitleStyle.colorKey: "white"])
    }

    @Test("Incoming values land in the person's slot — unknown ones do not")
    func adoptsOnlyKnown() {
        let device = InMemoryStore()
        let bucket = ProfileStore(device, forItem: personA)
        let foreign = "zukunft:" + UUID().uuidString

        #expect(bucket.adopt([AudioPreference.languageKey: "tur", foreign: "x"]))
        #expect(AudioPreference.load(from: bucket).language == "tur")
        #expect((try? device.value(for: ProfileStore.bucket(foreign, forItem: personA))) == nil)
        // The same thing a second time is not a change.
        #expect(!bucket.adopt([AudioPreference.languageKey: "tur"]))
    }

    /// **The guard for the list.** If ``AudioPreference`` or ``SubtitleStyle`` gets a
    /// new field, `save` writes a key that ``ProfileStore/own()`` does not know — it
    /// would stand per person at the device and arrive on no other.
    @Test("Every key the preferences write travels along")
    func listIsComplete() {
        let transcript = Transcript()
        AudioPreference(language: "eng", animeOriginal: true, subtitles: .always).save(to: transcript)
        SubtitleStyle(size: .large, color: .yellow).save(to: transcript)
        SubtitleStyle.setPrefersPlainSubtitles(true, in: transcript)
        SubtitleStyle.setPrefersPlainSubtitles(false, in: transcript)
        // **Since 2026-09-28 also what otherwise makes up a profile** — Live, trailer, head
        // area, schedule filter and the kind of the Top Shelf shelf.
        var live = LivePreferences()
        live.setShowsBrowseArea(false)
        live.setShowsAdultChannels(true)
        live.setPreviewsChannels(false)
        live.setVisible(false, group: "g")
        live.setGroupOrder(["g"])
        live.save(to: transcript)
        TrailerPreferences().save(to: transcript)
        HeroPreferences().save(to: transcript)
        SportFilterSettings().save(to: transcript)
        TopShelfBridge.updateMode(.latest, store: transcript)
        // **Since 2026-11-09 the binge package** (AP85).
        BingePreferences.writeSkipsIntro(true, in: transcript)
        BingePreferences.writeHidesSpoilers(true, in: transcript)
        BingePreferences.writeStillWatchingAfter(5, in: transcript)

        // **The language writes into the compartment and not via a store** (AP46,
        // 2026-09-25) — its key is counted without the identifier behind it.
        let languageSlot = Transcript()
        AppLanguageSetting.write(
            "de", profile: "p", keychain: languageSlot,
            device: UserDefaults(suiteName: "profilablage-" + UUID().uuidString)!)
        let language = languageSlot.keys.map { String($0.dropLast(".p".count)) }

        #expect(transcript.keys.union(language) == Set(ProfileStore.playbackKeys))
    }

    /// Remembers which keys were written.
    final class Transcript: KeyValueStore, @unchecked Sendable {
        var keys: Set<String> = []
        func set(_ value: String, for keyName: String) throws { keys.insert(keyName) }
        func value(for key: String) throws -> String { throw SecureStore.Failure.notFound }
        func remove(_ keyName: String) throws { keys.insert(keyName) }
    }
}
