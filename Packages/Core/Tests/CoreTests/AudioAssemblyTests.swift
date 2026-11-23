import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// Audio on its way from the transport stream into a packet for CoreMedia.
///
/// **Audio is the quieter half of repackaging** — and the trickier one: A wrongly
/// read frame is not noticed as a still frame, but as a crackle, as an offset to the
/// picture or as silence for which there is no message.
@Suite("Audio from the transport stream")
struct AudioAssemblyTests {

    /// A header from real material: `FF F1 4C 40 2C 9F FC` — the first frame of
    /// "Telve 1 HEVC".
    let realHeader = Data([0xFF, 0xF1, 0x4C, 0x40, 0x2C, 0x9F, 0xFC])

    @Test("A real header is read correctly")
    func realHeaderIsRead() throws {
        let header = try #require(AudioAssembly.header(at: 0, in: realHeader))

        #expect(header.objectType == 2)  // AAC-LC
        #expect(header.sampleRate == 48000)
        #expect(header.headerSize == 7)  // without checksum
        #expect(header.frameLength == 356)
    }

    /// **Twelve set bits occur by chance in audio data.** Without the additional checks
    /// the reader would find frames in the middle of noise and read nonsense from there
    /// on — audible as a crackle, visible as an error nowhere.
    @Test("A random sync pattern is not mistaken for a header")
    func randomSyncIsRejected() {
        // Sync pattern, but sample index 15 (forbidden) and length zero.
        #expect(AudioAssembly.header(at: 0, in: Data([0xFF, 0xF1, 0x7C, 0x00, 0x00, 0x00, 0x00])) == nil)
        // Too short for a header.
        #expect(AudioAssembly.header(at: 0, in: Data([0xFF, 0xF1, 0x4C])) == nil)
        // No sync pattern.
        #expect(AudioAssembly.header(at: 0, in: Data(repeating: 0x00, count: 16)) == nil)
    }

    /// **With a running channel you start in the middle of the stream.** The first bytes
    /// are then half a frame. Anyone who gives up has no audio at every channel switch.
    @Test("A partial start is skipped, not given up on")
    func brokenStartIsSkipped() {
        var data = Data([0x21, 0x37, 0x2E])  // Remainder of an earlier frame
        data.append(realHeader)
        data.append(Data(repeating: 0xAB, count: 356 - 7))

        let frames = AudioAssembly.frames(in: data)

        #expect(frames.count == 1)
        #expect(frames.first?.payload.count == 356 - 7)
    }

    /// **The ADTS header goes out.** In MP4 the same information appears exactly once in
    /// the track description; anyone who sends the header along hands the decoder seven
    /// bytes before every frame that it takes for audio.
    @Test("The header is no longer part of the content")
    func headerIsStripped() {
        var data = realHeader
        data.append(Data(repeating: 0x5A, count: 356 - 7))

        let frame = AudioAssembly.frames(in: data).first

        #expect(frame?.payload.first == 0x5A)
        #expect(frame?.payload.count == 349)
    }

    // MARK: - Am echten Sender

    private func liveAudio() throws -> (
        payloads: [TransportStream.ElementaryPayload], kind: TransportStream.StreamKind
    ) {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts"))
        let data = try Data(contentsOf: url)
        let audio = try #require(TransportStream.inventory(from: data).audio)

        return (TransportStream.payloads(from: data, pid: audio.pid), audio.kind)
    }

    /// **If Apple's own function accepts our values, they are right.** The same argument
    /// as with the picture: What the decoder can describe, it can also play.
    @Test("CoreMedia builds a valid description from the header")
    func formatDescriptionIsAccepted() throws {
        let header = try #require(AudioAssembly.header(at: 0, in: realHeader))
        let format = try AudioAssembly.formatDescription(for: header)

        let asbd = try #require(format.audioStreamBasicDescription)
        #expect(asbd.mSampleRate == 48000)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC)
        #expect(asbd.mFramesPerPacket == 1024)
    }
}

/// **The description without which the audio stays silent.**
///
/// Measured on 2026-08-11 on a real channel: The repackaged stream carried an audio
/// track of the right length, `ffprobe` read it as `aac` — but without `extradata` and
/// with the wrong channel count. ffmpeg decoded it anyway, because it guesses the
/// description from the first frame; Apple's decoder does not do that and delivered
/// zero packets with the error `'bada'`. For the viewer: picture plays, no audio.
@Suite("AAC description")
struct AACCookieTests {

    @Test("The AudioSpecificConfig carries object type, rate and channel layout")
    func configHasAllThree() throws {
        // AAC-LC (2) · 48 kHz (Tabellenplatz 3) · mono (1)
        // 00010 0011 0001 000 → 0x11 0x88
        let config = try #require(AudioAssembly.audioSpecificConfig(sampleRate: 48000, channels: 1))
        #expect(Array(config) == [0x11, 0x88])

        // And the path for Matroska reads the same two bytes back out — both directions have
        // to match, otherwise one source sounds different from the other.
        let read = AudioAssembly.configuration(fromAudioSpecificConfig: config)
        #expect(read?.sampleRate == 48000)
        #expect(read?.channels == 1)
    }

    @Test("The cookie is a complete esds structure, not the bare configuration")
    func cookieIsAFullESDS() throws {
        // **The earlier finding "with a cookie no audio track" was right and the lesson from
        // it wrong:** Back then the bare two bytes were passed. CoreMedia expects the whole
        // structure — ES_Descriptor (0x03) above DecoderConfigDescriptor (0x04) above
        // DecoderSpecificInfo (0x05).
        let cookie = try #require(AudioAssembly.magicCookie(sampleRate: 48000, channels: 1))
        let bytes = Array(cookie)

        #expect(bytes.first == 0x03)
        #expect(bytes.count == 27)
        // The length value has to match the rest, otherwise CoreMedia reads past it.
        #expect(Int(bytes[1]) == bytes.count - 2)
        #expect(bytes.contains(0x04))
        // The configuration stands as DecoderSpecificInfo with its length in front.
        let marker = try #require(
            bytes.indices.first { bytes[$0] == 0x05 && $0 + 3 < bytes.count && bytes[$0 + 1] == 2 })
        #expect(Array(bytes[(marker + 2)...(marker + 3)]) == [0x11, 0x88])
    }

    @Test("The description carries the cookie and the right channel count")
    func descriptionCarriesTheCookie() throws {
        // The channel is mono; before, the finished file said "2 channels".
        let description = try AudioAssembly.formatDescription(sampleRate: 48000, channels: 1)
        var size = 0
        _ = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size)
        #expect(size == 27)

        let asbd = try #require(
            CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mChannelsPerFrame == 1)
        #expect(asbd.mSampleRate == 48000)
    }

    @Test("An unknown sample rate ends up without a cookie instead of without a track")
    func unknownRateStillProducesATrack() throws {
        // Better a track without a description than none at all — the old state was at least
        // usable for most sources.
        #expect(AudioAssembly.magicCookie(sampleRate: 12345, channels: 2) == nil)
        #expect(throws: Never.self) {
            try AudioAssembly.formatDescription(sampleRate: 12345, channels: 2)
        }
    }
}
