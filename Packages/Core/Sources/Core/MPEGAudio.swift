import AVFAudio
import CoreMedia
import Foundation

/// Reads the head of an MPEG audio frame — Layer I, II and III.
///
/// **The audio format of classic broadcasting.** The Turkish national channels
/// (on-device finding 2026-08-16, "TR ULUSAL HQ/UHD": picture plays, audio missing) broadcast
/// MPEG-1 Layer II — the same format DVB has carried in Europe since the nineties.
/// And as `A_MPEG/L3`, Layer III sits in Matroska files. Apple's
/// decoder can handle all three layers (confirmed on a real frame: `afconvert`
/// converts the capture without complaint) — only the passthrough was missing.
///
/// Built like ``AC3Audio``: the track table gives only the name; everything
/// else — layer, sample rate, channels, frame length — is in the first
/// frame of the stream.
public enum MPEGAudio {

    /// What a frame head reveals.
    public struct FrameInfo: Sendable, Equatable {
        /// 1, 2 or 3 — the layer decides the frame length and the decoder.
        public let layer: Int
        /// Whether MPEG-1; MPEG-2 and 2.5 halve sample rates and frames.
        public let isMPEG1: Bool
        public let sampleRate: Int
        public let channels: Int
        /// Abtastwerte je Rahmen — Layer I: 384, Layer II: 1152,
        /// Layer III: 1152 (MPEG-1) bzw. 576 (MPEG-2).
        public let samplesPerFrame: Int
        /// Length of the frame in bytes, including the padding bit.
        public let frameSize: Int?
    }

    /// Bitrates in kbit/s, by version and layer.
    static let bitratesMPEG1: [[Int]] = [
        [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],  // Layer I
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],  // Layer II
        [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],  // Layer III
    ]
    static let bitratesMPEG2: [[Int]] = [
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],  // Layer I
        [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],  // Layer II & III
        [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    ]
    static let sampleRatesMPEG1 = [44100, 48000, 32000]

    /// Liest den Kopf am Anfang dieser Daten.
    public static func info(in data: Data) -> FrameInfo? {
        let base = data.startIndex
        guard data.count >= 4 else { return nil }
        let byte = { (index: Int) -> Int in Int(data[base + index]) }

        // Eleven bits of sync word; the version comes right after it.
        guard byte(0) == 0xFF, byte(1) & 0xE0 == 0xE0 else { return nil }

        let versionCode = (byte(1) >> 3) & 0x03
        guard versionCode != 1 else { return nil }  // reserviert
        let isMPEG1 = versionCode == 3

        let layerCode = (byte(1) >> 1) & 0x03
        guard layerCode != 0 else { return nil }  // reserviert
        let layer = 4 - layerCode

        let bitrateIndex = (byte(2) >> 4) & 0x0F
        let rateIndex = (byte(2) >> 2) & 0x03
        guard bitrateIndex != 0, bitrateIndex != 15, rateIndex != 3 else { return nil }

        let padding = (byte(2) >> 1) & 0x01
        let mode = (byte(3) >> 6) & 0x03

        var rate = sampleRatesMPEG1[rateIndex]
        if !isMPEG1 { rate /= versionCode == 2 ? 2 : 4 }  // MPEG-2 halbiert, 2.5 viertelt

        let table = isMPEG1 ? bitratesMPEG1 : bitratesMPEG2
        let kilobits = table[layer - 1][bitrateIndex]

        // Layer I counts in four-byte steps, II and III in bytes; with
        // Layer III, MPEG-2 halves the frame as well.
        let size: Int
        let samples: Int
        switch layer {
        case 1:
            size = (12 * kilobits * 1000 / rate + padding) * 4
            samples = 384
        case 2:
            size = 144 * kilobits * 1000 / rate + padding
            samples = 1152
        default:
            let factor = isMPEG1 ? 144 : 72
            size = factor * kilobits * 1000 / rate + padding
            samples = isMPEG1 ? 1152 : 576
        }

        return FrameInfo(
            layer: layer,
            isMPEG1: isMPEG1,
            sampleRate: rate,
            channels: mode == 3 ? 1 : 2,
            samplesPerFrame: samples,
            frameSize: size
        )
    }

    /// Splits a piece of stream into whole frames at the sync word.
    ///
    /// The same rule as for AC-3: only complete frames get through. One
    /// cut at the PES edge is discarded — the gap is a frame
    /// of 24 ms, the garbage would be a click.
    ///
    /// **The frame length comes from each head itself**, not from the first:
    /// the sync word 0xFF 0xE0 also occurs as a byte sequence in the middle of the
    /// audio data. Only checking whether a valid head sits at the match
    /// AND the next frame follows at the expected distance separates a head from a
    /// chance hit.
    public static func frames(in data: Data) -> [Data] {
        var result: [Data] = []
        let bytes = [UInt8](data)
        let base = data.startIndex
        var index = 0
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF, bytes[index + 1] & 0xE0 == 0xE0,
                let info = info(in: data.subdata(in: (base + index)..<(base + index + 4))),
                let size = info.frameSize, size > 0
            else {
                index += 1
                continue
            }
            guard index + size <= bytes.count else { break }  // Restrahmen — verwerfen
            result.append(data.subdata(in: (base + index)..<(base + index + size)))
            index += size
        }
        return result
    }

    /// Builds the description of the **raw** stream — for the decoder, not
    /// for the writer: HLS fMP4 does not accept MPEG audio, see
    /// ``MPEGAudioDecoder``.
    public static func formatDescription(for info: FrameInfo) throws -> CMFormatDescription {
        let formatID: AudioFormatID =
            switch info.layer {
            case 1: kAudioFormatMPEGLayer1
            case 2: kAudioFormatMPEGLayer2
            default: kAudioFormatMPEGLayer3
            }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(info.sampleRate),
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(info.samplesPerFrame),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(info.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var description: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw AudioAssembly.AudioFailure.descriptionRejected(status)
        }
        return description
    }
}

