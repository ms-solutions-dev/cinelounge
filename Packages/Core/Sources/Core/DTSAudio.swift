import AVFoundation
import CoreMedia
import DCADec
import Foundation

/// DTS audio (Coherent Acoustics) — detecting, decoding, transcoding.
///
/// **Why the app does this itself** (Continue Watching finding 2026-09-03): an Apple TV
/// does not output DTS, so until now the server converted — and it probes
/// a large DTS Matroska completely before the first segment (`-probesize
/// 1G`). Continue Watching in a two-hour film thus took half a minute.
/// With the core decoder from ``DCADec`` (libdcadec, LGPL 2.1 — see
/// `HERKUNFT.md` there), the file takes the repackaging path like one with AC-3: the
/// DTS core becomes PCM, the PCM becomes AAC as with ``MPEGAudioTranscoder``, and
/// the player sees an ordinary HLS audio track. Picture-in-picture, AirPlay and
/// the fast start remain, because the player stays the same.
///
/// Only the **core** is decoded (up to 5.1, 48 kHz): it is present in every DTS
/// and DTS-HD track, and the AAC path gains nothing from lossless anyway.
public enum DTSAudio {

    /// What the first frame reveals about the track.
    public struct FrameInfo: Sendable, Equatable {
        public let sampleRate: Int
        /// Channels **including** LFE.
        public let channels: Int
        public let samplesPerFrame: Int
        public let profile: String

        public init(sampleRate: Int, channels: Int, samplesPerFrame: Int, profile: String) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.samplesPerFrame = samplesPerFrame
            self.profile = profile
        }
    }

    /// How the bits lie in the frame. libdcadec wants 16-bit big-endian; the
    /// little-endian form is swapped, the 14-bit forms (old DTS CDs,
    /// LaserDisc) stay out — they do not occur in Matroska.
    enum Framing: Equatable {
        case bigEndian16
        case littleEndian16
        case bits14
        case extensionOnly
        case unknown
    }

    static func framing(of frame: Data) -> Framing {
        guard frame.count >= 4 else { return .unknown }
        let a = frame[frame.startIndex], b = frame[frame.startIndex + 1]
        let c = frame[frame.startIndex + 2], d = frame[frame.startIndex + 3]
        switch (a, b, c, d) {
        case (0x7F, 0xFE, 0x80, 0x01): return .bigEndian16
        case (0xFE, 0x7F, 0x01, 0x80): return .littleEndian16
        case (0x1F, 0xFF, 0xE8, 0x00), (0xFF, 0x1F, 0x00, 0xE8): return .bits14
        case (0x64, 0x58, 0x20, 0x25): return .extensionOnly
        default: return .unknown
        }
    }

    /// The frame in the form the decoder reads — or `nil`.
    static func normalized(_ frame: Data) -> Data? {
        switch framing(of: frame) {
        case .bigEndian16, .extensionOnly:
            return frame
        case .littleEndian16:
            var swapped = Data(count: frame.count & ~1)
            swapped.withUnsafeMutableBytes { out in
                frame.withUnsafeBytes { input in
                    let src = input.bindMemory(to: UInt8.self)
                    let dst = out.bindMemory(to: UInt8.self)
                    var i = 0
                    while i + 1 < src.count {
                        dst[i] = src[i + 1]
                        dst[i + 1] = src[i]
                        i += 2
                    }
                }
            }
            return swapped
        case .bits14, .unknown:
            return nil
        }
    }

    /// Reads sample rate, channels and frame length from the core of a frame.
    public static func info(in frame: Data) -> FrameInfo? {
        DTSDecoder().probe(frame)
    }

    static func profileName(_ profile: Int32) -> String {
        switch profile {
        case 0x01: "DTS"
        case 0x02: "DTS 96/24"
        case 0x04: "DTS-ES"
        case 0x08: "DTS-HD HRA"
        case 0x10: "DTS-HD MA"
        case 0x20: "DTS Express"
        default: "DTS (unknown profile)"
        }
    }
}

/// The thin shell around libdcadec: one frame in, planar samples
/// out. Only the core is driven.
public final class DTSDecoder {

    /// A decoded frame — planes in WAVEFORMATEXTENSIBLE order,
    /// `channelMask` says which speakers the planes occupy.
    public struct Output {
        public let planes: [[Int32]]
        public let channelMask: UInt32
        public let sampleRate: Int
        public let bitsPerSample: Int
        public let profile: Int32
        public var frames: Int { planes.first?.count ?? 0 }
    }

