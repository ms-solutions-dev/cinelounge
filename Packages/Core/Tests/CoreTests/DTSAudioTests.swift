import AVFoundation
import Foundation
import Testing

@testable import Core

/// DTS in the app (AP10 · 1, 2026-09-04): The core from libdcadec, the PCM to AAC. The test
/// file is an excerpt from a real DTS 5.1 Matroska (H.264, 48 kHz), 1 MiB like the
/// others.
struct DTSAudioTests {

    @Test("Little-endian frames are swapped, 14-bit forms rejected")
    func framing() {
        let littleEndian = Data([0xFE, 0x7F, 0x01, 0x80, 0xAA, 0xBB])
        #expect(DTSAudio.framing(of: littleEndian) == .littleEndian16)
        #expect(DTSAudio.normalized(littleEndian) == Data([0x7F, 0xFE, 0x80, 0x01, 0xBB, 0xAA]))
        #expect(DTSAudio.normalized(Data([0x1F, 0xFF, 0xE8, 0x00, 0, 0])) == nil)
        #expect(DTSAudio.normalized(Data([1, 2, 3, 4])) == nil)
        #expect(DTSAudio.info(in: Data([0x7F, 0xFE, 0x80, 0x01])) == nil)
    }

    @Test("The stereo downmix drops LFE and halves the centre")
    func downmixRoutes() {
        let center = DTSTranscoder.routes(for: 0x4, target: .stereo)
        #expect(center.count == 2)
        #expect(center.allSatisfy { abs($0.1 - 0.7071) < 0.001 })
        #expect(DTSTranscoder.routes(for: 0x8, target: .stereo).isEmpty)
        #expect(DTSTranscoder.routes(for: 0x8, target: .surround51).map(\.0) == [3])
        // Side speakers end up in 5.1 in the rear positions.
        #expect(DTSTranscoder.routes(for: 0x200, target: .surround51).map(\.0) == [4])
        #expect(DTSTranscoder.routes(for: 0x400, target: .surround51).map(\.0) == [5])
    }

    @Test("A four-channel frame is mixed down to stereo")
    func fourChannelsBecomeStereo() throws {
        let info = DTSAudio.FrameInfo(
            sampleRate: 48000, channels: 4, samplesPerFrame: 512, profile: "DTS")
        let transcoder = try DTSTranscoder(checking: info)
        let asbd = try #require(transcoder.outputDescription.audioStreamBasicDescription)
        #expect(asbd.mChannelsPerFrame == 2)

        // FL FR BL BR, 16 Bit: links laut, rechts still.
        let planes: [[Int32]] = [
            Array(repeating: 16384, count: 8), Array(repeating: 0, count: 8),
            Array(repeating: 16384, count: 8), Array(repeating: 0, count: 8),
        ]
        let output = DTSDecoder.Output(
            planes: planes, channelMask: 0x33, sampleRate: 48000, bitsPerSample: 16, profile: 1)
        let pcm = try #require(transcoder.pcmBuffer(from: output))
        #expect(pcm.frameLength == 8)
        let left = pcm.floatChannelData![0][0]
        let right = pcm.floatChannelData![1][0]
        #expect(abs(left - (0.5 + 0.5 * 0.7071)) < 0.001)
        #expect(right == 0)
    }
}
