import Foundation
import Testing

@testable import Core

/// The reader for transport streams — tested on real material.
///
/// **The test piece is not a replica.** It is ten packets from a segment
/// that a real Jellyfin server delivered (H.264 with AAC, 2026-08-08):
/// program table, program description and eight picture packets. A packet
/// put together by hand would only prove that my reader understands my own
/// idea of the format — and that is the trap that snaps shut most often in
/// format work.
///
/// The synthetic cases beside it test what real material does not yield:
/// lost alignment, MPEG-2, junk.
@Suite("Reading a transport stream")
struct TransportStreamTests {

    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/transport-stream", withExtension: "ts")
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Die Grenzen des Vorhabens

    /// **The hard wall.** No Apple TV decodes MPEG-2; where that shows up,
    /// no repackaging helps. The reader must be able to say so **before** weeks
    /// flow into a repackager.
    @Test("MPEG-2 counts as not decodable")
    func mpeg2IsOutOfReach() {
        #expect(!TransportStream.StreamKind.mpeg2Video.isHardwareDecodable)
        // MP2 **sound** was wrongly on this list for a long time — yet
        // CoreAudio decodes it just fine (2026-08-16, Turkish
        // national channels: picture played, sound was missing for no reason).
        #expect(TransportStream.StreamKind.mp2Audio.isHardwareDecodable)
        #expect(TransportStream.StreamKind.hevc.isHardwareDecodable)
        #expect(TransportStream.StreamKind.h264.isHardwareDecodable)
    }

    @Test("Unknown types count as not decodable")
    func unknownIsNotAssumedToWork() {
        // When in doubt claim nothing: an unknown type that counted as
        // playable would later yield a black picture without explanation.
        #expect(!TransportStream.StreamKind.other(0x42).isHardwareDecodable)
    }

    @Test("The stream type IDs match the specification")
    func streamTypesMatchTheSpecification() {
        #expect(TransportStream.StreamKind.from(streamType: 0x1B) == .h264)
        #expect(TransportStream.StreamKind.from(streamType: 0x24) == .hevc)
        #expect(TransportStream.StreamKind.from(streamType: 0x02) == .mpeg2Video)
        #expect(TransportStream.StreamKind.from(streamType: 0x0F) == .aac)
        #expect(TransportStream.StreamKind.from(streamType: 0x81) == .ac3)
        #expect(TransportStream.StreamKind.from(streamType: 0x87) == .eac3)
        #expect(TransportStream.StreamKind.from(streamType: 0x99) == .other(0x99))
    }

    /// **Type 0x06 only means "private PES data"** — what is inside is only told by
    /// the DVB descriptor. That is how DVB packs its AC-3 sound, and that is how "A2 UHD"
    /// arrived silent on 2026-08-22: the diagnosis said "sound type 0x06" while the
    /// AC-3 path was long since ready in the house.
    @Test("Private PES data is recognized by its descriptor")
    func privateDataIsResolvedByDescriptor() {
        // AC-3 descriptor (0x6A), content irrelevant — the tag is the statement.
        #expect(
            TransportStream.StreamKind.from(
                streamType: 0x06, descriptors: Data([0x6A, 0x01, 0x00])) == .ac3)
        // E-AC-3-Descriptor (0x7A).
        #expect(
            TransportStream.StreamKind.from(
                streamType: 0x06, descriptors: Data([0x7A, 0x01, 0x00])) == .eac3)
        // Registration (0x05) with the format abbreviation "AC-3" as ASCII.
        #expect(
            TransportStream.StreamKind.from(
                streamType: 0x06, descriptors: Data([0x05, 0x04, 0x41, 0x43, 0x2D, 0x33])) == .ac3)
        // The target descriptor may also stand behind a foreign one —
        // language identifier (0x0A) first is the rule with DVB.
        #expect(
            TransportStream.StreamKind.from(
                streamType: 0x06,
                descriptors: Data([0x0A, 0x04, 0x74, 0x75, 0x72, 0x00, 0x6A, 0x01, 0x00])) == .ac3)
    }

    /// Teletext and DVB subtitles travel in the same type — they must not count as
    /// sound, otherwise ``claimAudio`` would nail the sound onto a text stream.
    /// **Since 2026-09-03 they are recognised** (AP6): as subtitles, not as
    /// sound — and an audio marker beside them wins.
    @Test("Private PES data with a text descriptor is subtitles, never audio")
    func privateDataWithoutAudioStaysUnknown() {
        // Teletext-Descriptor (0x56).
        let teletext = TransportStream.StreamKind.from(
            streamType: 0x06, descriptors: Data([0x56, 0x01, 0x00]))
        #expect(teletext == .teletext)
        #expect(teletext.isSubtitle && !teletext.isVideo && !teletext.isHardwareDecodable)
        // DVB-Untertitel (0x59).
        #expect(
            TransportStream.StreamKind.from(
                streamType: 0x06, descriptors: Data([0x59, 0x01, 0x00])) == .dvbSubtitle)
        // Text AND AC-3 in the same stream: the sound wins.
        #expect(
            TransportStream.StreamKind.from(
                streamType: 0x06, descriptors: Data([0x56, 0x01, 0x00, 0x6A, 0x01, 0x00])) == .ac3)
        // And the table lists them separately from the audio streams.
        let inventory = TransportStream.Inventory(streams: [
            .init(pid: 1, kind: .h264), .init(pid: 2, kind: .mp2Audio, language: "deu"),
            .init(pid: 3, kind: .teletext, language: "deu"), .init(pid: 4, kind: .dvbSubtitle),
        ])
        #expect(inventory.audioStreams.map(\.pid) == [2])
        #expect(inventory.subtitleStreams.map(\.pid) == [3, 4])
        // No description at all.
        #expect(TransportStream.StreamKind.from(streamType: 0x06) == .other(0x06))
        // A broken length that points past the end does not run amok.
        #expect(
            TransportStream.StreamKind.from(
                streamType: 0x06, descriptors: Data([0x0A, 0xFF])) == .other(0x06))
    }

    // MARK: - Ausrichtung

    /// **A single `0x47` is no proof** — the byte occurs in picture data
    /// all the time. Only the second one at a distance of 188 bytes establishes the
    /// packet boundary; otherwise one would read only nonsense from a coincidence on.
    @Test("A stray sync byte does not mislead")
    func loneSyncByteIsNotMistakenForAPacket() {
        var data = Data(repeating: 0x00, count: 400)
        data[10] = TransportStream.syncByte

        #expect(TransportStream.firstPacketOffset(in: data) == nil)
    }

    @Test("Two bytes at the right distance count as a packet boundary")
    func twoSyncBytesInLineAreAccepted() {
        var data = Data(repeating: 0x00, count: 500)
        data[10] = TransportStream.syncByte
        data[10 + TransportStream.packetSize] = TransportStream.syncByte

        #expect(TransportStream.firstPacketOffset(in: data) == 10)
    }

    // MARK: - Was nicht passt

    @Test("Empty data yields an empty result")
    func emptyDataIsEmpty() {
        let inventory = TransportStream.inventory(from: Data())
        #expect(inventory.streams.isEmpty)
        #expect(!inventory.isFullyHardwareDecodable)
        #expect(inventory.summary == "empty")
    }

    @Test("Garbage does not crash and claims nothing")
    func garbageIsHandledQuietly() {
        let noise = Data((0..<2000).map { UInt8(($0 * 37) % 256) })
        let inventory = TransportStream.inventory(from: noise)

        // Whether an alignment is found by chance in the process is irrelevant —
        // no result may arise from it.
        #expect(!inventory.isFullyHardwareDecodable)
    }
}
