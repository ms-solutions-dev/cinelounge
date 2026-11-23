import AVFoundation
import CoreMedia
import Foundation

/// Writes fragmented MP4 **itself** — header segment and pieces of any length.
///
/// **Why there is a second writer next to ``FragmentWriter``** (2026-09-03, diagnosis F-003):
/// `AVAssetWriter` demands in the HLS profile that every piece begin with a keyframe — after a
/// cut it otherwise dies with `-11876`, confirmed on a channel (see
/// ``TransportRemuxer/flushSegment()``). A piece is thus as long as the distance between two
/// keyframes, and for the UHD channels that is ten seconds. Two of them had to be in place
/// before the engine got the address: twenty seconds of broadcast, 5.0 s median until the
/// picture.
///
/// HLS itself does not demand this. A piece may begin in the middle of a group of pictures, as
/// long as the playlist does not promise `EXT-X-INDEPENDENT-SEGMENTS` — exactly how the parts
/// of Low-Latency HLS work. Only the writer did not want it. So this one writes the boxes
/// itself: `moof` and `mdat` every half second, at any sample, and the keyframe additionally
/// forces a cut, so that every group of pictures begins at a piece boundary — the playlist can
/// then always start at a keyframe.
///
/// **What it writes, and what not.** Picture as `hvc1`/`avc1` with the descriptions from the
/// format description, audio as `mp4a` (AAC) or `ac-3`/`ec-3`, plus color space and field
/// marker where the description carries them. No subtitles, no chapters, no seek tables: This
/// is a writer for a running channel, not for a file.
///
/// **Picture and audio per piece, with their own timing.** Each track has its own `tfdt`; the
/// pieces need not be cut at the same instant between the tracks. The audio goes out with the
/// picture that is being cut right now — whatever still arrives for that picture afterwards
/// goes into the next piece. The player does not care: It reads one continuous time per track.
public final class CMAFWriter: SampleSink, @unchecked Sendable {

    /// A finished piece.
    public struct Segment: Sendable {
        public let isInitialization: Bool
        public let data: Data
        /// How long the piece is, in seconds of picture.
        public let duration: Double
        /// Whether it begins with a keyframe — then the playlist may start here, and a part may carry
        /// `INDEPENDENT=YES`.
        public let startsWithKeyframe: Bool
    }

    /// From which length cutting happens — at any sample, not only at the keyframe.
    ///
    /// **Half a second.** Three of them are the startup reserve of the HLS route (see
    /// ``LiveRemuxSession/defaultReadySegments``), so one and a half seconds of broadcast instead
    /// of twenty — and the provider burst delivers them in under a second. Shorter would gain
    /// nothing more: The player fetches the playlist at the rhythm of the target duration, and it
    /// rounds up to a second anyway.
    public static let fragmentDuration = CMTime(value: 1, timescale: 2)

    /// From which distance between two pictures a hole in the stream is assumed.
    ///
    /// **The finding F-004 (2026-09-03, Ayaz HD\*):** Pieces of 2.2 s and 5.3 s on a channel whose
    /// timestamps jump. A piece spanned the gap, stood as a part of 2.2 s in a playlist that
    /// promises 0.6 s — and AVPlayer rejected the playlist (`-12642`) before it loaded a byte. A
    /// gap is therefore a piece boundary: The piece before it ends with an ordinary picture
    /// duration, the one after begins with its own time (`tfdt`), and the player sees a hole
    /// instead of a giant.
    public static let gapThreshold = CMTime(value: 1, timescale: 2)

    /// **The shortest piece duration.** A keyframe opens a new piece — but not if the running one
    /// has only just begun. Some channels (TELE MOOS HQ, SELA 1 HQ, Rendal UP HQ, 2026-09-04) put two
    /// keyframes close together, at scene cuts or as a double IDR; without this limit a mini piece
    /// of 0.04 s arose from it. At the live edge such a mini piece threw AVPlayer out of rhythm —
    /// it stuttered although the material was gapless (probe on the Mac: TELE MOOS 3 stalls, Varo and
    /// Kanal Dere 0, with the same recording). The second keyframe then stays in the running piece;
    /// that is valid, because the piece begins

    public enum Failure: Error, Equatable {
        case unsupportedVideo
        case unsupportedAudio
        case missingCodecConfiguration
    }

