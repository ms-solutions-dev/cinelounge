import CoreMedia
import Foundation
import Testing

@testable import Core

/// Tested on **real** frames from the Telve 1 HQ recording (2026-08-16) — the
/// header fields of MPEG audio are table work, and table errors only show
/// on values that really occur.
@Suite("MPEG-Audio")
struct MPEGAudioTests {

    /// Three whole frames from the recording: MPEG-1 Layer II, 256 kbit/s,
    /// 48 kHz, stereo — 768 bytes each.
    static let capturedFrames = Data(
        base64Encoded:
            "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"
    )!

    @Test("The real frame header is read correctly")
    func realHeader() throws {
        let info = try #require(MPEGAudio.info(in: Self.capturedFrames))

        #expect(info.layer == 2)
        #expect(info.isMPEG1)
        #expect(info.sampleRate == 48000)
        #expect(info.channels == 2)
        #expect(info.samplesPerFrame == 1152)
        #expect(info.frameSize == 768, "144 · 256000 / 48000")
    }

    @Test("An MP3 header is recognized as Layer III")
    func mp3Header() throws {
        // 0xFFFB9004: MPEG-1 Layer III, 128 kbit/s, 44.1 kHz — the
        // everyday case in old releases.
        let info = try #require(MPEGAudio.info(in: Data([0xFF, 0xFB, 0x90, 0x04])))

        #expect(info.layer == 3)
        #expect(info.sampleRate == 44100)
        #expect(info.samplesPerFrame == 1152)
        #expect(info.frameSize == 144 * 128_000 / 44100)
    }

    @Test("Garbage is not mistaken for a header")
    func garbageRejected() {
        #expect(MPEGAudio.info(in: Data([0x00, 0x00, 0x01, 0xE0])) == nil)
        // Synchronwort da, aber Bitraten-Index 15 (verboten):
        #expect(MPEGAudio.info(in: Data([0xFF, 0xFD, 0xF4, 0x0C])) == nil)
        #expect(MPEGAudio.info(in: Data([0xFF])) == nil)
    }

    @Test("A PES piece splits into whole frames")
    func frameSplitting() {
        let frames = MPEGAudio.frames(in: Self.capturedFrames)

        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.count == 768 })
    }

    @Test("A truncated frame at the end is discarded")
    func partialTailDropped() {
        let cut = Self.capturedFrames.prefix(768 * 2 + 100)
        let frames = MPEGAudio.frames(in: cut)

        // Two whole ones get through, the rest is not worth half a frame —
        // garbage at the decoder would be a crackle, the gap is inaudible.
        #expect(frames.count == 2)
    }

    @Test("Lead-in before the first frame is skipped")
    func leadingGarbageSkipped() {
        var data = Data([0x12, 0x34, 0xFF, 0x00])  // 0xFF without a valid header
        data.append(Self.capturedFrames.prefix(768))

        #expect(MPEGAudio.frames(in: data).count == 1)
    }

    @Test("The transcoder turns real frames into playable AAC")
    func transcoderProducesAAC() throws {
        let info = try #require(MPEGAudio.info(in: Self.capturedFrames))
        let transcoder = try #require(MPEGAudioTranscoder(info: info))

        var packets: [(payload: Data, time: CMTime)] = []
        for (index, frame) in MPEGAudio.frames(in: Self.capturedFrames).enumerated() {
            let time = CMTime(value: CMTimeValue(index * 1152), timescale: 48000)
            packets += transcoder.transcode(frame, at: time)
        }

        // 3456 samples in — at least two 1024 packets must be
        // out (the encoder may keep one back).
        #expect(packets.count >= 2)
        #expect(packets.allSatisfy { !$0.payload.isEmpty })

        // The times run with the samples: packet n at n · 1024/48000.
        for (index, packet) in packets.enumerated() {
            let expected = CMTime(value: CMTimeValue(index * 1024), timescale: 48000)
            #expect(packet.time == expected)
        }

        // And the description says AAC — what the writer knows.
        let description = transcoder.outputDescription
        let asbd = try #require(
            CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC)
        #expect(asbd.mSampleRate == 48000)
        #expect(asbd.mChannelsPerFrame == 2)
    }

    @Test("A time jump in the input re-anchors the output")
    func timeJumpReanchors() throws {
        let info = try #require(MPEGAudio.info(in: Self.capturedFrames))
        let transcoder = try #require(MPEGAudioTranscoder(info: info))
        let frames = MPEGAudio.frames(in: Self.capturedFrames)

        _ = transcoder.transcode(frames[0], at: CMTime(value: 0, timescale: 48000))
        // A jump of minutes — say a time break in the channel. Counting on
        // would mean putting the audio minutes away from the picture.
        let jumped = CMTime(value: 48000 * 300, timescale: 48000)
        let packets = transcoder.transcode(frames[1], at: jumped)

        for packet in packets {
            #expect(abs((packet.time - jumped).seconds) < 1, "close to the new anchor time")
        }
    }

    /// **A "doesn't work" cost a day on 2026-08-22** The diagnosis from the
    /// device said six times "this device has no transcoder", and after that it was
    /// open whether the MP2 decoder or the AAC encoder is missing — two findings with
    /// completely different ways out. The setup must name the step at
    /// which it stops.
    @Test("The setup names the step at which it fails")
    func theObstacleHasAName() throws {
        // On this machine the path works — then there is no failure reason.
        let info = try #require(MPEGAudio.info(in: Self.capturedFrames))
        #expect(throws: Never.self) { try MPEGAudioTranscoder(checking: info) }

        // And an impossible header does not get past the first step.
        // Zero channels do not exist; that already fails the description
        // or the PCM intermediate format — in any case with a name, not silently.
        let impossible = MPEGAudio.FrameInfo(
            layer: 2, isMPEG1: true, sampleRate: 48000, channels: 0,
            samplesPerFrame: 1152, frameSize: 768)
        do {
            _ = try MPEGAudioTranscoder(checking: impossible)
            Issue.record("a header without channels must not pass")
        } catch let obstacle as MPEGAudioTranscoder.Obstacle {
            // The value itself is the statement: It stands so in the diagnosis.
            #expect(!obstacle.rawValue.isEmpty)
        }
    }

    /// The convenience form stays convenient — the places in the middle of the data stream should
    /// not each have to carry a `do`/`catch`.
    @Test("The short form still returns nil instead of throwing")
    func theShortFormStillReturnsNil() {
        let impossible = MPEGAudio.FrameInfo(
            layer: 2, isMPEG1: true, sampleRate: 48000, channels: 0,
            samplesPerFrame: 1152, frameSize: 768)
        #expect(MPEGAudioTranscoder(info: impossible) == nil)
    }
}