    private let context: OpaquePointer
    public private(set) var lastError: String?
    public private(set) var decodedFrames = 0
    public private(set) var failedFrames = 0

    public init() {
        // CORE_ONLY: Master Audio remnants are left lying, the core is what counts.
        context = dcadec_context_create(Int32(DCADEC_FLAG_CORE_ONLY))!
    }

    deinit {
        dcadec_context_destroy(context)
    }

    /// Header only: for registering the track. Resets the decoder.
    func probe(_ frame: Data) -> DTSAudio.FrameInfo? {
        guard let normalized = DTSAudio.normalized(frame) else { return nil }
        defer { dcadec_context_clear(context) }
        guard parse(normalized) >= 0, let info = dcadec_context_get_core_info(context) else {
            return nil
        }
        defer { dcadec_context_free_core_info(info) }
        let core = info.pointee
        let profile = Self.encodedProfile(core)
        return DTSAudio.FrameInfo(
            sampleRate: Int(core.sample_rate),
            channels: Int(core.nchannels) + (core.lfe_present != 0 ? 1 : 0),
            samplesPerFrame: Int(core.npcmblocks) * 32,
            profile: profile)
    }

    private static func encodedProfile(_ core: dcadec_core_info) -> String {
        if core.ext_audio_present {
            // The core reports only its own extension; an HD substream
            // sits next to it and becomes visible when filtering. For display
            // the core information is enough.
            return DTSAudio.profileName(core.es_format ? 0x04 : 0x01)
        }
        return DTSAudio.profileName(core.es_format ? 0x04 : 0x01)
    }

    /// Decodes a frame. `nil` for a frame the decoder does not
    /// accept — the reason is in `lastError`.
    public func decode(_ frame: Data) -> Output? {
        guard let normalized = DTSAudio.normalized(frame) else {
            lastError = "DTS frame in 14-bit form or without a sync word"
            failedFrames += 1
            return nil
        }
        let status = parse(normalized)
        guard status >= 0 else {
            lastError = String(cString: dcadec_strerror(status))
            failedFrames += 1
            return nil
        }
        var planes: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>? = nil
        var count: Int32 = 0
        var mask: Int32 = 0
        var rate: Int32 = 0
        var bits: Int32 = 0
        var profile: Int32 = 0
        let filtered = dcadec_context_filter(
            context, &planes, &count, &mask, &rate, &bits, &profile)
        guard filtered >= 0, let planes, count > 0, mask != 0 else {
            lastError = String(cString: dcadec_strerror(filtered))
            failedFrames += 1
            return nil
        }
        let channels = UInt32(bitPattern: mask).nonzeroBitCount
        var copied: [[Int32]] = []
        copied.reserveCapacity(channels)
        for index in 0..<channels {
            guard let plane = planes[index] else { break }
            copied.append(Array(UnsafeBufferPointer(start: plane, count: Int(count))))
        }
        decodedFrames += 1
        return Output(
            planes: copied, channelMask: UInt32(bitPattern: mask), sampleRate: Int(rate),
            bitsPerSample: Int(bits), profile: profile)
    }

    /// Copies the frame into an aligned, padded buffer — as
    /// the library requires — and lets it read it.
    private func parse(_ frame: Data) -> Int32 {
        let padding = Int(DCADEC_BUFFER_PADDING)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: frame.count + padding, alignment: 16)
        defer { buffer.deallocate() }
        frame.withUnsafeBytes { bytes in
            buffer.copyMemory(from: bytes.baseAddress!, byteCount: frame.count)
        }
        (buffer + frame.count).initializeMemory(as: UInt8.self, repeating: 0, count: padding)
        return dcadec_context_parse(
            context, buffer.assumingMemoryBound(to: UInt8.self), frame.count)
    }
}

/// What a file's audio path attests about itself: frames in,
/// AAC packets out.
///
/// **A path that was accepted and then delivers nothing is invisible without this
/// accounting.** That is the lesson of 2026-08-16, learned on the silent
/// Turkish channel: the head of the output reports an audio track with channel count
/// and sample rate, the viewer sees a film without sound, and the diagnosis
/// says not a word — a missing decoder is then indistinguishable from a file without an audio
/// track. ``TransportRemuxer`` has drawn this balance for channels
/// since 2026-08-22; the file path (``MatroskaRemuxer``) did not have it.
///
/// **For DTS this is exactly the likely case** and not an
/// edge thought: the track is accepted at the **first** frame, and that frame can
/// carry a readable core while later frames no longer carry one.
/// The two aborts the remuxer already reports today hit only the
/// first frame — everything after it failed silently.
///
/// **As a value of its own and not a branch in the remuxer**, so that the verdict can be checked without
/// a file and without a player: the remuxer counts, this value
/// judges, and ``MatroskaFileSession`` only retrieves ``silenceFinding``. The
/// holder itself — a session with its own server and its own thread — would be
/// hard to set up in a test.
public struct AudioTally: Sendable, Equatable {