    private let lock = NSLock()
    private let onSegment: @Sendable (Segment) -> Void
    private let cutAfter: CMTime
    private let video: TrackLayout
    private let audio: TrackLayout?
    private var sequence: UInt32 = 1

    /// A picture waiting for its piece — with everything `trun` needs.
    private struct PendingVideo {
        let decode: CMTime
        let presentation: CMTime
        let isSync: Bool
        let data: Data
    }
    private struct PendingAudio {
        let presentation: CMTime
        let duration: CMTime
        let data: Data
    }
    private var pendingVideo: [PendingVideo] = []
    private var pendingAudio: [PendingAudio] = []
    /// The start of the running piece in decode time.
    private var fragmentStart: CMTime?
    /// The decode time of the last picture — for the duration of a piece's last picture, when
    /// cutting at a drop without a successor.
    private var lastDuration: CMTime?
    private var _failure: Error?

    /// - Parameters:
    ///   - format: The picture description with its `hvcC`/`avcC` atoms — it arises from the
    ///     parameter sets of the stream.
    ///   - audioFormat: The audio description, or `nil` for a silent channel.
    ///   - fragmentDuration: See ``fragmentDuration``.
    ///   - onSegment: Receives first the header segment, then every piece.
    ///   - videoTimescale: The time base of the picture track. **90 000 for channels**; for
    ///     files the base in which a picture comes out as an integer
    ///     (``TimeGrid/timebase``, 24000 at 23.976 Hz). In 90 000 a picture there would be
    ///     3753.75 ticks — the durations would alternate between 3753 and 3754, again a cadence
    ///     instead of a beat (F-005).
    public init(
        format: CMFormatDescription,
        audioFormat: CMFormatDescription? = nil,
        fragmentDuration: CMTime = CMAFWriter.fragmentDuration,
        videoTimescale: CMTimeScale = SampleAssembly.timescale,
        onSegment: @escaping @Sendable (Segment) -> Void
    ) throws {
        self.onSegment = onSegment
        cutAfter = fragmentDuration
        video = try TrackLayout.video(from: format, trackID: 1, timescale: UInt32(max(1, videoTimescale)))
        audio = try audioFormat.map { try TrackLayout.audio(from: $0, trackID: 2) }

        // The header stands immediately — it depends only on the descriptions, not on the content.
        // That makes the downloads complete from the first piece on.
        let header = Self.initializationSegment(video: video, audio: audio)
        onSegment(Segment(isInitialization: true, data: header, duration: 0, startsWithKeyframe: false))
    }

    // MARK: - SampleSink

