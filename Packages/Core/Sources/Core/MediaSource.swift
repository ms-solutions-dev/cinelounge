import Foundation

/// Describes how a file is technically made. The server delivers this before the
/// start, and from it the decision follows which engine plays it — see
/// ``PlaybackEngineSelector``.
public struct MediaSource: Sendable, Equatable, Hashable, Codable {

    public enum Container: String, Sendable, Equatable, Codable {
        case mp4, mov, m4v, mkv, avi, ts, webm, hls
        case unknown

        /// Containers that Apple's own engine can open. Everything else the server would
        /// have to remux first.
        ///
        /// **The container alone does not decide** whether the native engine can play the
        /// file — see ``MediaSource/isNativelyPlayable``. An MP4 can contain any picture
        /// codec, including ones Apple does not know.
        public var isNativelySupported: Bool {
            switch self {
            case .mp4, .mov, .m4v, .hls: true
            case .mkv, .avi, .ts, .webm, .unknown: false
            }
        }

        /// The container as the **bytes** identify it — not the name.
        ///
        /// **The finding** (AP3 · V3c, expert review 2026-08-24): if the file is called `.mp4`,
        /// it goes straight to direct delivery, and the remuxer is never asked. The name
        /// comes from the provider's Xtream information, and that is a claim: with a
        /// provider that calls every file `.mp4`, the app decides on the basis of a
        /// statement nobody has checked — and a Matroska behind an `.mp4` name is never
        /// opened by AVFoundation.
        ///
        /// Three identifiers suffice, and all three are in the first bytes:
        ///
        /// - `ftyp` at position 4 — the ISO family (MP4, MOV, M4V).
        /// - `1A 45 DF A3` — the EBML header of Matroska and WebM.
        /// - `0x47` at a spacing of 188 bytes — the grid of the transport stream.
        ///
        /// `nil` means: the bytes say nothing. Then the name stays in charge —
        /// a claim is still better than no statement at all.
        public static func fromBytes(_ bytes: Data) -> Container? {
            guard bytes.count >= 8 else { return nil }
            let b = [UInt8](bytes.prefix(4096))

            // Matroska and WebM share the EBML header. Which of the two it is only appears in
            // the `DocType` — for the choice of engine the difference is irrelevant: neither
            // can be opened by AVFoundation, both can be handled by the remuxer.
            if b.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .mkv }

            // `ftyp` comes after the box length, so at position 4.
            if b.count >= 8, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
                return .mp4
            }

            // The transport stream has no header but a grid: 0x47 every 188 bytes. Three hits
            // in a row are no coincidence.
            if b.count >= 3 * 188 + 1, b[0] == 0x47, b[188] == 0x47, b[376] == 0x47,
                b[564] == 0x47
            {
                return .ts
            }

