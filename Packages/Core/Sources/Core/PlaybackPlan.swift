import Foundation

/// How a title is played — **engine, delivery route, start tracks and start position from
/// one hand.**
///
/// **Why this exists** (AP58 R4, report A finding S2). The inputs for
/// ``PlaybackEngineSelector/decide(for:wantsSubtitles:audioTrack:subtitleTrack:availableBitrate:quality:startAt:sourceCanStartAtOffset:prefersPlainSubtitles:hasMediaServer:displaySupportsHDR:canDecodeHEVC:)``
/// were built in four places — start and next episode on the TV, the jump via the server,
/// the start on the phone —, and each left out something different. The phone passed
/// neither audio track nor subtitle, quality level, measured connection or the ASS choice;
/// the next episode on the TV always began at zero and assumed the media server even where
/// a provider delivered the episode. Each gap was an engine switch in the middle of a series
/// or an audio track that the person had turned off.
///
/// **Computes, reads nothing from the device.** What the person prefers comes in as
/// ``Preference``, what the device can do as ``Device``. Both have a default that reads the
/// stores (``Preference/effective(interfaceLanguage:)``); the board check passes in its own
/// values.
public enum PlaybackPlan {

    /// What the person prefers — **read for this playback, not remembered.**
    public struct Preference: Sendable, Equatable {
        public var audio: AudioPreference
        /// Plain text instead of custom drawing for charset-based subtitles — see
        /// ``SubtitleStyle/prefersPlainSubtitles(from:)``.
        public var plainSubtitles: Bool
        public var quality: StreamQuality
        /// The measured connection, when it is tight and fresh — ``ThroughputMemory``.
        public var measuredBitrate: Int?
        /// The language of the interface — fallback for the subtitles of the anime rule.
        public var interfaceLanguage: String
        /// Which audio language was chosen for which title (AP58 G1, A10) — it takes precedence over
        /// the general rule, see ``AudioMemory/preferred(_:identifier:series:)``.
        public var audioMemory: AudioMemory

        public init(
            audio: AudioPreference = AudioPreference(), plainSubtitles: Bool = false,
            quality: StreamQuality = .unlimited, measuredBitrate: Int? = nil,
            interfaceLanguage: String = "en", audioMemory: AudioMemory = AudioMemory()
        ) {
            self.audioMemory = audioMemory
            self.audio = audio
            self.plainSubtitles = plainSubtitles
            self.quality = quality
            self.measuredBitrate = measuredBitrate
            self.interfaceLanguage = interfaceLanguage
        }

        /// The preferences that apply now — **the one place where they are read.**
        ///
        /// Audio and subtitles from the person's compartment (``ProfileStore/playback``), the
        /// level and the measurement from the device: They depend on the connection, not on the
        /// person. Until AP58 R4 each of the four build sites read on its own, and two forgot the
        /// ASS choice — the default `false` then silently decided for the second engine.
        public static func effective(
            interfaceLanguage: String, device: any KeyValueStore = SecureStore()
        ) -> Preference {
            Preference(
                audio: AudioPreference.load(from: ProfileStore.playback),
                plainSubtitles: SubtitleStyle.prefersPlainSubtitles(
                    from: ProfileStore.playback),
                quality: StreamQuality.load(from: device),
                measuredBitrate: ThroughputMemory.constrainingBitrate(from: device),
                interfaceLanguage: interfaceLanguage,
                audioMemory: AudioMemory.load(from: ProfileStore.playback))
        }
    }

    /// What the device can do — **asked, not assumed.** The answer is known to `Playback`
    /// (`DisplaySupport`, `DeviceCodecs`), and the default of this device lives there as well.
    public struct Device: Sendable, Equatable {
        public var hdr: Bool
        public var hevc: Bool

        public init(hdr: Bool, hevc: Bool) {
            self.hdr = hdr
            self.hevc = hevc
        }
    }

    /// What the source can do.
    public struct Source: Sendable, Equatable {
        /// Ob sie den Strom an einer Stelle beginnen kann — ``ContentSource/canStartAtOffset``.
        public var canShift: Bool
        /// Whether a media server stands behind it that can chunk.
        ///
        /// **A question to the source and no assumption about the occasion.** The next episode on
        /// the TV always claimed a media server until AP58 R4, even for a series from the provider —
        /// the first episode then played differently from the second.
        public var isMediaServer: Bool

        public init(canShift: Bool, isMediaServer: Bool) {
            self.canShift = canShift
            self.isMediaServer = isMediaServer
        }