    /// How the audio came in. For the log line, not for the decision: whether
    /// a path stays silent does not depend on the name of its codec.
    public let codec: String

    /// Frames that were fed into the transcoder.
    public let framesIn: Int

    /// AAC packets that came out. **This is the number that counts** — that the
    /// decoder delivers samples does not yet mean that the encoder yields packets,
    /// and only the packet ends up in the segment.
    public let packetsOut: Int

    /// How much playing time the fed frames carry, in seconds.
    public let secondsIn: Double

    /// Channels of the registered AAC form — so it can be read off whether 5.1 survived
    /// or was mixed down to stereo.
    public let channels: Int

    /// Frames the decoder rejected, as far as it reports them.
    public let rejectedFrames: Int?

    /// What the transcoder last complained about.
    public let reason: String?

    public init(
        codec: String,
        framesIn: Int,
        packetsOut: Int,
        secondsIn: Double,
        channels: Int,
        rejectedFrames: Int?,
        reason: String?
    ) {
        self.codec = codec
        self.framesIn = framesIn
        self.packetsOut = packetsOut
        self.secondsIn = secondsIn
        self.channels = channels
        self.rejectedFrames = rejectedFrames
        self.reason = reason
    }

    /// From how much playing time the verdict is reliable, in seconds.
    ///
    /// **Not from the first frame**, and the reason is in the arithmetic:
    /// a DTS frame carries 512 samples, an AAC packet 1024 — the first
    /// frames yield nothing by design, and the encoder additionally accumulates.
    /// Whoever judged earlier here would report the normal case as an error.
    ///
    /// **And not the two seconds of the channel** (``TransportRemuxer`` draws
    /// its balance after 84 MPEG frames): there **one** remuxer runs over the
    /// whole stream, here **each piece** gets its own, and the counters
    /// start at zero with it. A piece is **at least** two seconds long:
    /// ``MatroskaIndex`` cuts the file by `pieceTargetSeconds` in
    /// ``MatroskaFileSession`` (the same value as ``FragmentWriter/segmentDuration``),
    /// only the last piece is shorter. The writer itself does not cut here —
    /// it gets `.indefinite`. A deadline of two
    /// seconds would lie exactly on the piece length and would never be
    /// reached in many pieces: a guard that only triggers by chance.
    ///
    /// One second is unambiguous and fits. Measured on the DTS sample
    /// in the directory: 51 frames (0.54 s) yielded 25 AAC packets — after one
    /// second about 46 are to be expected, and zero of them is no longer
    /// buffering but a silent track.
    public static let verdictFrom: Double = 1

    /// Whether the path stays silent although it was accepted.
    public var staysSilent: Bool {
        secondsIn >= Self.verdictFrom && packetsOut == 0
    }

    /// The line for the recording — even when everything is fine.
    public var row: String {
        var split = [
            "\(codec) \(framesIn) frames in, \(packetsOut) AAC packets out, "
                + "\(channels) channels"
        ]
        if let rejectedFrames, rejectedFrames > 0 {
            split.append("\(rejectedFrames) frames rejected")
        }
        if let reason { split.append(reason) }
        return split.joined(separator: ", ")
    }

    /// The sentence for the **error trace** — or `nil` as long as audio comes out.
    ///
    /// It names both numbers and the reason, because the follow-up question would
    /// otherwise stay open: whether the decoder rejected the frames or the encoder
    /// yielded nothing are two findings with two entirely different ways out.
    public var silenceFinding: String? {
        guard staysSilent else { return nil }
        return "Audio: \(row) — after \(String(format: "%.1f", secondsIn)) s "
            + "not a single packet. The track stays silent"
    }
}

/// What the Matroska remuxer needs from an audio transcoder — fulfilled by
/// ``MPEGAudioTranscoder`` and ``DTSTranscoder``.
public protocol AudioTranscoding: AnyObject {
    /// The AAC form that is registered with the writer.
    var outputDescription: CMFormatDescription { get }
    /// Abtastwerte je AAC-Paket.
    var packetSamples: Int { get }
    func transcode(_ frame: Data, at time: CMTime) -> [(payload: Data, time: CMTime)]
}

extension MPEGAudioTranscoder: AudioTranscoding {
    public var packetSamples: Int { Self.samplesPerPacket }
}