            return nil
        }

        public init(rawValue: String) {
            switch rawValue.lowercased() {
            case "mp4": self = .mp4
            case "mov": self = .mov
            case "m4v": self = .m4v
            case "mkv", "matroska", "x-matroska": self = .mkv
            case "avi": self = .avi
            case "ts", "mpegts", "mpeg-ts": self = .ts
            case "webm": self = .webm
            case "hls", "m3u8": self = .hls
            default: self = .unknown
            }
        }
    }

    public enum SubtitleFormat: String, Sendable, Equatable, Codable {
        /// Zeitgesteuerter Text, den Apples Motor darstellen kann.
        case vtt, ttml
        /// Character-based formats with their own formatting — only VLC renders them.
        case ass, ssa, srt, subrip
        /// Image-based, comes from DVD and Blu-ray. Apple's engine cannot do them.
        case pgs, dvbsub, vobsub
        case unknown

        /// Whether Apple's engine does **not** render this format itself.
        ///
        /// **Until 2026-09-02 the name was `needsVLC`** (AP8, added later) and thereby named an
        /// answer that no longer exists: VLC is gone. The question behind it has remained
        /// and is important — it decides whether the track may be handed to the engine or
        /// whether the app has to draw it itself.
        public var needsOwnRenderer: Bool {
            switch self {
            case .vtt, .ttml: false
            default: true
            }
        }

        /// Whether the format is pure timed text.
        ///
        /// The difference from ``needsOwnRenderer``: this question applies **with** a
        /// media server. Pure text is converted by the server when chunking into WebVTT
        /// snippets and attached as its own track to the playlist — Apple's engine then
        /// renders it itself, including the system's subtitle settings. ASS/SSA lose their
        /// layout in this conversion (for anime the layout is half the content), and image
        /// formats cannot be converted at all — so the app draws both itself.
        public var isPlainText: Bool {
            switch self {
            case .vtt, .ttml, .srt, .subrip: true
            case .ass, .ssa, .pgs, .dvbsub, .vobsub, .unknown: false
            }
        }

        /// Whether the format carries text at all — as opposed to images.
        ///
        /// Only text can be converted to WebVTT by the server; an image stays an image. The
        /// difference from ``isPlainText``: there it is about text **without** its own
        /// typeface, here about text at all.
        public var isTextBased: Bool {
            switch self {
            case .vtt, .ttml, .srt, .subrip, .ass, .ssa: true
            case .pgs, .dvbsub, .vobsub, .unknown: false
            }
        }

        /// Whether the app can **draw the format itself** — with a media server.
        ///
        /// **On 2026-08-10 only one case remained here.** Pure text comes as WebVTT, PGS and
        /// VobSub come as a raw image track, ASS raw with its layout — the app fetches and
        /// draws everything without an engine switch. What remains is DVBSUB: it comes only
        /// from channels, and test material is still missing for it.
        public var isSelfRenderable: Bool {
            switch self {
            // ASS and SSA since 2026-08-10: the server delivers them **raw** (`Stream.ass`),
            // ``ASSSubtitles`` reads out time, text and position, and the custom renderer sets
            // them — dialogue at the bottom, signs at the top. The detour via conversion to
            // WebVTT, in which exactly this position was lost, is thus gone.
            case .vtt, .ttml, .srt, .subrip, .pgs, .ass, .ssa: true
            // VobSub since 2026-08-10: the server delivers `.sub` without trouble — the note
            // "neither convert nor deliver raw" was true only for `.vtt` and `.idx`. Drawing
            // works as with PGS.
            case .vobsub: true
            // DVBSUB is still missing: it comes only from channels, and without test material
            // the reader would be built and unproven.
            case .dvbsub, .unknown: false
            }
        }

        /// The container as the **bytes** identify it — not the name.
        ///
        /// **The finding** (AP3 · V3c, expert review 2026-08-24): if the file is called `.mp4`,
        /// it goes straight to direct delivery, and the remuxer is never asked. The name
        /// comes from the provider's Xtream information, and that is a claim: with a
        /// provider that calls every file `.mp4`, the app decides on the basis of a
        /// statement nobody has checked — and a Matroska behind an `.mp4` name is never
        /// opened by AVFoundation.
        ///
        /// Three identifiers suffice, and all three are in the first bytes:
        ///
        /// - `ftyp` at position 4 — the ISO family (MP4, MOV, M4V).
        /// - `1A 45 DF A3` — the EBML header of Matroska and WebM.
        /// - `0x47` at a spacing of 188 bytes — the grid of the transport stream.
        ///
        /// `nil` means: the bytes say nothing. Then the name stays in charge —
        /// a claim is still better than no statement at all.
        public static func fromBytes(_ bytes: Data) -> Container? {
            guard bytes.count >= 8 else { return nil }
            let b = [UInt8](bytes.prefix(4096))

            // Matroska and WebM share the EBML header. Which of the two it is only appears in
            // the `DocType` — for the choice of engine the difference is irrelevant: neither
            // can be opened by AVFoundation, both can be handled by the remuxer.
            if b.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .mkv }

            // `ftyp` comes after the box length, so at position 4.
            if b.count >= 8, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
                return .mp4
            }

            // The transport stream has no header but a grid: 0x47 every 188 bytes. Three hits
            // in a row are no coincidence.
            if b.count >= 3 * 188 + 1, b[0] == 0x47, b[188] == 0x47, b[376] == 0x47,
                b[564] == 0x47
            {
                return .ts
            }

            return nil
        }

        public init(rawValue: String) {
            switch rawValue.lowercased() {
            case "vtt", "webvtt": self = .vtt
            case "ttml": self = .ttml
            case "ass": self = .ass
            case "ssa": self = .ssa
            case "srt", "subrip": self = .srt
            case "pgs", "pgssub", "hdmv_pgs_subtitle": self = .pgs
            case "dvbsub", "dvb_subtitle": self = .dvbsub
            // **`dvdsub` is Jellyfin's spelling** and was missing here until 2026-08-28 — measured
            // on "Mukicim heklioblou kuspuwen Blaublan kounidrul plouglul Fanauskuk", where four external tracks are reported
            // as `DVDSUB`. As `.unknown` they did not count as an image track and were
            // therefore requested as text via `Stream.vtt`; the server never answers that for
            // image tracks, and the viewer saw "being prepared" for ten minutes.
            case "vobsub", "dvd_subtitle", "dvdsub": self = .vobsub
            default: self = .unknown
            }
        }
    }

    public enum VideoRange: String, Sendable, Equatable, Codable {
        case sdr
        case hdr10
        /// Only Apple's engine passes Dolby Vision through correctly — VLC loses the
        /// dynamic metadata.
        case dolbyVision
        case hlg
    }

    public var container: Container
    public var videoCodec: String?
    public var videoRange: VideoRange

    /// Whether Apple's engine can open **this file** — container **and** picture codec.
    ///
    /// **The container alone is not enough, and a bug hung on that.** A home video in
    /// the catalog is an MP4 and therefore went to the native engine. Its picture,
    /// however, is MPEG-4 Part 2 — the codec of DivX and Xvid, as older cameras and
    /// converters write it. Apple's engine does not know it: it opens the file, shows
    /// nothing, and reports no error. Eighteen gigabytes of family video that "could not
    /// be played" while VLC opens them without further ado.
    ///
    /// What **works** is enumerated, not what does not. The list of codecs that Apple
    /// cannot do is open-ended and grows with every old file that still turns up; the
    /// list of what it can do is fixed and short.
    public var isNativelyPlayable: Bool {
        guard container.isNativelySupported else { return false }
        // Interlacing rules out the native path — rationale at ``isInterlaced``.
        guard isInterlaced != true else { return false }
        // Ten-bit H.264 likewise — rationale at ``videoNeedsSoftwareDecoding``.
        guard !videoNeedsSoftwareDecoding else { return false }
        // Without a statement on the codec, the container stands: that is the case with a
        // channel whose tracks are settled only on opening — there the address is the only
        // thing we have.
        guard let videoCodec, !videoCodec.isEmpty else { return true }
        return Self.nativeVideoCodecs.contains(videoCodec.lowercased())
    }

    /// Whether the picture is a version that only a software decoder decodes —
    /// **H.264 with ten bits** (Hi10P), the classic anime encoding.
    ///
    /// **The codec name alone lies here** (on-device finding 2026-08-15, Woujeinspes Skutgro):
    /// the server reports `h264`, the list says "the hardware can do it" — but no Apple
    /// device decodes H.264 in ten bits. The remuxer built a stream from it that
    /// AVFoundation accepts and never decodes: a stall without an error message, anew
    /// with every audio track switch. VLC decodes Hi10P in software — as before AP1.
    ///
    /// The limit is **codec-specific**: HEVC in ten bits (Main10) the hardware can very
    /// well do — every HDR video is encoded that way. `nil` means "not known" and, as
    /// with interlacing, does not count as an exclusion.
    public var videoNeedsSoftwareDecoding: Bool {
        guard let videoCodec, let videoBitDepth, videoBitDepth > 8 else { return false }
        let lowered = videoCodec.lowercased()
        return lowered == "h264" || lowered == "avc1"
    }

    /// The picture codecs that Apple's engine handles on tvOS.
    ///
    /// `mpeg4` is explicitly **not** in it and is not to be confused with `mpeg4` as a
    /// container name: here the picture codec is meant, MPEG-4 Part 2. What Apple can
    /// do is Part 10 — and that is called `h264`.
    static let nativeVideoCodecs: Set<String> = ["h264", "avc1", "hevc", "h265", "hvc1", "dvh1", "dvhe"]

    /// The spellings behind which HEVC hides.
    ///
    /// **Listed separately because HEVC is the one capability that not every device
    /// has.** Every Apple TV can do H.264; HEVC only the 4K line, and the simulator not
    /// at all. So ``DeviceCodecs`` is asked, not this list — it only says which names
    /// are meant.
    static let hevcCodecs: Set<String> = ["hevc", "h265", "hvc1", "dvh1", "dvhe"]

    /// The audio formats that Apple's engine demonstrably handles in an MP4 delivered
    /// unchanged.
    ///
    /// **DTS and TrueHD are explicitly not in it**, and that is no negligence but the
    /// reason why some titles have to be converted at all: an Apple TV does not output
    /// them, not even via the passthrough path to the amplifier. In our own catalog that
    /// affects every anime episode and one film.
    ///
    /// **MP3 is likewise not in it, although Apple's engine plays MP3 files.** What
    /// matters here is MP3 **in the MP4 container**, and exactly this pairing is the
    /// exception: Swiftfin lists MP3 in its native direct-play profile for `mov` and
    /// `mpegts`, but not for `mp4` — and the twenty-two old phone videos in our own
    /// catalog (H.264 with MP3) are the proof: delivered unchanged, their audio was
    /// missing. For the same reason the list is kept short overall: the server converts
    /// a foreign audio to AAC for a few watts, whereas a silent title looks like a
    /// broken one — and nobody looks for the cause in the audio codec.
    static let nativeAudioCodecs: Set<String> = [
        "aac", "mp4a", "ac3", "ac-3", "eac3", "ec-3",
    ]

    /// What the **own remuxer** can process in audio — the native list plus the
    /// MPEG-audio family, which it transcodes to AAC via ``MPEGAudioTranscoder``
    /// (2026-08-16, silent Turkish national channels). Only for the remux path: in the MP4
    /// delivered unchanged MP3 stays out, see above.
    /// Since 2026-09-04. DTS too: ``DTSTranscoder`` encodes the DTS core (up to 5.1)
    /// in the app to AAC — the server would have to probe the whole file before it
    /// delivers the first second (Continue Watching finding 2026-09-03).
    static let remuxableAudioCodecs: Set<String> =
        nativeAudioCodecs.union(["mp3", "mp2", "mp1", "mpeg1audio", "mpeg2audio", "dts", "dca"])

    /// Whether container, picture **and** audio are demonstrably native — the strict
    /// version for the path via a media server.
    ///
    /// ``isNativelyPlayable`` gives the container the last word when the codec
    /// information is missing. For channels that is right: their tracks are settled only
    /// on opening, and nobody remuxes there anyway. With a media server the doubt turns
    /// around — chunking with copy costs it almost nothing, a black picture or a silent
    /// audio costs trust. What is not demonstrated here therefore counts as not directly
    /// playable.
    ///
    /// For the audio the **first** track counts, that is the one the server lists as
    /// default. Via a chunked stream no other can be chosen anyway — the rationale is at
    /// ``PlaybackDecision/Reason/multipleAudioTracksStayDirect``. No audio track at all,
    /// by contrast, is no doubt but a silent film: the track list did arrive, it was
    /// only shorter — otherwise the picture codec would be missing too.
    public var isProvenNativelyPlayable: Bool {
        guard container.isNativelySupported else { return false }
        // **Interlacing rules out here as well** (found on 2026-09-02 while cleaning up the
        // tautological checks, AP8).
        //
        // The lock stood only in ``isNativelyPlayable`` — the path **without** a media
        // server, where it can have no effect because there is nobody who could
        // deinterlace. With a media server, ``isProvenNativelyPlayable`` decided instead,
        // and the question was not asked there: a 1080i title from the library went
        // unchanged to Apple's engine, which does not deinterlace, and showed a comb
        // pattern at every movement.
        //
        // That is the half of AP2 · U1 step 2 that gets by without feedback from the
        // remuxer: the **server** knows it and says so.
        guard isInterlaced != true else { return false }
        guard !videoNeedsSoftwareDecoding else { return false }
        guard let videoCodec, !videoCodec.isEmpty,
            Self.nativeVideoCodecs.contains(videoCodec.lowercased())
        else { return false }
        guard let first = audioTracks.first else { return true }
        guard let codec = first.codec, !codec.isEmpty else { return false }
        return Self.nativeAudioCodecs.contains(codec.lowercased())
    }
    public var audioTracks: [MediaTrack]
    public var subtitleTracks: [MediaTrack]
    public var supportsDirectPlay: Bool
    /// Bitrate of the source in bits per second, as far as known.
    public var bitrate: Int?

    /// Whether the picture is interlaced (1080i, 576i).
    ///
    /// **Apple's engine does not deinterlace** (proven in VLC's own source code for
    /// VideoToolbox: "VT decoder doesn't handle deinterlacing on iOS"). An interlaced
    /// title does play there, but shows a comb pattern at every movement — that looks
    /// like a broken file, not like a format question. That is why it is here and not
    /// only in the metadata: the engine selection must be able to see it (schedule P11).
    ///
    /// `nil` means "not known" — with a channel, for instance, whose tracks are settled
    /// only on opening. Unknown does not count as interlaced: otherwise every title
    /// without a statement would needlessly take the expensive path.
    public var isInterlaced: Bool?

    /// Bit depth of the picture, as far as the server knows it.
    ///
    /// Needed for the one distinction that the codec name conceals: H.264 in ten bits —
    /// see ``videoNeedsSoftwareDecoding``.
    public var videoBitDepth: Int?

    public init(
        container: Container,
        videoCodec: String? = nil,
        videoRange: VideoRange = .sdr,
        audioTracks: [MediaTrack] = [],
        subtitleTracks: [MediaTrack] = [],
        supportsDirectPlay: Bool = true,
        bitrate: Int? = nil,
        isInterlaced: Bool? = nil,
        videoBitDepth: Int? = nil
    ) {
        self.container = container
        self.videoCodec = videoCodec
        self.videoRange = videoRange
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.supportsDirectPlay = supportsDirectPlay
        self.bitrate = bitrate
        self.isInterlaced = isInterlaced
        self.videoBitDepth = videoBitDepth
    }
}