/// Re-encodes MPEG audio frames to AAC — the detour HLS forces.
///
/// **Passing through does not work, and encoding in the writer does not either** — both
/// failed at the writer itself, not assumed: `AVAssetWriter` does not even accept an
/// MPEG audio track in the HLS profile (`canAdd` says no), and
/// next to a passed-through video track it refuses to encode (−11875).
/// The CMAF profile in turn allows only one track. What remains is the path before it:
/// Apple's MP2 decoder turns the frame into PCM, Apple's AAC encoder turns
/// that into AAC, and what arrives at the writer is what it knows. This is the one
/// place in the remuxer where audio is re-encoded — for video the
/// principle stays: never convert.
public final class MPEGAudioTranscoder {

    /// Samples per AAC packet — fixed by the format.
    public static let samplesPerPacket = 1024
    /// The target bitrate. 192 kbit/s stereo is transparent compared with a
    /// 256 kbit/s MP2 source — more would be space without gain.
    static let bitrate = 192_000

    /// Apple's decoder — or none: tvOS ships none for Layer I and II
    /// (confirmed on the device, 2026-08-22), in which case ``ownDecoder`` takes over.
    private let decoder: AVAudioConverter?
    /// The custom Layer II decoder — the fallback when Apple's is missing.
    private var ownDecoder: MP2Decoder?
    private let encoder: AVAudioConverter
    private let compressedFormat: AVAudioFormat
    private let pcmFormat: AVAudioFormat
    private let aacFormat: AVAudioFormat
    private let samplesPerFrame: Int
    private let sampleRate: Int

    /// PCM that is decoded and waiting for the encoder.
    private var pendingPCM: [AVAudioPCMBuffer] = []
    /// Where the output's timekeeping lives.
    private var anchor: CMTime?
    private var producedPackets = 0
    private var consumedFrames = 0

    /// The description of the AAC output — it goes to the writer as `sourceFormatHint`,
    /// just like for AAC that already arrives finished.
    /// With the AudioSpecificConfig cookie — see ``DTSTranscoder/outputDescription``.
    public var outputDescription: CMFormatDescription {
        (try? AudioAssembly.formatDescription(sampleRate: sampleRate, channels: Int(pcmFormat.channelCount)))
            ?? aacFormat.formatDescription
    }

    /// Whether the custom decoder is working instead of Apple's — for the diagnostics line:
    /// on the TV it must be readable which path produces the audio.
    public var usesOwnDecoder: Bool { ownDecoder != nil }

    /// What the setup failed on.
    ///
    /// **A single "doesn't work" cost a whole day on 2026-08-22**
    /// The diagnostics from the device said "this device has no transcoder" — and
    /// so it was open whether tvOS lacks the MP2 **decoder** or the AAC **encoder**.
    /// The whole further path hangs on that: if the decoder is missing,
    /// only a custom one or the detour via the server helps; if only the
    /// encoder is missing, PCM to the writer would be the shorter path. Four steps, four
    /// names.
    public enum Obstacle: String, Sendable, Error {
        /// The frame head could not be translated into a description.
        case description = "format description rejected"
        /// The intermediate PCM format was not created.
        case pcmFormat = "intermediate PCM format could not be created"
        /// The AAC target format was not created.
        case aacFormat = "AAC target format could not be created"
        /// **No MPEG audio decoder on this device.**
        case decoder = "no MPEG audio decoder"
        /// **No AAC encoder on this device.**
        case encoder = "no AAC encoder"
    }

