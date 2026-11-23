import Foundation

extension Matroska {

    // MARK: - Spuren

    public enum TrackKind: Sendable, Equatable {
        case video
        case audio
        case subtitle
        case other(Int)

        init(rawType: UInt64) {
            switch rawType {
            case 1: self = .video
            case 2: self = .audio
            case 17: self = .subtitle
            default: self = .other(Int(clamping: rawType))
            }
        }
    }

    /// How subtitles are present in this track.
    ///
    /// **Three kinds that have nothing in common:** text with timings (SRT), text with
    /// instructions for the appearance (ASS), and finished images that are laid over
    /// the picture (PGS, VobSub, DVBSUB). Only the first kind AVFoundation can handle
    /// by itself; the other two the app has to draw.
    public enum SubtitleFormat: Sendable, Equatable {
        case subrip
        case ass
        case pgs
        case vobsub
        case dvbsub
        case unknown(String)
    }

    public struct Track: Sendable, Equatable {
        public var number: Int
        public var kind: TrackKind
        public var codecID: String
        public var codecPrivate: Data?
        public var language: String
        public var name: String?
        /// Whether the track is to be chosen without any action.
        ///
        /// **If the field is missing, "yes" applies.** That is not an interpretation but
        /// the format's default value — and it reverses the obvious assumption: whoever
        /// substitutes `false` for a missing field finds **no** default track in a file
        /// with three audio tracks and not a single marking, and starts without audio.
        public var isDefault: Bool

        /// Whether the track translates only the passages that are not understandable.
        ///
        /// **Stays here and does not migrate to ``MediaTrack``.** This track table is read
        /// exclusively by the remuxer, which writes picture and one audio track into an MP4
        /// container; it does not touch subtitles. The track list that menu and start
        /// choice see always comes from the server (``PlayerModel/refreshTrackLists(from:)``)
        /// — and `IsForced` has been there since 2026-08-28. A second path into the same field
        /// would thus have no reader, only two truths.
        public var isForced: Bool
        public var width: Int?
        public var height: Int?
        public var sampleRate: Int?
        public var channels: Int?
        /// How long a picture lasts, in nanoseconds — if the file says so.
        public var defaultDuration: UInt64?
        /// Whether the content is compressed or encrypted.
        ///
        /// **For picture and audio this does not occur, for subtitles constantly** — in the
        /// test files exactly the PGS tracks carry this field, because caption images
        /// compress well. Whoever overlooks it sends the renderer a zlib packet instead of
        /// an image.
        public var isEncoded: Bool

        /// What this track's codec is in the language of the transport stream.
        ///
        /// **That way both readers flow into the same exit.** Whether an identifier comes
        /// from a PMT table or from a `CodecID` text is irrelevant from here on — and the
        /// answer to "can the hardware do that?" exists only once.
        public var stream: TransportStream.StreamKind? {
            switch codecID {
            case "V_MPEGH/ISO/HEVC": .hevc
            case "V_MPEG4/ISO/AVC": .h264
            case "V_MPEG2": .mpeg2Video
            case let id where id.hasPrefix("A_AAC"): .aac
            case "A_AC3": .ac3
            case "A_EAC3": .eac3
            case let id where id.hasPrefix("A_MPEG"): .mp2Audio
            case "A_DTS": .dts
            default: nil
            }
        }

        /// Whether the hardware decodes **this** picture track — codec and profile.
        ///
        /// **The codec alone is not enough** (on-device finding 2026-08-15, Woujeinspes Skutgro):
        /// for the hardware H.264 means "eight bit, chroma 4:2:0" — Hi10P and the 4:2:2/4:4:4
        /// profiles carry the same codec name and still stay black. The profile is in the
        /// second byte of the `avcC` header; what **works** is enumerated, everything
        /// unknown counts as "cannot do it" — a wrongly rejected profile ends up in VLC and
        /// plays, a wrongly accepted one stays black.
        ///
        /// For HEVC the codec alone still decides: the hardware can do Main10, every HDR
        /// video is encoded that way.
        public var isVideoHardwareDecodable: Bool {
            guard let stream, stream.isHardwareDecodable else { return false }
            guard stream == .h264 else { return true }
            // Without an avcC header the profile cannot be checked — then the parameter sets
            // are in the picture stream (as in the channel case), and there Hi10P is
            // practically unknown. The codec verdict stands.
            guard let codecPrivate, codecPrivate.count >= 2 else { return true }
            return Self.hardwareH264Profiles.contains(codecPrivate[codecPrivate.startIndex + 1])
        }

        /// The `profile_idc` values that Apple's H.264 hardware decodes: Baseline (66),
        /// Main (77), Extended (88), High (100).
        static let hardwareH264Profiles: Set<UInt8> = [66, 77, 88, 100]

