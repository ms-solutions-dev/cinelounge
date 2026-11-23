import CoreMedia
import Foundation
import Testing

@testable import Core

/// **Fields — the reason why half of the Turkish channel list showed no
/// picture.**
///
/// Viewer finding 2026-08-23: Telve 2, Telve 3 and AYAZ 2 in UHD still do not work … and
/// NOKTA TV HQ shows no picture at all. Measured on the real streams:
///
/// | Channel | `frame_mbs_only_flag` | Field pictures | DTS spacing | Picture |
/// |---|---|---|---|---|
/// | Telve 1 UHD | 1 (progressive) | 0 / 542 | 25 Hz | plays |
/// | SPORT DIGITAL HQ | 1 (true 720p50) | 0 / 906 | 50 Hz | plays |
/// | Telve 2 UHD | **0** | **762 / 762** | 50 Hz | broken |
/// | A2 UHD | **0** | **360 / 360** | 50 Hz | broken |
/// | NOKTA TV HQ | **0** | **329 / 329** | 50 Hz | broken |
///
/// Sport Digital is the control that rules out the obvious explanation:
/// true fifty frames, progressive, plays. It is not the frame rate.
///
/// The template `h264-fields-1080i.ts` is a recording of TR: Telve 2 UHD.
@Suite("Fields in H.264")
struct H264FieldsTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "ts"))
        return try Data(contentsOf: url)
    }

    private func sequenceInfo() throws -> (H264Fields.SequenceInfo, Data) {
        let data = try fixture("h264-fields-1080i")
        let video = try #require(TransportStream.inventory(from: data).video)
        let stream = TransportStream.elementaryStream(from: data, pid: video.pid)
        let sets = TransportStream.parameterSets(
            in: TransportStream.units(inElementaryStream: stream), kind: video.kind)
        let sps = try #require(sets.sps)
        return (try #require(H264Fields.sequenceInfo(fromSPS: sps)), data)
    }

    // MARK: - Der Bildsatz

    @Test("Garbage in the SPS yields nothing without crashing")
    func rubbishSPSIsRefused() {
        #expect(H264Fields.sequenceInfo(fromSPS: Data()) == nil)
        #expect(H264Fields.sequenceInfo(fromSPS: Data([0x67])) == nil)
        #expect(H264Fields.sequenceInfo(fromSPS: Data([0x67, 0xFF])) == nil)
    }

    /// The camouflage bytes: In the payload `00 00 03` stands for a literal `00 00`.
    /// A bit reader without this knowledge slips from the first such place on.
    @Test("Emulation prevention bytes are removed")
    func emulationPreventionIsUndone() {
        #expect(H264Fields.unescaped([0x00, 0x00, 0x03, 0x01]) == [0x00, 0x00, 0x01])
        #expect(H264Fields.unescaped([0x00, 0x00, 0x03, 0x00]) == [0x00, 0x00, 0x00])
        // Without two zeros before it, a 3 stays a 3.
        #expect(H264Fields.unescaped([0x01, 0x03, 0x04]) == [0x01, 0x03, 0x04])
    }

    // MARK: - Die Bilder selbst

    // MARK: - Die Paarung

    private func piece(pts: UInt64) -> TransportStreamReader.Piece {
        TransportStreamReader.Piece(
            pid: 256, kind: .h264, pts: pts, dts: pts &- 10800, data: Data())
    }

    private let fieldInfo = H264Fields.SequenceInfo(
        allowsFields: true, frameNumBits: 6, separateColourPlane: false)

    /// A whole frame passes through unchanged — even in a stream that
    /// may carry fields.
    ///
    /// **Until 2026-08-26 this held `Data([0x09])`** — an
    /// access-unit delimiter without any slice NAL.
    /// ``H264Fields/picture(in:info:)`` returns `nil` there, and the pairing passes
    /// `nil` through the same clause as a whole frame. The test was green and
    /// would have stayed green had field detection failed completely — it proved
    /// the unreadable header and not the pass-through. Now a real
    /// slice header with `field_pic_flag = 0` stands there, and the count bears witness
    /// to the difference: `wholePictures`, not `unreadable`.
    @Test("A whole frame is not touched")
    func wholeFramesPassThrough() throws {
        // First the precondition, without which the rest proves nothing.
        #expect(H264Fields.picture(in: [wholeFrameSlice()], info: fieldInfo) == .frame)

        var held: (units: [Data], piece: TransportStreamReader.Piece)?
        var half: H264Fields.Picture?
        var tally = TransportRemuxer.PairingTally()
        let result = TransportRemuxer.paired(
            units: [wholeFrameSlice()], piece: piece(pts: 1000), info: fieldInfo,
            held: &held, heldPicture: &half, tally: &tally)
        guard case .whole(let units, let out) = result else {
            Issue.record("not passed through"); return
        }
        #expect(units.count == 1)
        #expect(out.pts == 1000)
        #expect(held == nil)
        // The difference the old version could not see.
        #expect(tally.wholePictures == 1)
        #expect(tally.unreadable == 0)
        #expect(tally.fields == 0)
    }

    /// **A whole frame replaces a held field.** The field finds
    /// no partner any more; its picture is never shown, and the tally must see that
    /// as an orphan instead of silently dropping it.
    @Test("A whole frame orphans a held field")
    func wholeFrameOrphansHeldField() throws {
        var held: (units: [Data], piece: TransportStreamReader.Piece)?
        var half: H264Fields.Picture?
        var tally = TransportRemuxer.PairingTally()

        let first = TransportRemuxer.paired(
            units: [topFieldSlice()], piece: piece(pts: 1000), info: fieldInfo,
            held: &held, heldPicture: &half, tally: &tally)
        #expect(first == .wait)
        #expect(held != nil)

        let result = TransportRemuxer.paired(
            units: [wholeFrameSlice()], piece: piece(pts: 1900), info: fieldInfo,
            held: &held, heldPicture: &half, tally: &tally)
        guard case .whole(_, let out) = result else {
            Issue.record("not passed through"); return
        }
        #expect(out.pts == 1900)
        #expect(held == nil)
        #expect(tally.orphans == 1)
        #expect(tally.wholePictures == 1)
        #expect(tally.fields == 1)
    }

    /// **The timestamp of the FIRST field applies.** The second lies 20 ms
    /// later; if it were used, the picture would run ahead by half a frame.
    @Test("Two fields become one frame with the first timestamp")
    func twoFieldsBecomeOneFrame() throws {
        var held: (units: [Data], piece: TransportStreamReader.Piece)?

        let first = TransportRemuxer.paired(
            units: [topFieldSlice()], piece: piece(pts: 1000), info: fieldInfo, held: &held)
        #expect(first == .wait)
        #expect(held != nil)

        let second = TransportRemuxer.paired(
            units: [bottomFieldSlice()], piece: piece(pts: 1900), info: fieldInfo, held: &held)
        guard case .whole(let units, let out) = second else {
            Issue.record("not paired"); return
        }
        #expect(units.count == 2)
        #expect(out.pts == 1000)
        #expect(held == nil)
    }

    /// **Two equal fields in a row replace the first.** Happens when
    /// joining in the middle of a pair and after a drop — otherwise a foreign field would stick
    /// to a frame forever.
    @Test("An orphaned field is replaced, not paired")
    func orphanFieldIsReplaced() throws {
        var held: (units: [Data], piece: TransportStreamReader.Piece)?

        _ = TransportRemuxer.paired(
            units: [topFieldSlice()], piece: piece(pts: 1000), info: fieldInfo, held: &held)
        let again = TransportRemuxer.paired(
            units: [topFieldSlice()], piece: piece(pts: 1900), info: fieldInfo, held: &held)
        #expect(again == .wait)
        #expect(held?.piece.pts == 1900)

        // And after that it keeps pairing cleanly.
        let closing = TransportRemuxer.paired(
            units: [bottomFieldSlice()], piece: piece(pts: 2800), info: fieldInfo, held: &held)
        guard case .whole(_, let out) = closing else {
            Issue.record("not paired"); return
        }
        #expect(out.pts == 1900)
    }

    // MARK: - Built slice headers

    /// A NAL-1 slice header: `first_mb_in_slice = 0` (1 bit `1`),
    /// `slice_type = 0` (1 bit `1`), `pic_parameter_set_id = 0` (1 bit `1`),
    /// `frame_num` (6 bits, here zero), `field_pic_flag` and — only for a
    /// field — `bottom_field_flag`.
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

    private func topFieldSlice() -> Data { slice(field: true) }
    private func bottomFieldSlice() -> Data { slice(field: true, bottom: true) }
    private func wholeFrameSlice() -> Data { slice(field: false) }
}