        /// What a source can do — **by its own statement and not by its type.**
        ///
        /// Only a source that can start at an offset can chunk: the media server. Providers,
        /// portals and the aggregate source cannot. **A filtered source answers for the one beneath
        /// it** — the question `is JellyfinSource` said "no media server" for a child profile,
        /// because the filter's wrapper was asked there.
        public init(_ source: any ContentSource) {
            self.init(
                canShift: source.canStartAtOffset, isMediaServer: source.canStartAtOffset)
        }
    }

    /// Why a plan is made — **the four build sites as three occasions.**
    public enum Occasion: Sendable, Equatable {
        /// A start from a list or the detail page, on the TV as on the phone.
        /// - fest: an explicitly chosen position (chapter, "from the beginning" as zero).
        /// - vonVorn: the saved state does not count.
        case start(fixed: TimeInterval?, fromStart: Bool)
        /// The next episode in the running player.
        /// - mitUntertiteln: whether a subtitle was playing in the previous episode — whoever
        ///   watches with subtitles wants them in the next one too.
        case nextEpisode(withSubtitles: Bool)
        /// The same title at a different position — a jump via the server or a track switch. The
        /// chosen tracks carry over instead of being chosen anew.
        case jump(from: TimeInterval, audio: Int?, subtitles: Int?)
    }

    /// The result.
    public struct Plan: Sendable, Equatable {
        public let decision: PlaybackDecision
        public let audio: MediaTrack?
        public let subtitles: MediaTrack?
        public let startAt: TimeInterval

        /// The language of the start tracks — **for engines and remuxers that choose themselves.**
        /// With chunked delivery the choice is in the address as a track number; whoever remuxes a
        /// file on their own finds it only via the language.
        public var audioLanguage: String? { audio?.language }
        public var subtitleLanguage: String? { subtitles?.language }
    }

    public static func build(
        title: MediaItem, media: MediaSource, source: Source, preference: Preference,
        device: Device, reason: Occasion
    ) -> Plan {
        let tracks: (audio: MediaTrack?, subtitle: MediaTrack?)
        let startAt: TimeInterval
        var withSubtitles = false
        switch reason {
        case .start(let fixed, let fromStart):
            tracks = startTracks(title: title, media: media, preference: preference)
            startAt = PlaybackProgress.startPoint(
                fixed: fixed, state: fromStart ? nil : title.progress, length: title.runtime)
        case .nextEpisode(let subtitles):
            tracks = startTracks(title: title, media: media, preference: preference)
            startAt = PlaybackProgress.startPoint(state: title.progress, length: title.runtime)
            withSubtitles = subtitles
        case .jump(let from, let audio, let subtitles):
            tracks = (
                track(audio, in: media.audioTracks), track(subtitles, in: media.subtitleTracks)
            )
            startAt = from
        }
        let decision = PlaybackEngineSelector.decide(
            for: media,
            wantsSubtitles: withSubtitles,
            audioTrack: tracks.audio,
            subtitleTrack: tracks.subtitle,
            availableBitrate: preference.measuredBitrate,
            quality: preference.quality,
            startAt: startAt,
            sourceCanStartAtOffset: source.canShift,
            prefersPlainSubtitles: preference.plainSubtitles,
            hasMediaServer: source.isMediaServer,
            displaySupportsHDR: device.hdr,
            canDecodeHEVC: device.hevc)
        return Plan(
            decision: decision, audio: tracks.audio, subtitles: tracks.subtitle,
            startAt: startAt)
    }

    /// The anime rule including the subtitle level — ``StartingTracks``, **with this title's
    /// remembered audio language on top** (``AudioMemory``). If the file does not carry the
    /// remembered language, the general rule applies.
    private static func startTracks(
        title: MediaItem, media: MediaSource, preference: Preference
    ) -> (audio: MediaTrack?, subtitle: MediaTrack?) {
        let isAnime = StartingTracks.isAnime(
            genres: title.genres, anilistID: title.ratings.anilistID)
        let preferred = preference.audioMemory.preferred(
            preference.audio, identifier: title.id, series: title.seriesID)
        let remembered = StartingTracks.select(
            for: media, isAnime: isAnime, preference: preferred,
            interfaceLanguage: preference.interfaceLanguage)
        guard preferred != preference.audio, remembered.audio == nil else { return remembered }
        return StartingTracks.select(
            for: media, isAnime: isAnime, preference: preference.audio,
            interfaceLanguage: preference.interfaceLanguage)
    }

    /// Looks up a chosen track number in the server's tracks.
    public static func track(_ number: Int?, in tracks: [MediaTrack]) -> MediaTrack? {
        guard let number else { return nil }
        return tracks.first { Int($0.id) == number }
    }
}