/// DTS core → PCM → AAC, frame by frame. The timing is that of
/// ``MPEGAudioTranscoder``: the first frame sets the anchor, each packet
/// is counted up, a jump of more than 350 ms resets everything.
public final class DTSTranscoder: AudioTranscoding {

    public static let samplesPerPacket = 1024
    public var packetSamples: Int { Self.samplesPerPacket }

    /// Where the speakers are mixed to.
    enum Target {
        case mono, stereo, surround51

        var channels: Int {
            switch self {
            case .mono: 1
            case .stereo: 2
            case .surround51: 6
            }
        }

        var bitrate: Int {
            switch self {
            case .mono: 96_000
            case .stereo: 192_000
            case .surround51: 384_000
            }
        }
    }

    public enum Obstacle: String, Sendable, Error {
        case frame = "first frame unreadable"
        case pcmFormat = "PCM intermediate format cannot be created"
        case aacFormat = "AAC target format cannot be created"
        case encoder = "no AAC encoder"
    }

    private let decoder = DTSDecoder()
    private let encoder: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let aacFormat: AVAudioFormat
    private let target: Target
    private let samplesPerFrame: Int
    private let sampleRate: Int

    private var pendingPCM: [AVAudioPCMBuffer] = []
    private var anchor: CMTime?
    private var producedPackets = 0
    private var consumedFrames = 0

    /// **With the cookie** (probe 2026-09-04): `aacFormat.formatDescription` carries
    /// no AudioSpecificConfig, and AVAssetWriter then writes an
    /// `mp4a` entry without `esds` — the player saw "2 channels, no decoder"
    /// and stayed silent. ``AudioAssembly/formatDescription(sampleRate:channels:)``
    /// attaches the cookie, with the channel count in it.
    public var outputDescription: CMFormatDescription {
        (try? AudioAssembly.formatDescription(sampleRate: sampleRate, channels: target.channels))
            ?? aacFormat.formatDescription
    }
    public var decodedFrames: Int { decoder.decodedFrames }
    public var failedFrames: Int { decoder.failedFrames }
    public var lastError: String? { decoder.lastError }