        /// Palette and canvas of a VobSub track.
        ///
        /// **The `.idx` is in the track header.** With VobSub in MKV, `CodecPrivate` is
        /// nothing other than the text of the `.idx` file that lay next to the `.sub` on
        /// the DVD — including the palette and the canvas size. The server does not hand
        /// out the `.idx` (400), the file it does; and its header is in the first
        /// kilobytes.
        public var vobSubIndex: (palette: [UInt32], width: Int?, height: Int?)? {
            guard subtitleFormat == .vobsub, let codecPrivate else { return nil }
            return Matroska.vobSubIndex(inCodecPrivate: codecPrivate)
        }

        public var subtitleFormat: SubtitleFormat? {
            guard kind == .subtitle else { return nil }
            return switch codecID {
            case "S_TEXT/UTF8", "S_TEXT/ASCII": .subrip
            case "S_TEXT/ASS", "S_TEXT/SSA": .ass
            case "S_HDMV/PGS": .pgs
            case "S_VOBSUB": .vobsub
            case "S_DVBSUB": .dvbsub
            default: .unknown(codecID)
            }
        }
    }

    /// What is in the file's header — everything that is settled before the first
    /// picture.
    public struct Header: Sendable, Equatable {
        public var tracks: [Track] = []
        /// Nanoseconds per time unit. Almost always one million, i.e. milliseconds — but
        /// only almost always, and whoever does not read the value gets a factor wrong with
        /// the other files.
        public var timestampScale: UInt64 = 1_000_000
        /// Total length in time units, if the file states it.
        public var duration: Double?

        public var video: Track? { tracks.first { $0.kind == .video } }

        /// The frame rate of the file, if the track table states it.
        ///
        /// **`defaultDuration` was always read, never used** — until 2026-08-23 the value was in
        /// the header and picked up by no one. It is needed here: the file remuxer passed no
        /// frame rate to the engine, unlike both live paths, and therefore in 39 s of Blupriatio
        /// Gufaidia there was not a single line "frame rate registered". Without it the TV
        /// cannot set its output to the content — 25 pictures on 60 Hz give the cadence
        /// 2-2-3-2-3, i.e. even slight stutter with zero dropouts and zero discarded
        /// pictures. Exactly the picture the diagnosis showed.
        ///
        /// `defaultDuration` is nanoseconds per picture.
        public var frameRate: Double? {
            guard let nanoseconds = video?.defaultDuration, nanoseconds > 0 else { return nil }
            let rate = 1_000_000_000.0 / Double(nanoseconds)
            // Better to withhold nonsensical values than to register them: a wrong value sets
            // the TV to something that the content is not.
            return (1...480).contains(rate) ? rate : nil
        }
        public var audioTracks: [Track] { tracks.filter { $0.kind == .audio } }
        public var subtitleTracks: [Track] { tracks.filter { $0.kind == .subtitle } }

        /// The audio track that is started with when nobody says otherwise.
        public var preferredAudio: Track? {
            audioTracks.first { $0.isDefault } ?? audioTracks.first
        }

        /// A line for the report — "HEVC + AAC".
        public var summary: String {
            let parts = [video?.stream?.name, preferredAudio?.stream?.name].compactMap { $0 }
            return parts.isEmpty ? "empty" : parts.joined(separator: " + ")
        }

        /// Whether picture and chosen audio are both decoded by the hardware.
        public var isFullyHardwareDecodable: Bool {
            guard video?.isVideoHardwareDecodable == true else { return false }
            guard let audio = preferredAudio else { return true }
            return audio.stream?.isHardwareDecodable ?? false
        }
    }

    // MARK: - Kopf lesen

    /// Reads the header from the start of a file.
    ///
    /// **A few hundred kilobytes suffice.** What is needed here is in front of the
    /// first cluster in every common file — so one does not have to load three
    /// gigabytes to find out whether a title can be remuxed.
    ///
    /// `nil` if there was no track table yet in this start.
    public static func header(from data: Data) -> Header? {
        let reader = MatroskaReader()
        _ = reader.read(data)
        return reader.header.tracks.isEmpty ? nil : reader.header
    }

    /// Reads the track table from a `Tracks` element.
    static func tracks(inTracksElement data: Data) -> [Track] {
        children(of: data).compactMap { child in
            guard child.id == ID.trackEntry else { return nil }
            return track(inTrackEntry: data.subdata(in: child.range))
        }
    }

    /// Which sample rates the track table may state.
    ///
    /// **From the file, hence a claim** (remuxer check B4, 2026-09-27): `NaN` stopped
    /// the process when rounding, and a huge rate later when converting to
    /// `CMTimeScale`. What lies outside counts as not stated — the remuxer then takes
    /// the rate from the audio frame or the default.
    static let audibleRates = 1...768_000

