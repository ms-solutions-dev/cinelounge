import AVFAudio
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The own decoder against Apple's own** — on the Mac we have
/// both, and that is exactly why it can be demonstrated here what nobody can
/// check on the device: that the Swift port hears the same as the reference.
///
/// The outputs are not compared byte for byte but via the
/// **cross-correlation**: Every Layer II decoder has a lead-in from the
/// synthesis filterbank (481 values), and whether a decoder cuts it off is
/// its own business. The sound behind it must be the same — at the best
/// shift nearly congruent.
@Suite("The custom Layer II decoder")
struct MP2DecodingTests {

    /// A tiny latch around the fed flag — only so the checker
    /// has nothing to complain about; the callback runs in one go here anyway.
    private final class Locked: @unchecked Sendable {
        private var value: Bool
        private let lock = NSLock()
        init(_ value: Bool) { self.value = value }
        func exchange(_ new: Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let old = value
            value = new
            return old
        }
    }

    private var frames: [Data] {
        MPEGAudio.frames(in: MPEGAudioTests.capturedFrames)
    }

    /// Three frames, 1152 stereo values per frame — the bookkeeping first.
    @Test("A frame yields 1152 values per channel")
    func frameYieldsItsSamples() throws {
        var decoder = MP2Decoder()
        for frame in frames {
            let pcm = decoder.decode(frame)
            #expect(pcm?.count == 1152 * 2)
        }
    }

    /// Not Layer II — no output. An MP3 frame through this decoder
    /// would be noise with an announcement.
    @Test("Foreign headers are rejected")
    func foreignHeadersAreRefused() {
        var decoder = MP2Decoder()
        #expect(decoder.decode(Data([0xFF, 0xFB, 0x90, 0x00])) == nil, "MP3")
        #expect(decoder.decode(Data([0x00, 0x01, 0x02, 0x03])) == nil, "no sync word")
        #expect(decoder.decode(Data()) == nil, "empty")
    }

    /// The result is deterministic — fixed point has no moods.
    @Test("Decoded twice is the same twice")
    func decodingIsDeterministic() throws {
        var first = MP2Decoder()
        var second = MP2Decoder()
        for frame in frames {
            let a = first.decode(frame)
            let b = second.decode(frame)
            #expect(a != nil && a == b)
        }
    }

    /// **The actual test**: the same real frames through both
    /// decoders, then search for the best shift and measure the match.
    /// Below 0.99 the port would be wrong — a table error
    /// drives the correlation straight down, a sign error
    /// makes it negative.
    @Test("It hears the same as Apple's decoder")
    func agreesWithAppleDecoder() throws {
        let info = try #require(MPEGAudio.info(in: MPEGAudioTests.capturedFrames))

        // Apple's path: MP2 → float PCM via AVAudioConverter (only there on the Mac).
        let description = try MPEGAudio.formatDescription(for: info)
        let compressed = AVAudioFormat(cmAudioFormatDescription: description)
        let pcmFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(info.sampleRate),
                channels: AVAudioChannelCount(info.channels),
                interleaved: false))
        let apple = try #require(
            AVAudioConverter(from: compressed, to: pcmFormat),
            "the reference decoder must be present on the Mac")

        var appleLeft: [Float] = []
        for frame in frames {
            let buffer = AVAudioCompressedBuffer(
                format: compressed, packetCapacity: 1, maximumPacketSize: frame.count)
            frame.withUnsafeBytes {
                buffer.data.copyMemory(from: $0.baseAddress!, byteCount: frame.count)
            }
            buffer.byteLength = UInt32(frame.count)
            buffer.packetCount = 1
            buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))

            let out = try #require(
                AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1152))
            let fed = Locked(false)
            var conversionError: NSError?
            // The same assurance as in the converter itself: The block runs
            // synchronously inside `convert` and does not escape — see
            // ``MPEGAudioTranscoder`` (AP15, 2026-09-02).
            nonisolated(unsafe) let once = buffer
            let status = apple.convert(to: out, error: &conversionError) { _, outStatus in
                if fed.exchange(true) {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return once
            }
            guard status != .error, let channel = out.floatChannelData else { continue }
            appleLeft.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        }

        // Unser Weg.
        var own = MP2Decoder()
        var ownLeft: [Float] = []
        for frame in frames {
            guard let pcm = own.decode(frame) else {
                Issue.record("Frame not decoded")
                return
            }
            for index in stride(from: 0, to: pcm.count, by: 2) {
                ownLeft.append(Float(pcm[index]) / 32768)
            }
        }

        try #require(appleLeft.count > 1500, "the reference delivered")
        try #require(ownLeft.count == 3 * 1152)

        // Beste Verschiebung im Bereich des Filterbank-Vorlaufs suchen.
        var best = -Double.infinity
        var bestLag = 0
        let window = 1500
        for lag in -600...600 {
            var dot = 0.0
            var a2 = 0.0
            var b2 = 0.0
            for index in 0..<window {
                let i = index + max(0, lag)
                let j = index + max(0, -lag)
                guard i < ownLeft.count, j < appleLeft.count else { break }
                let a = Double(ownLeft[i])
                let b = Double(appleLeft[j])
                dot += a * b
                a2 += a * a
                b2 += b * b
            }
            guard a2 > 0, b2 > 0 else { continue }
            let correlation = dot / (a2 * b2).squareRoot()
            if correlation > best {
                best = correlation
                bestLag = lag
            }
        }

        #expect(best > 0.99, "Correlation \(best) at shift \(bestLag) — the transfer is wrong")
    }
}