/// A single audio, picture or subtitle track.
public struct MediaTrack: Sendable, Equatable, Hashable, Identifiable, Codable {

    public enum Kind: String, Sendable, Equatable, Codable {
        case video, audio, subtitle
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// Two-letter or three-letter language code, as the server reports it.
    public var language: String?
    public var codec: String?
    public var subtitleFormat: MediaSource.SubtitleFormat?
    public var isDefault: Bool

    /// Whether the track translates only the passages that even a native speaker does
    /// not understand — foreign-language dialogue, signs, sign language.
    ///
    /// **The difference is no trifle.** In a film with a scene in a foreign language the
    /// forced German track may carry a dozen captions, the full track next to it hundreds.
    /// Whoever lists both only as "German" turns a translation of a few lines into
    /// subtitling of the whole film — and vice versa.
    public var isForced: Bool

    /// Whether the track lies as its own file next to the film instead of in the
    /// container.
    ///
    /// Important for the choice at start, because external tracks at the server are
    /// often in image formats (DVDSUB from an `.idx`/`.sub` pair) and then expensive to
    /// fetch.
    public var isExternal: Bool

    /// Whether the track is intended for the hard of hearing (SDH/CC) — that is, it
    /// also transcribes sounds and speaker changes.
    ///
    /// Not evaluated anywhere so far; it comes along so that the information is not
    /// lost in the mapping and a later rule does not first have to pull it through all
    /// layers again.
    public var isHearingImpaired: Bool