    /// The convenient path: `nil` instead of a throw, for the spots in the middle of the data stream
    /// that have no use for the reason anyway.
    public convenience init?(info: MPEGAudio.FrameInfo) {
        try? self.init(checking: info)
    }

    /// The same setup, but it says what it fails on — see ``Obstacle``.
    ///
    /// - Parameter forcingOwnDecoder: For the checks only: forces the
    ///   custom Layer II decoder even where Apple's is available. On the
    ///   Mac Apple's is always there — without this lever the device path
    ///   (tvOS without a Layer II decoder) would never run in any test.
    public init(checking info: MPEGAudio.FrameInfo, forcingOwnDecoder: Bool = false) throws {
        guard let description = try? MPEGAudio.formatDescription(for: info) else {
            throw Obstacle.description
        }
        guard
            let pcm = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(info.sampleRate),
                channels: AVAudioChannelCount(info.channels),
                interleaved: false)
        else {
            throw Obstacle.pcmFormat
        }
        var aacDescription = AudioStreamBasicDescription(
            mSampleRate: Float64(info.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.samplesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(info.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let compressed = AVAudioFormat(cmAudioFormatDescription: description)
        guard let aac = AVAudioFormat(streamDescription: &aacDescription) else {
            throw Obstacle.aacFormat
        }
        // **Checked individually, not in a chain.** In a shared `guard`
        // it is impossible to tell afterwards which of the two converters is missing — and
        // that was exactly the open question after the on-device test of 2026-08-22.
        //
        // The device's answer: the Layer II DECODER is missing (tvOS decodes
        // MP3, AAC, AC-3, PCM — not Layer II), the AAC encoder is there.
        // That is why the custom decoder steps in for Layer II — ``MP2Decoder``,
        // checked against Apple's reference on the computer. For Layer III every
        // device has Apple's decoder; only Layer I remains without a path, and it has been
        // dead in broadcasting for decades.
        let decoder = forcingOwnDecoder ? nil : AVAudioConverter(from: compressed, to: pcm)
        if decoder == nil {
            guard info.layer == 2 else { throw Obstacle.decoder }
            ownDecoder = MP2Decoder()
        }
        guard let encoder = AVAudioConverter(from: pcm, to: aac) else {
            throw Obstacle.encoder
        }
        encoder.bitRate = Self.bitrate
        self.compressedFormat = compressed
        self.pcmFormat = pcm
        self.aacFormat = aac
        self.decoder = decoder
        self.encoder = encoder
        self.samplesPerFrame = info.samplesPerFrame
        self.sampleRate = info.sampleRate
    }

    /// Takes a whole frame and returns whatever AAC has been completed.
    ///
    /// **The output times run with the samples**, not with the
    /// timestamps of the input: MP2 packs 1152 values into a frame, AAC
    /// 1024 into a packet — the boundaries never coincide, the encoder
    /// buffers in between. It anchors once, at the first frame; if the
    /// input time drifts noticeably from this calculation (channel switch in the same
    /// stream, time jump), it re-anchors instead of counting on.
    public func transcode(_ frame: Data, at time: CMTime) -> [(payload: Data, time: CMTime)] {
        if let anchor {
            let expected =
                anchor
                + CMTime(
                    value: CMTimeValue(consumedFrames * samplesPerFrame),
                    timescale: CMTimeScale(sampleRate))
            let deviation = (time - expected).seconds
            if abs(deviation) > Self.reanchorFrom {
                reset(to: time, by: deviation)
            }
        } else {
            anchor = time
        }

        if let pcm = decode(frame) { pendingPCM.append(pcm) }
        consumedFrames += 1
        return drainEncoder()
    }

    /// At what divergence the audio clock is reset.
    ///
    /// **The number used to sit as `0.35` in the body.** It is the threshold at which the
    /// viewer hears a jump; it deserves a name and a place where it can be
    /// found when a report mentions it.
    public static let reanchorFrom: Double = 0.35

    /// How often the audio clock has been reset in this session.
    public private(set) var reanchors = 0

    /// Resets the audio clock — **and says so, because it is audible.**
    ///
    /// **Until 2026-09-06 this was the quietest spot in the whole audio chain.** The output
    /// times run with the samples and not with the input timestamps;
    /// when the two diverge, the clock jumps here by up to a third of a second — and
    /// without a single line anywhere. This jump is exactly what someone describes as "the audio
    /// doesn't run cleanly", and it was visible in no report.
    ///
    /// **The amount belongs with it, not only the fact.** A jump of 0.4 s after
    /// a reconnect is something different from one of 0.36 s that
    /// returns every two minutes: the first is a seam, the second a sync fault.
    private func reset(to time: CMTime, by deviation: Double = 0) {
        reanchors += 1
        Diagnostics.playbackStep(
            "Audio: clock re-anchored (no. \(reanchors), "
                + "\(Int(deviation * 1000)) ms apart)", since: nil)
        resetSilently(to: time)
    }

    private func resetSilently(to time: CMTime) {
        decoder?.reset()
        if ownDecoder != nil { ownDecoder = MP2Decoder() }
        encoder.reset()
        pendingPCM.removeAll()
        anchor = time
        producedPackets = 0
        consumedFrames = 0
    }

    private func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        if ownDecoder != nil { return decodeOwn(frame) }
        return decodeWithApple(frame)
    }

    /// The custom Layer II path: frame → interleaved integers →
    /// floating-point channels, as the encoder expects them.
    private func decodeOwn(_ frame: Data) -> AVAudioPCMBuffer? {
        guard let interleaved = ownDecoder?.decode(frame),
            let pcm = AVAudioPCMBuffer(
                pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(MP2Decoder.samplesPerFrame)),
            let channels = pcm.floatChannelData
        else { return nil }
        let channelCount = Int(pcmFormat.channelCount)
        for index in 0..<MP2Decoder.samplesPerFrame {
            for ch in 0..<channelCount {
                // The decoder always delivers stereo; for mono both
                // channels are equal, and the first is the one.
                channels[ch][index] = Float(interleaved[(index << 1) + ch]) / 32768
            }
        }
        pcm.frameLength = AVAudioFrameCount(MP2Decoder.samplesPerFrame)
        return pcm
    }

    /// Whether the input block has already delivered.
    ///
    /// A class instead of a captured `var`: the block is declared as `@Sendable`,
    /// and a captured mutable variable inside it is exactly the warning
    /// in question — see ``decodeWithApple(_:)``.
    private final class FeedingState: @unchecked Sendable {
        var fed = false
    }

    /// An empty frame does not go to the converter — a Matroska lacing may name frames
    /// of length zero, and without bytes there is no base pointer
    /// (remuxer check, follow-up 2026-09-27).
    private func decodeWithApple(_ frame: Data) -> AVAudioPCMBuffer? {
        guard let decoder, !frame.isEmpty else { return nil }
        let compressed = AVAudioCompressedBuffer(
            format: compressedFormat, packetCapacity: 1, maximumPacketSize: frame.count)
        frame.withUnsafeBytes { bytes in
            compressed.data.copyMemory(from: bytes.baseAddress!, byteCount: frame.count)
        }
        compressed.byteLength = UInt32(frame.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))

        guard
            let pcm = AVAudioPCMBuffer(
                pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samplesPerFrame))
        else { return nil }

