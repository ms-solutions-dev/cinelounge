import Foundation

/// When subtitles appear by themselves — before a menu was ever opened.
///
/// **The default is "forced only", and that is no convenience.** A forced track carries
/// exactly the passages that even someone who understands the audio track needs:
/// foreign-language dialogue, signs, the sign language of the apes. Leaving them out means
/// leaving out parts of the movie — with the four "Blaublan prouvouspa ciakos Fanauskuk" movies, half the
/// opening. The full track next to it would be the other extreme: eight hundred overlays on
/// top of a German audio track that nobody wanted to read along with.
public enum SubtitleMode: String, CaseIterable, Sendable, Identifiable {

    /// Never by themselves — only what is chosen in the track menu.
    case off

    /// Only the forced track of the preferred language. The default.
    case forcedOnly

    /// Always read along: the full track of the preferred language, otherwise the forced one.
    case always

    public var id: String { rawValue }

    static let key = "playback.subtitleMode"

    /// Out of the box: forced only. Reasoning on the enumeration itself.
    public static let standard = SubtitleMode.forcedOnly

    public static func load(from store: any KeyValueStore) -> SubtitleMode {
        SubtitleMode(rawValue: (try? store.value(for: key)) ?? "") ?? standard
    }

    public func save(to store: any KeyValueStore) {
        try? store.set(rawValue, for: Self.key)
    }
}

/// What is chosen at start — audio track and subtitles —, before a menu was ever opened.
///
/// Two separate language rules, because they are two separate habits: Whoever watches movies
/// in German as a rule does not by any means watch anime in German — original audio with
/// subtitles is the normal case there, not the exception. A single language rule would have
/// to decide for one of the two habits and would be wrong for the other every time.
///
/// The subtitle rule deliberately lives **here** and not in ``SubtitleStyle``: There it
/// says what a line looks like, here it says whether it exists at all. And all callers of the
/// start choice already load from here anyway.
public struct AudioPreference: Sendable, Equatable {

    /// Preferred audio language as an ISO code ("deu"), `nil` means: the file's default track —
    /// the previous behavior.
    public var language: String?

    /// Anime in original audio: Japanese audio track, subtitles in the preferred language.
    ///
    /// Off by default. The rule applies only where a title is recognizable as anime — see
    /// ``StartingTracks/isAnime(genres:anilistID:)``.
    public var animeOriginal: Bool

    /// Wann Untertitel von selbst erscheinen.
    public var subtitles: SubtitleMode

    public init(
        language: String? = nil,
        animeOriginal: Bool = false,
        subtitles: SubtitleMode = .standard
    ) {
        self.language = language
        self.animeOriginal = animeOriginal
        self.subtitles = subtitles
    }

    static let languageKey = "playback.audioLanguage"
    static let animeKey = "playback.animeOriginal"

    public static func load(from store: any KeyValueStore) -> AudioPreference {
        let language = (try? store.value(for: languageKey)).flatMap { $0.isEmpty ? nil : $0 }
        let anime = (try? store.value(for: animeKey)) == "on"
        return AudioPreference(
            language: language,
            animeOriginal: anime,
            subtitles: SubtitleMode.load(from: store)
        )
    }

    /// Stores **all three** values — for takeovers and checks, not for a single switch in the
    /// interface.
    ///
    /// **In a ``ProfileStore`` this would be the wrong writer** (counter-check of 2026-09-24):
    /// Whoever only toggles the anime rule would write the inherited device value of the audio
    /// language into the compartment as its own value. It would go to the cloud with the
    /// timestamp *now* and beat the real choice from the other device there — and the fallback to
    /// the device would be silently switched off for this person. The interface therefore writes
    /// per key: ``writeLanguage(_:in:)``, ``writeAnimeOriginal(_:in:)``,
    /// ``SubtitleMode/save(to:)``.
    public func save(to store: any KeyValueStore) {
        Self.writeLanguage(language, in: store)
        Self.writeAnimeOriginal(animeOriginal, in: store)
        subtitles.save(to: store)
    }

    /// Only the audio language. `nil` means "as the file specifies" and is stored as an empty value.
    public static func writeLanguage(_ language: String?, in store: any KeyValueStore) {
        try? store.set(language ?? "", for: languageKey)
    }

    /// Only the anime rule.
    public static func writeAnimeOriginal(_ on: Bool, in store: any KeyValueStore) {
        try? store.set(on ? "on" : "off", for: animeKey)
    }
}

/// Compares language codes across spellings.
///
/// Files list their tracks sometimes with two, sometimes with three letters, and for German
/// there are even two three-letter forms (`deu` and `ger`). Whoever only checks for equality
/// misses the German track in every second file — and the error would look as if the setting
/// were ignored.
public enum LanguageCode {

    /// The spellings per language, limited to the languages that the app offers. A complete ISO
    /// table would be mere ballast here: What is not offered, nobody can choose.
    static let families: [[String]] = [
        ["de", "deu", "ger"],
        ["en", "eng"],
        ["tr", "tur"],
        ["ja", "jpn"],
    ]