    public init(checking info: DTSAudio.FrameInfo) throws {
        let target: Target =
            switch info.channels {
            case 1: .mono
            case 2: .stereo
            // 6.1 (DTS-ES, rear center — a few percent of the catalog) ends up in 5.1,
            // the center at the back half left, half right.
            case 6, 7: .surround51
            // 3, 4, 5 channels (stereo + center, quad, 5.0): mixed down to
            // stereo — rare enough that an AAC form of its own is not worthwhile.
            default: .stereo
            }
        let pcm: AVAudioFormat?
        let layout: AVAudioChannelLayout?
        switch target {
        case .surround51:
            // L R C LFE Ls Rs — the order in which WAVE counts as well.
            let pcmLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
            pcm = AVAudioFormat(
                standardFormatWithSampleRate: Double(info.sampleRate), channelLayout: pcmLayout)
            layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_AAC_5_1)
        case .mono, .stereo:
            pcm = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(info.sampleRate),
                channels: AVAudioChannelCount(target.channels), interleaved: false)
            layout = nil
        }
        guard let pcm else { throw Obstacle.pcmFormat }

        var aacDescription = AudioStreamBasicDescription(
            mSampleRate: Float64(info.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.samplesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(target.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let aac: AVAudioFormat? =
            if let layout {
                AVAudioFormat(streamDescription: &aacDescription, channelLayout: layout)
            } else {
                AVAudioFormat(streamDescription: &aacDescription)
            }
        guard let aac else { throw Obstacle.aacFormat }
        guard let encoder = AVAudioConverter(from: pcm, to: aac) else {
            throw Obstacle.encoder
        }
        encoder.bitRate = target.bitrate
        self.encoder = encoder
        self.pcmFormat = pcm
        self.aacFormat = aac
        self.target = target
        self.samplesPerFrame = info.samplesPerFrame
        self.sampleRate = info.sampleRate
    }

    public func transcode(_ frame: Data, at time: CMTime) -> [(payload: Data, time: CMTime)] {
        if let anchor {
            let expected =
                anchor
                + CMTime(
                    value: CMTimeValue(consumedFrames * samplesPerFrame),
                    timescale: CMTimeScale(sampleRate))
            if abs((time - expected).seconds) > 0.35 {
                reset(to: time)
            }
        } else {
            anchor = time
        }
        if let output = decoder.decode(frame), let pcm = pcmBuffer(from: output) {
            pendingPCM.append(pcm)
        }
        consumedFrames += 1
        return drainEncoder()
    }

    private func reset(to time: CMTime) {
        encoder.reset()
        pendingPCM.removeAll()
        anchor = time
        producedPackets = 0
        consumedFrames = 0
    }

    // WAVEFORMATEXTENSIBLE bits, in the order of the planes.
    private static let frontLeft: UInt32 = 0x1
    private static let frontRight: UInt32 = 0x2
    private static let frontCenter: UInt32 = 0x4
    private static let lowFrequency: UInt32 = 0x8
    private static let backLeft: UInt32 = 0x10
    private static let backRight: UInt32 = 0x20
    private static let frontLeftOfCenter: UInt32 = 0x40
    private static let frontRightOfCenter: UInt32 = 0x80
    private static let backCenter: UInt32 = 0x100
    private static let sideLeft: UInt32 = 0x200
    private static let sideRight: UInt32 = 0x400

    /// Where a speaker flows to in the target: (target channel, weight).
    static func routes(for speaker: UInt32, target: Target) -> [(Int, Float)] {
        let half: Float = 0.7071
        switch target {
        case .surround51:
            switch speaker {
            case frontLeft: return [(0, 1)]
            case frontRight: return [(1, 1)]
            case frontCenter: return [(2, 1)]
            case lowFrequency: return [(3, 1)]
            case backLeft, sideLeft: return [(4, 1)]
            case backRight, sideRight: return [(5, 1)]
            case frontLeftOfCenter: return [(0, half)]
            case frontRightOfCenter: return [(1, half)]
            case backCenter: return [(4, half), (5, half)]
            default: return []
            }
        case .stereo:
            switch speaker {
            case frontLeft: return [(0, 1)]
            case frontRight: return [(1, 1)]
            case frontCenter: return [(0, half), (1, half)]
            case lowFrequency: return []
            case backLeft, sideLeft, frontLeftOfCenter: return [(0, half)]
            case backRight, sideRight, frontRightOfCenter: return [(1, half)]
            case backCenter: return [(0, 0.5), (1, 0.5)]
            default: return []
            }
        case .mono:
            switch speaker {
            case lowFrequency: return []
            case frontCenter: return [(0, 1)]
            default: return [(0, half)]
            }
        }
    }

    /// Ganzzahl-Ebenen → Gleitkomma-Puffer im Zielbild.
    func pcmBuffer(from output: DTSDecoder.Output) -> AVAudioPCMBuffer? {
        let frames = output.frames
        guard frames > 0,
            let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)),
            let channels = pcm.floatChannelData
        else { return nil }
        let channelCount = target.channels
        for ch in 0..<channelCount {
            channels[ch].initialize(repeating: 0, count: frames)
        }
        let scale = 1 / Float(1 << (max(1, min(output.bitsPerSample, 31)) - 1))
        var planeIndex = 0
        for bit in 0..<32 where output.channelMask & (1 << bit) != 0 {
            defer { planeIndex += 1 }
            guard planeIndex < output.planes.count else { break }
            let plane = output.planes[planeIndex]
            for (channel, gain) in Self.routes(for: 1 << bit, target: target) {
                let weight = gain * scale
                let out = channels[channel]
                for index in 0..<frames {
                    out[index] += Float(plane[index]) * weight
                }
            }
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        return pcm
    }

    private func drainEncoder() -> [(payload: Data, time: CMTime)] {
        guard let anchor else { return [] }
        var result: [(payload: Data, time: CMTime)] = []
        while true {
            let packet = AVAudioCompressedBuffer(
                format: aacFormat,
                packetCapacity: 1,
                maximumPacketSize: max(1536, Int(encoder.maximumOutputPacketSize)))
            var conversionError: NSError?
            nonisolated(unsafe) let isMarkedItself = self
            let status = encoder.convert(to: packet, error: &conversionError) { _, outStatus in
                if let next = isMarkedItself.pendingPCM.first {
                    isMarkedItself.pendingPCM.removeFirst()
                    outStatus.pointee = .haveData
                    return next
                }
                outStatus.pointee = .noDataNow
                return nil
            }
            guard status == .haveData, packet.packetCount > 0, packet.byteLength > 0 else {
                break
            }
            let payload = Data(bytes: packet.data, count: Int(packet.byteLength))
            let time =
                anchor
                + CMTime(
                    value: CMTimeValue(producedPackets * Self.samplesPerPacket),
                    timescale: CMTimeScale(sampleRate))
            producedPackets += 1
            result.append((payload, time))
        }
        return result
    }
}
