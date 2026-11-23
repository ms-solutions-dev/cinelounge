import AVFoundation
import CoreMedia
import Foundation

/// Decodes AC-3 and E-AC-3 to PCM — for the renderer path, which does not get
/// Dolby decoded by itself.
///
/// **The finding** (F-010, 2026-09-04): Rendal HD, Rendal 2 HD, SELA 1 HD — picture without
/// audio. The tally: 1448 AC-3 packets arrived on time at the audio renderer, "0 behind
/// the clock", and it stayed silent. The HLS path plays the same channels with
/// audio, because there AVPlayer decodes. The `AVSampleBufferAudioRenderer` lacks
/// the Dolby decoder on this device — since tvOS 18, Apple's
/// `AudioConverter` delivers nothing for (E)AC-3 (Apple forum, FB15344866), and
/// the renderer hangs at the same point. `AVAudioConverter`, the higher
/// layer, still works. So the audio goes through it here: one PCM packet
/// from each Dolby frame, and the renderer receives what it can reliably
/// play.
///
/// **Stereo, not 5.1 — for now.** The decoder downmixes itself when
/// the target format has two channels; a surround channel layout would need the
/// decoder's channel assignment in the description, and that can only be
/// measured on the device. Stereo is the version that is right on every output.
public final class DolbyDecoder {

    public enum Obstacle: String, Sendable, Error {
        case description = "format description rejected"
        case pcmFormat = "PCM target format cannot be created"
        case decoder = "no Dolby decoder on this device"
    }

    /// The PCM target: the same channel count as the frame, with channel layout.
    ///
    /// **Do not downmix yourself.** A target format with fewer channels
    /// than the frame made `AVAudioConverter` die with signal 11 on the Mac
    /// (E-AC-3 5.1 → stereo, 2026-09-04). The audio renderer mixes itself
    /// to whatever is attached to the output — and for a Dolby receiver, a
    /// stereo premix is the wrong thing anyway. From three channels on, the
    /// format needs a channel layout; the assignment is the MPEG order (L R C LFE Ls
    /// Rs), in which Apple's Dolby decoder delivers.
    static func layout(for channels: Int) -> AVAudioChannelLayout? {
        let tag: AudioChannelLayoutTag
        switch channels {
        case 1: tag = kAudioChannelLayoutTag_Mono
        case 2: tag = kAudioChannelLayoutTag_Stereo
        case 3: tag = kAudioChannelLayoutTag_MPEG_3_0_A
        case 4: tag = kAudioChannelLayoutTag_MPEG_4_0_A
        case 5: tag = kAudioChannelLayoutTag_MPEG_5_0_A
        default: tag = kAudioChannelLayoutTag_MPEG_5_1_A
        }
        return AVAudioChannelLayout(layoutTag: tag)
    }