    public static func matches(_ first: String?, _ second: String?) -> Bool {
        guard let first = first?.lowercased(), let second = second?.lowercased(),
            !first.isEmpty, !second.isEmpty
        else { return false }
        if first == second { return true }
        return families.contains { $0.contains(first) && $0.contains(second) }
    }

    /// The two-letter form (`de` for `ger`/`deu`) — for badges and queries that expect ISO 639-1.
    /// Unknown codes come back only if they already have two letters; a three-letter one without
    /// a family yields `nil`.
    public static func short(_ code: String?) -> String? {
        guard let code = code?.lowercased(), !code.isEmpty else { return nil }
        if let family = families.first(where: { $0.contains(code) }) { return family[0] }
        return code.count == 2 ? code : nil
    }
}

/// Chooses audio and subtitle track for the start of a playback.
///
/// The rule runs **before** the engine choice: Its selection goes as the chosen track into
/// ``PlaybackEngineSelector/decide`` and from there — depending on the delivery route — as a
/// track number into the address or as a language request to the engine.
public enum StartingTracks {

    /// Whether a title counts as anime.
    ///
    /// The AniList ID is the reliable sign: The server plugin assigns it only to anime, and it is
    /// language-independent. The genre stands next to it as a second net — for servers without
    /// the plugin.
    public static func isAnime(genres: [String], anilistID: String?) -> Bool {
        if let anilistID, !anilistID.isEmpty { return true }
        return genres.contains { $0.localizedCaseInsensitiveContains("anime") }
    }

    /// The choice for the start: audio track and subtitles, both optional.
    ///
    /// - Anime with the original-audio rule switched on: the Japanese track, plus the **full**
    ///   track in the preferred language (first the general language rule, then the interface
    ///   language). The subtitle level deliberately does not apply here: Whoever orders Japanese
    ///   audio orders reading along with it — without a line the rule would be pointless. If
    ///   there is no Japanese, the general rule applies — a rule that finds nothing must not land
    ///   silently on some arbitrary track.
    /// - Otherwise: the audio track in the desired language, plus the subtitles per the
    ///   configured level — out of the box the forced track.
    /// - Without an audio language preference, the audio stays at the file's default. The subtitle
    ///   choice still runs: It does not depend on the audio but on the language the viewer reads
    ///   — otherwise that of the interface.
    public static func select(
        for source: MediaSource,
        isAnime: Bool,
        preference: AudioPreference,
        interfaceLanguage: String
    ) -> (audio: MediaTrack?, subtitle: MediaTrack?) {
        let wantedSubtitle = preference.language ?? interfaceLanguage

        if isAnime, preference.animeOriginal {
            if let japanese = audioTrack(in: source, language: "ja") {
                return (japanese, subtitleTrack(in: source, language: wantedSubtitle))
            }
        }

        let audio = preference.language.flatMap { audioTrack(in: source, language: $0) }

        switch preference.subtitles {
        case .off:
            return (audio, nil)
        case .forcedOnly:
            return (audio, subtitleTrack(in: source, language: wantedSubtitle, forced: true))
        case .always:
            // First the full track, then the forced one as a fallback: "Always" means reading along, and
            // a forced track with eleven overlays is not reading along. Where only the forced one exists,
            // it is better than nothing in any case.
            let full = subtitleTrack(in: source, language: wantedSubtitle, forced: false)
            return (audio, full ?? subtitleTrack(in: source, language: wantedSubtitle))
        }
    }

    private static func audioTrack(in source: MediaSource, language: String) -> MediaTrack? {
        source.audioTracks.first { LanguageCode.matches($0.language, language) }
    }

    /// The subtitle for the language — plain text before charset-based, image formats never.
    ///
    /// Text runs through the playlist with the native engine, charset-based (ASS) leads to VLC —
    /// both are worth a deliberate choice. Image formats from DVD and Blu-ray are not suited as
    /// a default: They are expensive to fetch, and whoever wants them chooses them in the menu.
    /// That is exactly what "Blonwaund Mukicim" hinged on: There an external full DVDSUB track stands
    /// next to the forced SubRip track, and without this precedence the choice landed on the
    /// image format.
    ///
    /// - Parameter forced: `true` only forced tracks, `false` only full ones, `nil` both. The
    ///   setting is the whole difference between "translates the ape language" and "subtitles the
    ///   whole movie".
    private static func subtitleTrack(
        in source: MediaSource,
        language: String,
        forced: Bool? = nil
    ) -> MediaTrack? {
        let matching = source.subtitleTracks.filter {
            LanguageCode.matches($0.language, language) && (forced == nil || $0.isForced == forced)
        }
        if let text = matching.first(where: { $0.subtitleFormat?.isPlainText == true }) {
            return text
        }
        return matching.first {
            switch $0.subtitleFormat {
            case .ass, .ssa: true
            default: false
            }
        }
    }
}