    public init(
        id: String,
        kind: Kind,
        title: String,
        language: String? = nil,
        codec: String? = nil,
        subtitleFormat: MediaSource.SubtitleFormat? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false,
        isHearingImpaired: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.language = language
        self.codec = codec
        self.subtitleFormat = subtitleFormat
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
        self.isHearingImpaired = isHearingImpaired
    }

    /// Also reads snapshots that existed before the three attributes.
    ///
    /// ``ListSnapshotStore`` stores whole lists as JSON in the Caches directory, and
    /// after an app update the old files are still there. With the hand-built decoder
    /// the three missing keys would be an error, and the whole snapshot would be lost —
    /// the viewer would see loading bars again instead of lists on the first start after
    /// the update.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.kind = try values.decode(Kind.self, forKey: .kind)
        self.title = try values.decode(String.self, forKey: .title)
        self.language = try values.decodeIfPresent(String.self, forKey: .language)
        self.codec = try values.decodeIfPresent(String.self, forKey: .codec)
        self.subtitleFormat = try values.decodeIfPresent(
            MediaSource.SubtitleFormat.self, forKey: .subtitleFormat)
        self.isDefault = try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        self.isForced = try values.decodeIfPresent(Bool.self, forKey: .isForced) ?? false
        self.isExternal = try values.decodeIfPresent(Bool.self, forKey: .isExternal) ?? false
        self.isHearingImpaired =
            try values.decodeIfPresent(Bool.self, forKey: .isHearingImpaired) ?? false
    }
}

extension MediaSource {

    /// Whether Apple's engine can do the **picture codec** — independent of the
    /// container.
    ///
    /// Separate from ``isNativelyPlayable``, which checks both at once. For the question
    /// "is remuxing worth it?" only the content counts: the container is exactly what
    /// gets changed in the process.
    public var videoCodecIsNative: Bool {
        guard let videoCodec, !videoCodec.isEmpty else { return true }
        return Self.nativeVideoCodecs.contains(videoCodec.lowercased())
    }

    /// Whether among the subtitles there are any that only the native engine needs.
    ///
    /// Today none — Dolby Vision hangs on the picture, not on the subtitles. The query
    /// is nevertheless here and not a `false` in the caller: it names the place where
    /// such a condition belongs, should there ever be one.
    public var subtitleTracksNeedNative: Bool { videoRange == .dolbyVision }
}