    static func pcmFormat(sampleRate: Int, layout: AVAudioChannelLayout) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), interleaved: true,
            channelLayout: layout)
    }

    private let converter: AVAudioConverter
    private let compressedFormat: AVAudioFormat
    private let pcmFormat: AVAudioFormat
    public let samplesPerFrame: Int
    public let sampleRate: Int
    public let isEnhanced: Bool
    private var decodedFrames = 0
    private var failedFrames = 0
    /// The converter's last error — for the tally. `nil` as long as none came.
    public private(set) var lastError: String?

    /// The description the consumer receives: PCM Float32, interleaved.
    public var outputDescription: CMFormatDescription { pcmFormat.formatDescription }

    public var decodedCount: Int { decodedFrames }
    public var failedCount: Int { failedFrames }

    public init(checking info: AC3Audio.FrameInfo) throws {
        // **Both formats with a channel layout, the compressed one too.** Built from the
        // CoreMedia description without a channel layout, `AVAudioConverter`
        // made the test runner die with signal 11 at 5.1 (2026-09-04); with the
        // channel layout on the input side it holds — and even downmixes
        // to stereo on request, which is not needed here.
        guard let description = try? AC3Audio.formatDescription(for: info),
            var asbd = description.audioStreamBasicDescription,
            let layout = Self.layout(for: info.channels)
        else { throw Obstacle.description }
        guard let compressed = AVAudioFormat(streamDescription: &asbd, channelLayout: layout) else {
            throw Obstacle.description
        }
        guard let pcm = Self.pcmFormat(sampleRate: info.sampleRate, layout: layout) else {
            throw Obstacle.pcmFormat
        }
        guard let converter = AVAudioConverter(from: compressed, to: pcm) else {
            throw Obstacle.decoder
        }
        self.converter = converter
        self.compressedFormat = compressed
        self.pcmFormat = pcm
        self.samplesPerFrame = info.samplesPerFrame
        self.sampleRate = info.sampleRate
        self.isEnhanced = info.isEnhanced
    }

    /// What should be in the trace when the decoder stalls.
    public var summary: String {
        "\(isEnhanced ? "E-AC-3" : "AC-3") → PCM, \(pcmFormat.channelCount) channels (AVAudioConverter)"
    }

    private final class FeedingState: @unchecked Sendable {
        var fed = false
    }

    /// One Dolby frame in, one PCM packet out — `nil` if the
    /// decoder did not take it.
    ///
    /// **Reset once and try again** (F-011, 2026-09-04): Rendal 2 HD
    /// delivered 29 PCM packets in 21 seconds, Rendal HD HEVC broke off after a
    /// while — a converter that runs into the error once stays there
    /// until someone resets it. A frame is complete in itself; after
    /// the reset it accepts the next one again.
    ///
    /// An empty frame has no start pointer and does not go to the converter
    /// (remuxer check, follow-up 2026-09-27).
    public func decode(_ frame: Data, at time: CMTime) -> CMSampleBuffer? {
        guard !frame.isEmpty else { return nil }
        if let sample = decodeOnce(frame, at: time) { return sample }
        converter.reset()
        if let sample = decodeOnce(frame, at: time) {
            recovered += 1
            return sample
        }
        failedFrames += 1
        return nil
    }

    /// How often a reset got the converter going again.
    public private(set) var recovered = 0

    private func decodeOnce(_ frame: Data, at time: CMTime) -> CMSampleBuffer? {
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

        nonisolated(unsafe) let once = compressed
        let feeding = FeedingState()
        var conversionError: NSError?
        let status = converter.convert(to: pcm, error: &conversionError) { _, outStatus in
            guard !feeding.fed else {
                outStatus.pointee = .noDataNow
                return nil
            }
            feeding.fed = true
            outStatus.pointee = .haveData
            return once
        }
        if let conversionError { lastError = conversionError.localizedDescription }
        guard status != .error, pcm.frameLength > 0, let sample = Self.sampleBuffer(pcm, at: time)
        else {
            if status != .error, lastError == nil {
                lastError = "Converter delivered \(pcm.frameLength) samples (\(status.rawValue))"
            }
            return nil
        }
        decodedFrames += 1
        return sample
    }

    /// The decoder's tally for the trace.
    public var balance: String {
        var split = ["Dolby: \(decodedFrames) frames decoded"]
        if recovered > 0 { split.append("\(recovered) after reset") }
        if failedFrames > 0 { split.append("\(failedFrames) rejected") }
        if let lastError { split.append("last error: \(lastError)") }
        return split.joined(separator: ", ")
    }

    /// Before a seek: the decoder forgets what it knows about the stream.
    public func reset() {
        converter.reset()
    }

    /// A PCM buffer as a packet, as the audio renderer takes it.
    static func sampleBuffer(_ pcm: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        let frames = Int(pcm.frameLength)
        let bytesPerFrame = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        let byteCount = frames * bytesPerFrame
        guard byteCount > 0, let source = pcm.audioBufferList.pointee.mBuffers.mData else { return nil }

        // Via the proven helper — a self-created block without
        // `CMBlockBufferAssureBlockMemory` has already once taken the
        // test runner down with signal 11.
        guard let block = try? SampleAssembly.blockBuffer(for: Data(bytes: source, count: byteCount))
        else { return nil }

        var sample: CMSampleBuffer?
        guard
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: pcm.format.formatDescription, sampleCount: frames,
                presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample)
                == noErr
        else { return nil }
        return sample
    }
}