/// **The device path, forced on the Mac:** tvOS has no
/// Layer II decoder, there the full chain runs through the own one. On the Mac
/// the transcoder would always take Apple's — without the force the path that
/// this is actually about would never run through in any test.
@Suite("The transcoder on the device path")
struct OwnDecoderTranscodeTests {

    @Test("Real frames become AAC via the custom decoder")
    func producesAACThroughOwnDecoder() throws {
        let info = try #require(MPEGAudio.info(in: MPEGAudioTests.capturedFrames))
        let transcoder = try MPEGAudioTranscoder(checking: info, forcingOwnDecoder: true)
        #expect(transcoder.usesOwnDecoder)

        var packets = 0
        var bytes = 0
        for (index, frame) in MPEGAudio.frames(in: MPEGAudioTests.capturedFrames).enumerated() {
            let time = CMTime(
                value: CMTimeValue(index * info.samplesPerFrame),
                timescale: CMTimeScale(info.sampleRate))
            for packet in transcoder.transcode(frame, at: time) {
                packets += 1
                bytes += packet.payload.count
            }
        }
        // Three frames are 3456 values — after the encoder's lead-in at least
        // two full AAC packets (of 1024 each) must have come out.
        #expect(packets >= 2, "\(packets) packets from 3 frames")
        #expect(bytes > 200, "AAC with content, not empty wrappers")
    }

    @Test("On the Mac, Apple's decoder remains the first path")
    func appleStaysFirstOnTheMac() throws {
        let info = try #require(MPEGAudio.info(in: MPEGAudioTests.capturedFrames))
        let transcoder = try MPEGAudioTranscoder(checking: info)
        #expect(!transcoder.usesOwnDecoder)
    }
}

/// **Real time is a requirement, not a hope** — the on-device finding of
/// 2026-08-22 in the evening: The first version did not manage real time on the Apple TV in the
/// debug build (2 s of broadcast needed 3 s), the remuxer backed up, the
/// startup rose to 14 s, the audio fell 6.7 s behind. This test runs in the
/// same debug build as the device; one frame is 24 ms of broadcast, and the
/// limit leaves the A15 plenty of headroom compared with this machine.
@Suite("The decoder in real time")
struct MP2ThroughputTests {

    @Test("A frame is decoded in a fraction of its airtime")
    func decodesFasterThanRealTime() throws {
        let frames = MPEGAudio.frames(in: MPEGAudioTests.capturedFrames)
        var decoder = MP2Decoder()
        for frame in frames { _ = decoder.decode(frame) }  // Warm up

        // **The best of three passes, not the mean** (2026-09-02).
        // This test failed in the full run — 3.77 ms instead of 2.4 — while
        // it was green three times on its own: Next to it eight package builds were running. A
        // mean then measures the machine's load and not the
        // decoder, and a test that depends on the form of the day gets switched off at the
        // third failure and afterwards tests nothing at all.
        //
        // The minimum is the usual answer to that: The fastest pass
        // is the one in which the least got in the way — it measures what the code
        // can do, and not what the machine did on the side.
        let rounds = 200
        var bestPerFrame = Double.infinity
        for _ in 0..<3 {
            let start = Date()
            for _ in 0..<rounds {
                for frame in frames { _ = decoder.decode(frame) }
            }
            let duration =
                Date().timeIntervalSince(start) / Double(rounds * frames.count) * 1000
            bestPerFrame = min(bestPerFrame, duration)
        }

        // 24 ms would be real time on THIS machine — a tenth is required,
        // so that the device too stays clearly below it under channel-surfing load.
        #expect(
            bestPerFrame < 2.4,
            Comment(rawValue: String(format: "%.3f ms per frame — too slow", bestPerFrame)))
    }
}
