import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **AC-3 is not the special case it was long taken for.** 974 of 1408 titles in
/// the catalog carry it as an audio track — it is the most common audio format of
/// the library. Without this reader the repackager would be useless for two thirds
/// of the films.
@Suite("AC-3 and E-AC-3")
struct AC3AudioTests {

    static func firstAudioFrame(_ name: String) throws -> (Data, Matroska.Track) {
        let reader = MatroskaReader()
        let blocks = reader.read(try MatroskaTests.fixture(name))
        let track = try #require(reader.header.preferredAudio)
        let block = try #require(blocks.first { $0.track == track.number })
        return (try #require(block.frames.first), track)
    }

    /// An AC-3 frame of 128 bytes (48 kHz, smallest frame size) with arbitrary content.
    private static func frame(padding: UInt8) -> Data {
        var data = Data([0x0B, 0x77, 0x00, 0x00, 0x00, 0x40, 0x40, 0x00])
        data.append(Data(repeating: padding, count: 128 - data.count))
        return data
    }

    /// **TELE MOOS and SELA 1, 2026-09-04:** 74 of 2975 frames carried `0B 77` in the payload,
    /// and the splitter took each of them for a frame start — the frame fell into two
    /// halves that were too short and was gone.
    @Test("Frame splitting: a sync word in the payload does not cut a frame")
    func syncWordInPayload() throws {
        var first = Self.frame(padding: 0x11)
        first[40] = 0x0B
        first[41] = 0x77
        let second = Self.frame(padding: 0x22)
        let packet = first + second

        let frame = TransportRemuxer.ac3Frames(in: packet)
        #expect(frame.count == 2)
        #expect(frame.first == first)
        #expect(frame.last == second)
    }

    @Test("Frame splitting: a truncated remainder at the end of a packet is discarded, the rest stays")
    func truncatedRemainder() throws {
        let total = Self.frame(padding: 0x33)
        let packet = total + Self.frame(padding: 0x44).prefix(100)
        let frame = TransportRemuxer.ac3Frames(in: packet)
        #expect(frame == [total])
    }

}
