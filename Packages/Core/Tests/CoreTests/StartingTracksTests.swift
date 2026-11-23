import Testing

@testable import Core

/// The starting choice of tracks: it runs before every playback and without the
/// viewer doing anything — a bug here shows up as "the setting is ignored",
/// and nobody looks for it in the language comparison.
@Suite("Preferred audio track")
struct StartingTracksTests {

    /// Rebuilt from an anime episode: three audio tracks, ASS subtitles in two
    /// languages — and for the checks additionally a German SubRip.
    static var anime: MediaSource {
        MediaSource(
            container: .mkv,
            videoCodec: "h264",
            audioTracks: [
                .init(id: "1", kind: .audio, title: "German", language: "deu", codec: "aac", isDefault: true),
                .init(id: "2", kind: .audio, title: "English", language: "eng", codec: "aac"),
                .init(id: "3", kind: .audio, title: "Japanese", language: "jpn", codec: "aac"),
            ],
            subtitleTracks: [
                .init(
                    id: "4", kind: .subtitle, title: "German ASS", language: "deu", codec: "ass",
                    subtitleFormat: .ass),
                .init(
                    id: "5", kind: .subtitle, title: "German SRT", language: "deu", codec: "subrip",
                    subtitleFormat: .subrip),
                .init(
                    id: "6", kind: .subtitle, title: "English ASS", language: "eng", codec: "ass",
                    subtitleFormat: .ass),
            ]
        )
    }

    @Test("The anime rule picks Japanese with subtitles in the preferred language")
    func animeRulePicksOriginalWithSubtitles() {
        let choice = StartingTracks.select(
            for: Self.anime,
            isAnime: true,
            preference: AudioPreference(animeOriginal: true),
            interfaceLanguage: "de"
        )

        #expect(choice.audio?.id == "3", "the Japanese track")
        // Plain text before character set: text runs through the playlist on the
        // native engine — the proven, calmer path. ASS would remain the case for VLC.
        #expect(choice.subtitle?.id == "5", "the German SubRip, not the ASS")
    }

    @Test("Without text subtitles the anime rule takes the styled set")
    func animeRuleFallsBackToASS() {
        var source = Self.anime
        source.subtitleTracks.removeAll { $0.id == "5" }

        let choice = StartingTracks.select(
            for: source,
            isAnime: true,
            preference: AudioPreference(animeOriginal: true),
            interfaceLanguage: "de"
        )

        #expect(choice.subtitle?.id == "4", "ASS is better than no subtitle at all")
    }

    @Test("Without a Japanese track the general language rule applies")
    func animeRuleNeedsJapanese() {
        var source = Self.anime
        source.audioTracks.removeAll { $0.id == "3" }

        let choice = StartingTracks.select(
            for: source,
            isAnime: true,
            preference: AudioPreference(language: "eng", animeOriginal: true),
            interfaceLanguage: "de"
        )

        // A rule that finds nothing must not silently land on some arbitrary track —
        // it steps back, and the general rule applies.
        #expect(choice.audio?.id == "2")
        #expect(choice.subtitle == nil)
    }

    @Test("The anime rule leaves non-anime alone")
    func animeRuleIgnoresOtherTitles() {
        let choice = StartingTracks.select(
            for: Self.anime,
            isAnime: false,
            preference: AudioPreference(animeOriginal: true),
            interfaceLanguage: "de"
        )

        #expect(choice.audio == nil)
        #expect(choice.subtitle == nil)
    }

    @Test("The language rule finds the track across spellings")
    func languageRuleMatchesSpellings() {
        // The file carries "deu", the setting might carry "de" — and for
        // German there are even two three-letter forms. Whoever checks only for
        // equality misses the track in every second file.
        let choice = StartingTracks.select(
            for: Self.anime,
            isAnime: false,
            preference: AudioPreference(language: "de"),
            interfaceLanguage: "en"
        )
        #expect(choice.audio?.id == "1")

        #expect(LanguageCode.matches("deu", "ger"))
        #expect(LanguageCode.matches("ja", "jpn"))
        #expect(!LanguageCode.matches("deu", "eng"))
        #expect(!LanguageCode.matches(nil, "deu"))
    }

    @Test("Without a preference everything stays at the file default")
    func noPreferenceMeansNoChoice() {
        let choice = StartingTracks.select(
            for: Self.anime,
            isAnime: true,
            preference: AudioPreference(),
            interfaceLanguage: "de"
        )
        #expect(choice.audio == nil)
        #expect(choice.subtitle == nil)
    }

    @Test("Bitmap formats are never chosen automatically")
    func imageSubtitlesAreNeverAutoSelected() {
        // DVD tracks are often forced tracks with a different purpose — whoever
        // wants them picks them in the menu.
        var source = Self.anime
        source.subtitleTracks = [
            .init(
                id: "9", kind: .subtitle, title: "German DVD", language: "deu", codec: "dvdsub",
                subtitleFormat: .vobsub)
        ]

        let choice = StartingTracks.select(
            for: source,
            isAnime: true,
            preference: AudioPreference(animeOriginal: true),
            interfaceLanguage: "de"
        )
        #expect(choice.audio?.id == "3")
        #expect(choice.subtitle == nil)
    }

    @Test("Anime is recognized by the AniList identifier, failing that by genre")
    func animeDetection() {
        #expect(StartingTracks.isAnime(genres: [], anilistID: "12345"))
        #expect(StartingTracks.isAnime(genres: ["Anime", "Action"], anilistID: nil))
        #expect(!StartingTracks.isAnime(genres: ["Animation"], anilistID: nil))
        #expect(!StartingTracks.isAnime(genres: [], anilistID: nil))
    }