    public var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _failure
    }

    @discardableResult
    public func append(video sample: CMSampleBuffer) -> Bool {
        guard let data = Self.bytes(of: sample) else { return false }
        let presentation = sample.presentationTimeStamp
        let decode = sample.decodeTimeStamp.isValid ? sample.decodeTimeStamp : presentation
        let isSync = FragmentWriter.isKeyframe(sample)

        lock.lock()
        defer { lock.unlock() }

        // **The cut comes before the picture.** A keyframe always opens a new piece; any other
        // picture does so when the running piece is long enough. The picture that triggers the cut is
        // the first of the new piece — the previous ones thus all know their duration.
        let gap = pendingVideo.last.map { decode - $0.decode }
        let isGap = gap.map { $0 > Self.gapThreshold || $0 < .zero } ?? false
        if isGap, let gap { noteGap(gap, at: decode) }
        if let start = fragmentStart, !pendingVideo.isEmpty,
            isSync || isGap || (cutAfter.isNumeric && (decode - start) >= cutAfter)
        {
            // Before a gap the piece ends with an ordinary duration — not with the gap. See
            // ``gapThreshold``.
            flush(upTo: isGap ? nil : decode)
        }
        if fragmentStart == nil { fragmentStart = decode }
        if let gap, !isGap { lastDuration = gap }
        pendingVideo.append(
            PendingVideo(decode: decode, presentation: presentation, isSync: isSync, data: data))
        return true
    }

    /// How many audio packets at most wait while no picture comes.
    ///
    /// **Audio is written out only together with pictures** — a piece begins at a picture. If a
    /// channel loses its picture track, ``append(audio:)`` collected here without end (remuxer
    /// check, suspicion 2, 2026-09-27): Memory grew, and nothing went out. 3000 packets are a good
    /// minute for AAC, a minute and a half for AC-3 — far more than ever lies between two
    /// pictures. Above that the oldest drops out, half of it in one go, so that not every further
    /// packet shifts the whole list.
    /// **The cap applied only while ``pendingVideo`` was empty** (remuxer check, finding 2,
    /// 2026-09-27): If a channel lost the picture without the running piece ever being completed
    /// (leftover pictures stayed in ``pendingVideo`` because no further keyframe came),
    /// `pendingVideo.isEmpty` stayed `false` forever — and the audio still grew without limit, the
    /// same memory effect as suspicion V2 above, only with a standing residual load instead of no
    /// picture at all. The cap now applies to the total count, regardless of whether a picture is
    /// still pending.
    static let audioMaximumWithoutPicture = 3000

    /// How many audio packets were discarded because of ``audioMaximumWithoutPicture``.
    public private(set) var audioDiscardedWithoutPicture = 0

    /// How many audio packets are currently waiting for a picture — for the checks.
    var waitingAudio: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingAudio.count
    }

    @discardableResult
    public func append(audio sample: CMSampleBuffer) -> Bool {
        guard audio != nil, let data = Self.bytes(of: sample) else { return false }
        lock.lock()
        defer { lock.unlock() }
        pendingAudio.append(
            PendingAudio(
                presentation: sample.presentationTimeStamp,
                duration: sample.duration.isNumeric ? sample.duration : .zero,
                data: data))
        if pendingAudio.count > Self.audioMaximumWithoutPicture {
            let route = pendingAudio.count - Self.audioMaximumWithoutPicture / 2
            pendingAudio.removeFirst(route)
            audioDiscardedWithoutPicture += route
        }
        return true
    }

    /// On a drop: What is there goes out as a piece — with the last seen picture duration for the
    /// last picture, because there is no successor any more.
    public func discontinuity() {
        lock.lock()
        defer { lock.unlock() }
        guard !pendingVideo.isEmpty else { return }
        flush(upTo: nil)
    }

    // MARK: - Quantifying gaps

    /// How many gaps the writer turned into a piece boundary, and the largest.
    ///
    /// **F-006, "DE: TELE MOOS HQ":** four jumps of the player in 66 s, and the clock saw nothing —
    /// gaps below its threshold, above the writer's. Before anyone turns a threshold, the gaps
    /// should have a size: the first three individually in the trace, the sum at the end.
    public private(set) var gapCount = 0
    public private(set) var largestGap: CMTime = .zero
    private var firstDecode: CMTime?
    static let gapsReportedIndividually = 3

    private func noteGap(_ gap: CMTime, at decode: CMTime) {
        gapCount += 1
        if gap > largestGap { largestGap = gap }
        if firstDecode == nil { firstDecode = pendingVideo.first?.decode ?? decode }
        guard gapCount <= Self.gapsReportedIndividually else { return }
        let location = firstDecode.map { (decode - $0).seconds } ?? 0
        let row = String(
            format: "Gap in picture: %@%.2f s at %.1f s — segment boundary",
            gap < .zero ? "−" : "+", abs(gap.seconds), location)
        Diagnostics.playbackStep(row, since: nil)
    }

    private var declaredSeconds: Double = 0
    private var timelineStart: CMTime?
    private var timelineEnd: CMTime?

    /// The writer's tally for the trace: gaps, and whether the playlist's durations fit the time
    /// axis. **The suspicion on TELE MOOS HQ** (F-001, 2026-09-04): Jumps of the player without a gap in
    /// the picture — then the sum of the promised durations perhaps does not match the stamps, and
    /// AVPlayer catches up on the time.
    public var gapBalance: String? {
        lock.lock()
        defer { lock.unlock() }
        var split: [String] = []
        if audioDiscardedWithoutPicture > 0 {
            split.append("Audio without picture: \(audioDiscardedWithoutPicture) packets discarded")
        }
        if gapCount > 0 {
            split.append(
                "Gaps in picture: \(gapCount), largest \(String(format: "%.2f", largestGap.seconds)) s")
        }
        if let start = timelineStart, let end = timelineEnd, declaredSeconds > 0 {
            let axis = (end - start).seconds
            let drift = declaredSeconds - axis
            if abs(drift) >= 0.25 {
                split.append(
                    String(
                        format: "Segment durations %.1f s against timeline %.1f s (%+.2f s)", declaredSeconds,
                        axis, drift))
            }
        }
        return split.isEmpty ? nil : split.joined(separator: "; ")
    }

    public func finish() async {
        discontinuity()
        if let gapBalance { Diagnostics.playbackStep(gapBalance, since: nil) }
    }

    // MARK: - Schneiden

    /// Writes all waiting pictures and audio packets as one piece.
    ///
    /// - Parameter end: The decode time of the first picture of the NEXT piece — it is the end of
    ///   the last picture here. `nil` if there is no successor (drop) or it lies behind a gap:
    ///   Then the last picture gets the last seen picture duration.
    private func flush(upTo end: CMTime?) {
        guard let first = pendingVideo.first else { return }
        let pictures = pendingVideo
        let sounds = pendingAudio
        pendingVideo.removeAll()
        pendingAudio.removeAll()
        fragmentStart = nil

        let typical = lastDuration ?? Self.fallbackFrameDuration
        var durations: [CMTime] = []
        for (index, picture) in pictures.enumerated() {
            let next = index + 1 < pictures.count ? pictures[index + 1].decode : end
            durations.append(next.map { $0 - picture.decode } ?? typical)
        }
        let seconds = durations.reduce(CMTime.zero, +).seconds
        // For the tally: What the playlist promises in durations, against the time axis of the
        // pictures — see ``balance``.
        declaredSeconds += seconds.isFinite && seconds > 0 ? seconds : cutAfter.seconds
        if timelineStart == nil { timelineStart = first.decode }
        timelineEnd = end ?? pictures.last.map { $0.decode + typical }

        let fragment = Self.mediaSegment(
            sequence: sequence, video: video, pictures: pictures, durations: durations,
            audio: audio, sounds: sounds)
        sequence += 1

        onSegment(
            Segment(
                isInitialization: false, data: fragment,
                duration: seconds.isFinite && seconds > 0 ? seconds : cutAfter.seconds,
                startsWithKeyframe: first.isSync))
    }

    /// A picture at 25 per second — if no duration has been measured yet.
    static let fallbackFrameDuration = CMTime(value: 3600, timescale: 90_000)

    /// The raw bytes of a packet — copied, because the buffer belongs to CoreMedia.
    static func bytes(of sample: CMSampleBuffer) -> Data? {
        guard let block = sample.dataBuffer else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == noErr ? data : nil
    }

    // MARK: - Die Spuren

    /// What the header must say about a track — read from the format description, once at setup.
    struct TrackLayout {
        let trackID: UInt32
        let timescale: UInt32
        let isVideo: Bool
        /// The finished `stsd` entry: `hvc1`, `avc1`, `mp4a`, `ac-3`, `ec-3`.
        let sampleEntry: Data
        let width: UInt16
        let height: UInt16

        static func video(
            from format: CMFormatDescription, trackID: UInt32,
            timescale: UInt32 = UInt32(SampleAssembly.timescale)
        ) throws -> TrackLayout {
            let entryName: String
            let configName: String
            switch format.mediaSubType {
            case .hevc:
                entryName = "hvc1"
                configName = "hvcC"
            case .h264:
                entryName = "avc1"
                configName = "avcC"
            default:
                throw Failure.unsupportedVideo
            }
            guard let config = Self.extensionAtom(configName, in: format) else {
                throw Failure.missingCodecConfiguration
            }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            let width = UInt16(clamping: Int(size.width))
            let height = UInt16(clamping: Int(size.height))

            var inner = Box.plain(configName, config)
            if let colr = Self.colorBox(for: format) { inner.append(colr) }
            if let fiel = Self.fieldBox(for: format) { inner.append(fiel) }

            var entry = Data()
            entry.append(contentsOf: [UInt8](repeating: 0, count: 6))  // reserved
            entry.append(u16: 1)  // data_reference_index
            entry.append(contentsOf: [UInt8](repeating: 0, count: 16))  // pre_defined, reserved
            entry.append(u16: width)
            entry.append(u16: height)
            entry.append(u32: 0x0048_0000)  // horizresolution 72 dpi
            entry.append(u32: 0x0048_0000)  // vertresolution
            entry.append(u32: 0)  // reserved
            entry.append(u16: 1)  // frame_count
            entry.append(contentsOf: [UInt8](repeating: 0, count: 32))  // compressorname
            entry.append(u16: 0x0018)  // depth
            entry.append(u16: 0xFFFF)  // pre_defined
            entry.append(inner)

            return TrackLayout(
                trackID: trackID, timescale: timescale, isVideo: true,
                sampleEntry: Box.plain(entryName, entry), width: width, height: height)
        }

        static func audio(from format: CMFormatDescription, trackID: UInt32) throws -> TrackLayout {
            guard let asbd = format.audioStreamBasicDescription else {
                throw Failure.unsupportedAudio
            }
            let sampleRate = UInt32(asbd.mSampleRate.rounded())
            let channels = UInt16(clamping: Int(asbd.mChannelsPerFrame))

            let entryName: String
            let inner: Data
            switch asbd.mFormatID {
            case kAudioFormatMPEG4AAC:
                entryName = "mp4a"
                guard
                    let config = AudioAssembly.audioSpecificConfig(
                        sampleRate: Int(sampleRate), channels: Int(channels))
                else { throw Failure.missingCodecConfiguration }
                inner = Self.esdsBox(audioSpecificConfig: config)
            case kAudioFormatAC3:
                entryName = "ac-3"
                guard let config = Self.extensionAtom("dac3", in: format) else {
                    throw Failure.missingCodecConfiguration
                }
                inner = Box.plain("dac3", config)
            case kAudioFormatEnhancedAC3:
                entryName = "ec-3"
                guard let config = Self.extensionAtom("dec3", in: format) else {
                    throw Failure.missingCodecConfiguration
                }
                inner = Box.plain("dec3", config)
            default:
                throw Failure.unsupportedAudio
            }

            var entry = Data()
            entry.append(contentsOf: [UInt8](repeating: 0, count: 6))  // reserved
            entry.append(u16: 1)  // data_reference_index
            entry.append(contentsOf: [UInt8](repeating: 0, count: 8))  // version, revision, vendor
            entry.append(u16: channels)
            entry.append(u16: 16)  // samplesize
            entry.append(u16: 0)  // pre_defined
            entry.append(u16: 0)  // reserved
            entry.append(u32: sampleRate << 16)
            entry.append(inner)

            return TrackLayout(
                trackID: trackID, timescale: sampleRate, isVideo: false,
                sampleEntry: Box.plain(entryName, entry), width: 0, height: 0)
        }

        /// An atom from the description extensions — `hvcC`, `avcC`, `dac3`.
        static func extensionAtom(_ name: String, in format: CMFormatDescription) -> Data? {
            guard
                let atoms = CMFormatDescriptionGetExtension(
                    format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                    as? [String: Any]
            else { return nil }
            return atoms[name] as? Data
        }

        /// `colr` as `nclx`, where the description knows the color space.
        ///
        /// Without this box the player would assume BT.709 — on a BT.2020 channel the colors would then
        /// be wrong without anything reporting an error.
        static func colorBox(for format: CMFormatDescription) -> Data? {
            func code(_ key: CFString, _ table: [CFString: UInt16]) -> UInt16? {
                guard
                    let value = CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
                else { return nil }
                return table.first { ($0.key as String) == value }?.value
            }
            let primaries = code(
                kCMFormatDescriptionExtension_ColorPrimaries,
                [
                    kCMFormatDescriptionColorPrimaries_ITU_R_709_2: 1,
                    kCMFormatDescriptionColorPrimaries_EBU_3213: 5,
                    kCMFormatDescriptionColorPrimaries_SMPTE_C: 6,
                    kCMFormatDescriptionColorPrimaries_ITU_R_2020: 9,
                    kCMFormatDescriptionColorPrimaries_P3_D65: 12,
                ])
            let transfer = code(
                kCMFormatDescriptionExtension_TransferFunction,
                [
                    kCMFormatDescriptionTransferFunction_ITU_R_709_2: 1,
                    kCMFormatDescriptionTransferFunction_SMPTE_240M_1995: 7,
                    kCMFormatDescriptionTransferFunction_ITU_R_2020: 14,
                    kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ: 16,
                    kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG: 18,
                ])
            let matrix = code(
                kCMFormatDescriptionExtension_YCbCrMatrix,
                [
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2: 1,
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4: 6,
                    kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995: 7,
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_2020: 9,
                ])
            guard let primaries, let transfer, let matrix else { return nil }
            var body = Data("nclx".utf8)
            body.append(u16: primaries)
            body.append(u16: transfer)
            body.append(u16: matrix)
            body.append(0)  // full_range_flag 0 + reserved
            return Box.plain("colr", body)
        }

        /// `fiel`, if the stream carries fields — the information with which
        /// ``SampleAssembly/withFields(_:)`` equips the description.
        static func fieldBox(for format: CMFormatDescription) -> Data? {
            guard
                let count = CMFormatDescriptionGetExtension(
                    format, extensionKey: kCMFormatDescriptionExtension_FieldCount) as? Int,
                count == 2
            else { return nil }
            // 2 fields; detail 9 means: spatially first line first (top first).
            return Box.plain("fiel", Data([2, 9]))
        }

        /// The `esds` box for AAC — the description tree that MP4 wants for it.
        static func esdsBox(audioSpecificConfig config: Data) -> Data {
            var decoderSpecific = Data([0x05, UInt8(config.count)])
            decoderSpecific.append(config)

            var decoderConfig = Data([0x40, 0x15])  // AAC, Tonstrom
            decoderConfig.append(contentsOf: [0, 0, 0])  // bufferSizeDB
            decoderConfig.append(u32: 0)  // maxBitrate
            decoderConfig.append(u32: 0)  // avgBitrate
            decoderConfig.append(decoderSpecific)

            var es = Data([0x00, 0x01, 0x00])  // ES_ID 1, no flags
            es.append(Data([0x04, UInt8(decoderConfig.count)]))
            es.append(decoderConfig)
            es.append(Data([0x06, 0x01, 0x02]))  // SLConfig: MP4

            var body = Data([0, 0, 0, 0])  // FullBox: version 0, flags 0
            body.append(Data([0x03, UInt8(es.count)]))
            body.append(es)
            return Box.plain("esds", body)
        }
    }

    // MARK: - Das Kopfsegment

    static func initializationSegment(video: TrackLayout, audio: TrackLayout?) -> Data {
        var ftyp = Data("iso6".utf8)
        ftyp.append(u32: 1)
        ftyp.append(Data("iso6isommp41".utf8))

        var moov = Data()
        moov.append(mvhd(nextTrackID: (audio == nil ? 2 : 3)))
        moov.append(trak(video))
        if let audio { moov.append(trak(audio)) }
        var mvex = trex(video.trackID)
        if let audio { mvex.append(trex(audio.trackID)) }
        moov.append(Box.plain("mvex", mvex))

        var out = Box.plain("ftyp", ftyp)
        out.append(Box.plain("moov", moov))
        return out
    }

    private static func mvhd(nextTrackID: UInt32) -> Data {
        var body = Data([0, 0, 0, 0])  // version, flags
        body.append(u32: 0)  // creation_time
        body.append(u32: 0)  // modification_time
        body.append(u32: 1000)  // timescale
        body.append(u32: 0)  // duration — a channel has none
        body.append(u32: 0x0001_0000)  // rate 1.0
        body.append(u16: 0x0100)  // volume 1.0
        body.append(contentsOf: [UInt8](repeating: 0, count: 10))  // reserved
        body.append(unityMatrix)
        body.append(contentsOf: [UInt8](repeating: 0, count: 24))  // pre_defined
        body.append(u32: nextTrackID)
        return Box.plain("mvhd", body)
    }

    private static var unityMatrix: Data {
        var matrix = Data()
        for value in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] as [UInt32] {
            matrix.append(u32: value)
        }
        return matrix
    }

    private static func trak(_ track: TrackLayout) -> Data {
        var tkhd = Data([0, 0, 0, 7])  // version 0, flags: enabled, in movie, in preview
        tkhd.append(u32: 0)  // creation_time
        tkhd.append(u32: 0)  // modification_time
        tkhd.append(u32: track.trackID)
        tkhd.append(u32: 0)  // reserved
        tkhd.append(u32: 0)  // duration
        tkhd.append(contentsOf: [UInt8](repeating: 0, count: 8))  // reserved
        tkhd.append(u16: 0)  // layer
        tkhd.append(u16: track.isVideo ? 0 : 1)  // alternate_group
        tkhd.append(u16: track.isVideo ? 0 : 0x0100)  // volume
        tkhd.append(u16: 0)  // reserved
        tkhd.append(unityMatrix)
        tkhd.append(u32: UInt32(track.width) << 16)
        tkhd.append(u32: UInt32(track.height) << 16)

        var mdhd = Data([0, 0, 0, 0])
        mdhd.append(u32: 0)
        mdhd.append(u32: 0)
        mdhd.append(u32: track.timescale)
        mdhd.append(u32: 0)  // duration
        mdhd.append(u16: 0x55C4)  // language 'und'
        mdhd.append(u16: 0)  // pre_defined

        var hdlr = Data([0, 0, 0, 0])
        hdlr.append(u32: 0)  // pre_defined
        hdlr.append(Data((track.isVideo ? "vide" : "soun").utf8))
        hdlr.append(contentsOf: [UInt8](repeating: 0, count: 12))  // reserved
        hdlr.append(Data((track.isVideo ? "VideoHandler" : "SoundHandler").utf8))
        hdlr.append(0)

        var minf = Data()
        if track.isVideo {
            var vmhd = Data([0, 0, 0, 1])
            vmhd.append(contentsOf: [UInt8](repeating: 0, count: 8))  // graphicsmode, opcolor
            minf.append(Box.plain("vmhd", vmhd))
        } else {
            minf.append(Box.plain("smhd", Data([0, 0, 0, 0, 0, 0, 0, 0])))
        }
        var dref = Data([0, 0, 0, 0])
        dref.append(u32: 1)
        dref.append(Box.plain("url ", Data([0, 0, 0, 1])))  // self-contained
        minf.append(Box.plain("dinf", Box.plain("dref", dref)))

        var stsd = Data([0, 0, 0, 0])
        stsd.append(u32: 1)
        stsd.append(track.sampleEntry)
        var stbl = Box.plain("stsd", stsd)
        stbl.append(Box.plain("stts", Data([0, 0, 0, 0, 0, 0, 0, 0])))
        stbl.append(Box.plain("stsc", Data([0, 0, 0, 0, 0, 0, 0, 0])))
        stbl.append(Box.plain("stsz", Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
        stbl.append(Box.plain("stco", Data([0, 0, 0, 0, 0, 0, 0, 0])))
        minf.append(Box.plain("stbl", stbl))

        var mdia = Box.plain("mdhd", mdhd)
        mdia.append(Box.plain("hdlr", hdlr))
        mdia.append(Box.plain("minf", minf))

        var trak = Box.plain("tkhd", tkhd)
        trak.append(Box.plain("mdia", mdia))
        return Box.plain("trak", trak)
    }

    private static func trex(_ trackID: UInt32) -> Data {
        var body = Data([0, 0, 0, 0])
        body.append(u32: trackID)
        body.append(u32: 1)  // default_sample_description_index
        body.append(u32: 0)  // default_sample_duration
        body.append(u32: 0)  // default_sample_size
        body.append(u32: 0)  // default_sample_flags
        return Box.plain("trex", body)
    }

    // MARK: - One segment

    /// The marking of a picture in the `trun`: standing on its own or dependent.
    static let syncFlags: UInt32 = 0x0200_0000
    static let dependentFlags: UInt32 = 0x0101_0000

    /// Builds `moof` and `mdat` for a piece.
    ///
    /// **`default-base-is-moof`**, and the data offsets point from the start of the `moof` to the
    /// start of the respective track in the `mdat`. First the picture, then the audio — that is
    /// also how it lies in the header.
    private static func mediaSegment(
        sequence: UInt32, video: TrackLayout, pictures: [PendingVideo], durations: [CMTime],
        audio: TrackLayout?, sounds: [PendingAudio]
    ) -> Data {
        // The size of the moof depends on the offsets, the offsets on the size — hence build twice:
        // once with zeros to know the size, then with the true offsets.
        let videoBytes = pictures.reduce(0) { $0 + $1.data.count }
        let probe = moof(
            sequence: sequence, video: video, pictures: pictures, durations: durations,
            videoOffset: 0, audio: audio, sounds: sounds, audioOffset: 0)
        let moofSize = probe.count
        let videoOffset = UInt32(moofSize + 8)
        let audioOffset = UInt32(moofSize + 8 + videoBytes)

        var out = moof(
            sequence: sequence, video: video, pictures: pictures, durations: durations,
            videoOffset: videoOffset, audio: audio, sounds: sounds, audioOffset: audioOffset)
        var mdat = Data()
        for picture in pictures { mdat.append(picture.data) }
        for sound in sounds { mdat.append(sound.data) }
        out.append(Box.plain("mdat", mdat))
        return out
    }

    private static func moof(
        sequence: UInt32, video: TrackLayout, pictures: [PendingVideo], durations: [CMTime],
        videoOffset: UInt32, audio: TrackLayout?, sounds: [PendingAudio], audioOffset: UInt32
    ) -> Data {
        var mfhd = Data([0, 0, 0, 0])
        mfhd.append(u32: sequence)
        var body = Box.plain("mfhd", mfhd)

        // ── Bild ──
        if let first = pictures.first {
            var trun = Data([1, 0x00, 0x0F, 0x01])  // version 1; offset, dur, size, flags, cto
            trun.append(u32: UInt32(pictures.count))
            trun.append(u32: videoOffset)
            for (index, picture) in pictures.enumerated() {
                let duration = durations[index].convertScale(
                    Int32(video.timescale), method: .roundHalfAwayFromZero)
                trun.append(u32: UInt32(clamping: max(0, duration.value)))
                trun.append(u32: UInt32(picture.data.count))
                trun.append(u32: picture.isSync ? syncFlags : dependentFlags)
                let offset = (picture.presentation - picture.decode).convertScale(
                    Int32(video.timescale), method: .roundHalfAwayFromZero)
                trun.append(i32: Int32(clamping: offset.value))
            }
            body.append(
                traf(
                    trackID: video.trackID,
                    decodeTime: first.decode.convertScale(
                        Int32(video.timescale), method: .roundHalfAwayFromZero),
                    trun: Box.plain("trun", trun)))
        }

        // ── Ton ──
        if let audio, let first = sounds.first {
            var trun = Data([1, 0x00, 0x07, 0x01])  // offset, dur, size, flags
            trun.append(u32: UInt32(sounds.count))
            trun.append(u32: audioOffset)
            for sound in sounds {
                let duration = sound.duration.convertScale(
                    Int32(audio.timescale), method: .roundHalfAwayFromZero)
                trun.append(u32: UInt32(clamping: max(0, duration.value)))
                trun.append(u32: UInt32(sound.data.count))
                trun.append(u32: syncFlags)
            }
            body.append(
                traf(
                    trackID: audio.trackID,
                    decodeTime: first.presentation.convertScale(
                        Int32(audio.timescale), method: .roundHalfAwayFromZero),
                    trun: Box.plain("trun", trun)))
        }
        return Box.plain("moof", body)
    }

    private static func traf(trackID: UInt32, decodeTime: CMTime, trun: Data) -> Data {
        var tfhd = Data([0, 0x02, 0x00, 0x00])  // default-base-is-moof
        tfhd.append(u32: trackID)
        var tfdt = Data([1, 0, 0, 0])  // version 1: 64 Bit
        tfdt.append(u64: UInt64(max(0, decodeTime.value)))
        var traf = Box.plain("tfhd", tfhd)
        traf.append(Box.plain("tfdt", tfdt))
        traf.append(trun)
        return Box.plain("traf", traf)
    }

    /// An MP4 box: length, name, content.
    enum Box {
        static func plain(_ name: String, _ body: Data) -> Data {
            var out = Data()
            out.append(u32: UInt32(body.count + 8))
            out.append(Data(name.utf8))
            out.append(body)
            return out
        }
    }
}

extension Data {
    mutating func append(u16 value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func append(u32 value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func append(i32 value: Int32) {
        append(u32: UInt32(bitPattern: value))
    }

    mutating func append(u64 value: UInt64) {
        append(u32: UInt32(value >> 32))
        append(u32: UInt32(value & 0xFFFF_FFFF))
    }
}
