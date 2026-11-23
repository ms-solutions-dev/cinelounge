import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The channel that never ends.**
///
/// Everything before worked on a block that one has fully in front of one: start at the
/// front, stop at the back, seek in between. A channel has no
/// back. The bytes arrive in chunks whose boundaries have nothing to do with the boundaries
/// of the format.
///
/// So the check feeds **in small chunks** — and unfriendly ones: 1000
/// bytes are not a multiple of 188, so almost every chunk ends in the middle of
/// a packet. That is exactly what happens on the network, too.
@Suite("Continuous remuxing: the channel without an end")
struct TransportRemuxerTests {

    private func liveData() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts"))
        return try Data(contentsOf: url)
    }

    // MARK: - Der Leser

    /// A stream of pure nonsense must not let the buffer grow without
    /// limit — otherwise the TV runs out of memory, and the
    /// viewer sees a crash instead of a black area.
    @Test("A broken stream does not fill up the memory")
    func rubbishDoesNotGrowForever() {
        let reader = TransportStreamReader()
        for _ in 0..<64 {
            _ = reader.read(Data(repeating: 0x00, count: 256 * 1024))
        }
        #expect(reader.inventory.streams.isEmpty)
    }

    // MARK: - Der Umpacker

    /// Feeds the repackager in small chunks, as the network would.
    private func remuxed(chunkSize: Int = 4096) async throws -> (SegmentStore, TransportRemuxer) {
        let data = try liveData()
        let store = SegmentStore()
        let remuxer = TransportRemuxer(store: store)

        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + chunkSize, data.endIndex)
            remuxer.feed(Data(data[offset..<end]))
            offset = end
        }
        await remuxer.finish()

        return (store, remuxer)
    }

    // MARK: - Was die Paarung wirklich getan hat

    private func fieldsFixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/h264-fields-1080i", withExtension: "ts"))
        return try Data(contentsOf: url)
    }

    private let fieldInfo = H264Fields.SequenceInfo(
        allowsFields: true, frameNumBits: 6, separateColourPlane: false)

    private func piece(pts: UInt64) -> TransportStreamReader.Piece {
        TransportStreamReader.Piece(
            pid: 256, kind: .h264, pts: pts, dts: pts &- 10800, data: Data())
    }

    /// A NAL-1 slice header: `first_mb_in_slice = 0`, `slice_type = 0`,
    /// `pic_parameter_set_id = 0`, `frame_num` (6 bits), `field_pic_flag` and —
    /// only for a field — `bottom_field_flag`.
    private func slice(field: Bool, bottom: Bool = false) -> Data {
        var bits = "111" + String(repeating: "0", count: 6)
        bits += field ? (bottom ? "11" : "10") : "0"
        while bits.count % 8 != 0 { bits += "0" }
        var bytes: [UInt8] = [0x01]
        for start in stride(from: 0, to: bits.count, by: 8) {
            let index = bits.index(bits.startIndex, offsetBy: start)
            let end = bits.index(index, offsetBy: 8)
            bytes.append(UInt8(bits[index..<end], radix: 2) ?? 0)
        }
        return Data(bytes)
    }

    /// **The counter-test to `wholeFramesPassThrough`.** There an
    /// access unit without any slice NAL stands, and the pairing passes it through
    /// like a whole picture — correct as behaviour, wrong as information.
    /// "Progressive" and "we cannot read the header" have two
    /// different ways out, and from the diagnosis they could not previously be
    /// told apart.
    @Test("An unreadable slice header is not a whole picture")
    func unreadableSliceHeaderIsCountedApart() {
        var held: (units: [Data], piece: TransportStreamReader.Piece)?
        var half: H264Fields.Picture?
        var tally = TransportRemuxer.PairingTally()

        // 0x09 is an access-unit delimiter, not a slice NAL.
        _ = TransportRemuxer.paired(
            units: [Data([0x09])], piece: piece(pts: 1000), info: fieldInfo, held: &held,
            heldPicture: &half, tally: &tally)
        #expect(tally.unreadable == 1)
        #expect(tally.wholePictures == 0)
        #expect(tally.pairs == 0)
        #expect(tally.fields == 0)

        var second = TransportRemuxer.PairingTally()
        _ = TransportRemuxer.paired(
            units: [slice(field: false)], piece: piece(pts: 1000), info: fieldInfo, held: &held,
            heldPicture: &half, tally: &second)
        #expect(second.wholePictures == 1)
        #expect(second.unreadable == 0)
    }

    /// **The number at which decay becomes visible.** Two equal fields
    /// in a row replace the first; its picture is never shown.
    @Test("A lost partner is counted as an orphan")
    func lostPartnerIsCountedAsOrphan() {
        var held: (units: [Data], piece: TransportStreamReader.Piece)?
        var half: H264Fields.Picture?
        var tally = TransportRemuxer.PairingTally()
        let order = [false, true, false, false, true]

        for (index, bottom) in order.enumerated() {
            _ = TransportRemuxer.paired(
                units: [slice(field: true, bottom: bottom)],
                piece: piece(pts: UInt64(1000 + index * 900)), info: fieldInfo, held: &held,
                heldPicture: &half, tally: &tally)
        }

        #expect(tally.pairs == 2)
        #expect(tally.orphans == 1)
        #expect(tally.fields == 5)
        #expect(tally.wholePictures == 0)
        #expect(tally.unreadable == 0)
    }

    /// The line must not extend the progressive sessions by a zero line —
    /// the recording has enough of those.
    @Test("With a progressive stream the balance stays silent")
    func balanceStaysSilentWithoutFields() {
        #expect(
            TransportRemuxer.pairingBalance(
                TransportRemuxer.PairingTally(), pictures: 0, seconds: 10) == nil)
    }

    /// **The actual requirement: "interlaced, not de-interlaced" must not
    /// come back.** The sentence would be true as soon as there is a pair, and
    /// by construction — a diagnostic line that parrots the source code
    /// proves nothing. The two measured rates say the same thing
    /// and could just as well say the opposite.
    @Test("The balance of a two-hour channel names two rates")
    func balanceNamesBothRates() throws {
        let text = try #require(
            TransportRemuxer.pairingBalance(
                .init(pairs: 179613, orphans: 31, wholePictures: 0, unreadable: 0, fields: 359257),
                pictures: 179613, seconds: 7186))
        #expect(text.contains("179613 pairs"))
        #expect(text.contains("50.0 fields/s"))
        #expect(text.contains("25.0 pictures/s"))
        #expect(!text.contains("interwoven"))
    }

    /// **The regression for the refuted first draft.** It hung the tally on
    /// ``FrameCadence/rate``, and that matures at thirty intervals — what
    /// would come out is a startup tally over one second of broadcast, which would
    /// never see pairs decaying in the middle of a movie.
    @Test("The balance does NOT depend on the maturity of the clock measurement")
    func balanceDoesNotWaitForCadence() {
        #expect(12 < FrameCadence.minimumSamples)
        let line = TransportRemuxer.pairingBalance(
            .init(pairs: 6, orphans: 0, wholePictures: 0, unreadable: 0, fields: 12),
            pictures: 6, seconds: 0.24)
        #expect(line != nil)
        #expect(line?.contains("too short for a rate") == true)
    }

    /// Two to three orphans per session are the normal case — one when joining
    /// in the middle of a pair, one each after a break-off. A report for that would be
    /// noise.
    @Test("The decay only triggers above the threshold")
    func decayNeedsBothThresholds() {
        #expect(!TransportRemuxer.pairingDecays(.init(orphans: 2, fields: 400)))
        #expect(!TransportRemuxer.pairingDecays(.init(orphans: 2, fields: 4000)))
        #expect(TransportRemuxer.pairingDecays(.init(orphans: 400, fields: 4000)))
    }

    // MARK: - Der Schlüsselbild-Wächter (AP3 · V1 und V1b)

    /// **The bug that arose while fixing another — and reported itself
    /// as fixed.**
    ///
    /// The keyframe sets the boundary and lies **on** it. The source code
    /// cleared it for everything that did not lie *before* it — that is, in the same
    /// call in which it arose. The following pictures of the open
    /// group of pictures thus passed through unhindered (NOKTA TV HQ, MERCAN TV HQ:
    /// VideoToolbox `-12350`, and `AVAssetReader` discarded the whole track), and
    /// the sound began 80–200 ms before the picture again.
    ///
    /// **And nobody would have seen it:** `droppedLeadingPictures`,
    /// `droppedLeadingSound` and `soundBelongsToPicture` occurred in the checks
    /// **zero times** (V1b). The rule therefore now stands on its own.
    @Test("The keyframe does not clear its own boundary")
    func keyframeStaysOnTheBoundary() {
        #expect(TransportRemuxer.entry(pts: 90_000, limit: 90_000) == .kept)
    }

    /// What lies before belongs to a group of pictures that never existed here.
    @Test("What lies before the boundary is dropped")
    func beforeTheBoundary() {
        #expect(TransportRemuxer.entry(pts: 89_999, limit: 90_000) == .discard)
        #expect(TransportRemuxer.entry(pts: 0, limit: 90_000) == .discard)
    }

    /// **And the boundary falls at the first packet behind it.** Without this end it
    /// would be a permanent brake: after the overflow of the 33-bit stamps (26.5
    /// hours) or a timestamp break from the provider, `pts < limit` would be
    /// permanently true, and picture **and** sound would stop without a sound.
    @Test("Beyond the boundary it is dropped")
    func beyondTheLimit() {
        #expect(TransportRemuxer.entry(pts: 90_001, limit: 90_000) == .boundaryFalls)
    }
}

/// The line about the clock — it appears only if the clock had something to do.
@Suite("The clock balance")
struct ClockBalanceTests {

    @Test("A clock without work stays silent")
    func idleClockIsSilent() {
        #expect(TransportRemuxer.clockBalance(breaks: 0, wraps: 0, audioBehind: 0) == nil)
    }

    @Test("Breaks and discarded sound appear in one line")
    func breaksAndDropsAreNamed() throws {
        let row = try #require(TransportRemuxer.clockBalance(breaks: 3, wraps: 0, audioBehind: 7))
        #expect(row == "Clock: 3 breaks smoothed out, 7 audio packets behind it discarded")
        let withOverflow = try #require(TransportRemuxer.clockBalance(breaks: 0, wraps: 1, audioBehind: 0))
        #expect(withOverflow.contains("1 wraps"))
    }
}