    // MARK: - Erzwungene Untertitel

    /// Rebuilt from a film of the library: a German forced track that translates only
    /// the passages in a foreign language (a few hundred captions), next to the full
    /// German track and an English one.
    static var forcedFilm: MediaSource {
        MediaSource(
            container: .mkv,
            videoCodec: "h264",
            audioTracks: [
                .init(id: "1", kind: .audio, title: "German", language: "deu", codec: "ac3", isDefault: true)
            ],
            subtitleTracks: [
                .init(
                    id: "3", kind: .subtitle, title: "Forced - German - Erzwungen - SUBRIP",
                    language: "deu", codec: "subrip", subtitleFormat: .subrip, isDefault: true,
                    isForced: true),
                .init(
                    id: "4", kind: .subtitle, title: "Deutsch - German - SUBRIP", language: "deu",
                    codec: "subrip", subtitleFormat: .subrip),
                .init(
                    id: "5", kind: .subtitle, title: "English - SUBRIP", language: "eng",
                    codec: "subrip", subtitleFormat: .subrip),
            ]
        )
    }

    @Test("Out of the box the start picks the forced track of the preferred language")
    func forcedOnlyIsTheDefault() {
        let choice = StartingTracks.select(
            for: Self.forcedFilm,
            isAnime: false,
            preference: AudioPreference(language: "deu"),
            interfaceLanguage: "de"
        )

        #expect(choice.audio?.id == "1")
        // The core of the finding: until 2026-08-28 this was hard-coded `nil`, and every
        // ordinary movie started without any line.
        #expect(choice.subtitle?.id == "3", "the forced one, not the full track")
        #expect(choice.subtitle?.isForced == true)
    }

    @Test("\"Off\" omits the subtitles, \"Always\" takes the full track")
    func subtitleModes() {
        let off = StartingTracks.select(
            for: Self.forcedFilm,
            isAnime: false,
            preference: AudioPreference(language: "deu", subtitles: .off),
            interfaceLanguage: "de"
        )
        #expect(off.audio?.id == "1", "the audio choice is unaffected by the level")
        #expect(off.subtitle == nil)

        let always = StartingTracks.select(
            for: Self.forcedFilm,
            isAnime: false,
            preference: AudioPreference(language: "deu", subtitles: .always),
            interfaceLanguage: "de"
        )
        // "Always" means reading along — a forced track with 199 captions
        // against 800 would not be reading along.
        #expect(always.subtitle?.id == "4", "the full track")
        #expect(always.subtitle?.isForced == false)
    }

    @Test("Without a full track \"Always\" falls back to the forced one")
    func alwaysFallsBackToForced() {
        var source = Self.forcedFilm
        source.subtitleTracks.removeAll { $0.id == "4" }

        let choice = StartingTracks.select(
            for: source,
            isAnime: false,
            preference: AudioPreference(language: "deu", subtitles: .always),
            interfaceLanguage: "de"
        )
        #expect(choice.subtitle?.id == "3", "a forced track is better than none")
    }

    @Test("Without an audio language preference the subtitle rule still applies")
    func subtitlesDoNotHangOnTheAudioLanguage() {
        // The subtitle depends on the language the viewer reads — not
        // on whether they specified an audio track. Before 2026-08-28 the
        // choice aborted here, and the setting looked as if it did nothing.
        let choice = StartingTracks.select(
            for: Self.forcedFilm,
            isAnime: false,
            preference: AudioPreference(),
            interfaceLanguage: "de"
        )
        #expect(choice.audio == nil, "the audio stays at the file default")
        #expect(choice.subtitle?.id == "3")
    }

    @Test("Text before bitmap: the external DVD track is left alone")
    func textBeatsImages() {
        // A sequel carries several external DVDSUB tracks next to the forced
        // SubRip track. An image track as a default would be expensive to fetch —
        // and whoever wants it picks it in the menu.
        var source = Self.forcedFilm
        source.subtitleTracks.insert(
            .init(
                id: "0", kind: .subtitle, title: "German - Erzwungen - DVDSUB - Extern",
                language: "deu", codec: "DVDSUB", subtitleFormat: .vobsub, isForced: true,
                isExternal: true),
            at: 0
        )

        let choice = StartingTracks.select(
            for: source,
            isAnime: false,
            preference: AudioPreference(language: "deu"),
            interfaceLanguage: "de"
        )
        #expect(choice.subtitle?.id == "3", "the forced SubRip, not the DVDSUB before it")
    }

    @Test("The subtitle level survives saving and loading")
    func subtitleModeRoundTrip() {
        let store = InMemoryStore()
        #expect(SubtitleMode.load(from: store) == .forcedOnly, "out of the box: forced only")

        AudioPreference(language: "deu", subtitles: .always).save(to: store)
        #expect(AudioPreference.load(from: store).subtitles == .always)

        SubtitleMode.off.save(to: store)
        #expect(SubtitleMode.load(from: store) == .off)
    }

    @Test("The store survives saving and loading")
    func preferenceRoundTrip() {
        let store = InMemoryStore()
        AudioPreference(language: "jpn", animeOriginal: true).save(to: store)
        #expect(
            AudioPreference.load(from: store)
                == AudioPreference(language: "jpn", animeOriginal: true)
        )

        AudioPreference().save(to: store)
        #expect(AudioPreference.load(from: store) == AudioPreference())
    }
}