    static func track(inTrackEntry data: Data) -> Track? {
        var number: Int?
        var kind: TrackKind?
        var codecID: String?
        var track = Track(
            number: 0, kind: .other(0), codecID: "", codecPrivate: nil,
            language: "und", name: nil, isDefault: true, isForced: false,
            width: nil, height: nil, sampleRate: nil, channels: nil,
            defaultDuration: nil, isEncoded: false
        )

        for child in children(of: data) {
            let body = data.subdata(in: child.range)
            switch child.id {
            case ID.trackNumber: number = NetNumber.total(unsigned(body))
            case ID.trackType: kind = TrackKind(rawType: unsigned(body))
            case ID.codecID: codecID = text(body)
            case ID.codecPrivate: track.codecPrivate = body
            case ID.language: track.language = text(body)
            // The newer language field beats the old one where both are present.
            case ID.languageBCP47: track.language = text(body)
            case ID.trackName: track.name = text(body)
            case ID.flagDefault: track.isDefault = unsigned(body) != 0
            case ID.flagForced: track.isForced = unsigned(body) != 0
            case ID.defaultDuration: track.defaultDuration = unsigned(body)
            case ID.contentEncodings: track.isEncoded = true
            case ID.video:
                for field in children(of: body) {
                    let value = NetNumber.total(unsigned(body.subdata(in: field.range)))
                    if field.id == ID.pixelWidth { track.width = value }
                    if field.id == ID.pixelHeight { track.height = value }
                }
            case ID.audio:
                for field in children(of: body) {
                    let raw = body.subdata(in: field.range)
                    if field.id == ID.samplingFrequency {
                        track.sampleRate = float(raw).flatMap(NetNumber.roundedValue).flatMap {
                            audibleRates.contains($0) ? $0 : nil
                        }
                    }
                    if field.id == ID.channels {
                        track.channels = NetNumber.total(unsigned(raw)).flatMap {
                            (1...255).contains($0) ? $0 : nil
                        }
                    }
                }
            default: break
            }
        }

        guard let number, let kind, let codecID else { return nil }
        track.number = number
        track.kind = kind
        track.codecID = codecID
        return track
    }

    /// Reads time unit and length from an `Info` element.
    static func info(inInfoElement data: Data) -> (scale: UInt64?, duration: Double?) {
        var scale: UInt64?
        var duration: Double?
        for child in children(of: data) {
            let body = data.subdata(in: child.range)
            if child.id == ID.timestampScale {
                scale = NetNumber.int64(unsigned(body)).map { UInt64($0) }
            }
            if child.id == ID.duration {
                duration = float(body).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
        }
        return (scale, duration)
    }

    /// Reads palette and canvas from the text of an `.idx`.
    ///
    /// **The colors are stated there as YCbCr, drawing is done in RGB.** Without the
    /// conversion the subtitles are not only wrongly colored but regularly invisible: a
    /// gray of 0x808080 in YCbCr is mid gray, read as RGB likewise — but white
    /// (0xEB8080) would be a dull blue-gray on a light background.
    static func vobSubIndex(
        inCodecPrivate data: Data
    )
        -> (palette: [UInt32], width: Int?, height: Int?)?
    {
        let text = String(decoding: data, as: UTF8.self)
        var palette: [UInt32] = []
        var width: Int?
        var height: Int?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("palette:") {
                palette = trimmed.dropFirst("palette:".count)
                    .components(separatedBy: ",")
                    .compactMap { UInt32($0.trimmingCharacters(in: .whitespaces), radix: 16) }
                    .map(rgb(fromYCbCr:))
            }
            if trimmed.hasPrefix("size:") {
                let parts = trimmed.dropFirst("size:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: "x")
                if parts.count == 2 {
                    width = Int(parts[0])
                    height = Int(parts[1])
                }
            }
        }
        guard !palette.isEmpty || width != nil else { return nil }
        return (palette, width, height)
    }

    static func rgb(fromYCbCr value: UInt32) -> UInt32 {
        let y = Double((value >> 16) & 0xFF)
        let cb = Double((value >> 8) & 0xFF) - 128
        let cr = Double(value & 0xFF) - 128

        func clamp(_ value: Double) -> UInt32 {
            UInt32(max(0, min(255, value.rounded())))
        }
        let red = clamp(y + 1.402 * cr)
        let green = clamp(y - 0.344136 * cb - 0.714136 * cr)
        let blue = clamp(y + 1.772 * cb)
        return red << 16 | green << 8 | blue
    }

    /// The direct children of an element, as identifier and range.
    ///
    /// **Only for elements that are fully present** — track table, header data, group
    /// of pictures. Everything large goes the way via ``MatroskaReader``, which does
    /// not have to wait.
    static func children(of data: Data) -> [(id: UInt32, range: Range<Int>)] {
        var result: [(id: UInt32, range: Range<Int>)] = []
        var offset = 0
        while offset < data.count {
            guard let element = element(in: data, at: offset), let size = element.size else { break }
            let start = offset + element.headerSize
            let end = start + size
            guard end <= data.count else { break }
            result.append((element.id, (data.startIndex + start)..<(data.startIndex + end)))
            offset = end
        }
        return result
    }
}