        // **Why `nonisolated(unsafe)` is here** (AP15, 2026-09-02). The
        // input block of `AVAudioConverter` is declared `@Sendable` in Apple's header file;
        // but it is called **synchronously inside
        // `convert`**, on exactly this thread, and it does not escape. The
        // compiler cannot know that and therefore reported three warnings
        // — formally right, factually moot.
        //
        // Simply leaving them was the more expensive path: as long as even a single
        // warning stands, `SWIFT_TREAT_WARNINGS_AS_ERRORS` cannot be set,
        // and without that gate the next one slips in unseen.
        // The assertion therefore lives here, with its reasoning, instead of as a number
        // in a report nobody interprets.
        nonisolated(unsafe) let once = compressed
        let feeding = FeedingState()
        var conversionError: NSError?
        let status = decoder.convert(to: pcm, error: &conversionError) { _, outStatus in
            guard !feeding.fed else {
                outStatus.pointee = .noDataNow
                return nil
            }
            feeding.fed = true
            outStatus.pointee = .haveData
            return once
        }
        guard status != .error, pcm.frameLength > 0 else { return nil }
        return pcm
    }

    /// Collects from the encoder whatever the samples suffice for.
    private func drainEncoder() -> [(payload: Data, time: CMTime)] {
        guard let anchor else { return [] }
        var result: [(payload: Data, time: CMTime)] = []
        while true {
            let packet = AVAudioCompressedBuffer(
                format: aacFormat,
                packetCapacity: 1,
                maximumPacketSize: max(1536, Int(encoder.maximumOutputPacketSize)))
            var conversionError: NSError?
            // The same situation as in ``decodeWithApple(_:)``: called synchronously,
            // does not escape. The reasoning is given there in detail.
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
