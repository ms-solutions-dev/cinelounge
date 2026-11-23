import CoreMedia
import Foundation
import Testing

@testable import Core

/// The seam between our readers and Apple's tools.
///
/// **Nothing is decoded here** — the picture data pass through unchanged, only their
/// wrapper changes. That is exactly why the checks here are so fine-grained: an error
/// in the bookkeeping does not look like an error, it looks like a picture that does
/// not come.
@Suite("Frame packets for Apple's decoder")
struct SampleAssemblyTests {

    // MARK: - Startmuster zu Längen

    /// In a transport stream `00 00 01` introduces every unit; in MP4 their length stands
    /// in front instead. The same material, different bookkeeping.
    @Test("Each unit is preceded by its length in four bytes")
    func lengthReplacesStartCode() {
        let units = [Data([0xAA, 0xBB, 0xCC]), Data([0xDD])]

        let packed = SampleAssembly.lengthPrefixed(units)

        #expect(
            [UInt8](packed) == [
                0, 0, 0, 3, 0xAA, 0xBB, 0xCC,
                0, 0, 0, 1, 0xDD,
            ]
        )
    }

    /// The length must be in the order MP4 expects — highest byte first. The other way
    /// round, the decoder reads a unit of 16 million bytes where three are.
    @Test("Large lengths put the highest byte first")
    func lengthIsBigEndian() {
        let unit = Data(repeating: 0x42, count: 300)

        let packed = SampleAssembly.lengthPrefixed([unit])

        #expect([UInt8](packed.prefix(4)) == [0, 0, 0x01, 0x2C])
        #expect(packed.count == 304)
    }

    @Test("Without units nothing comes out")
    func nothingInNothingOut() {
        #expect(SampleAssembly.lengthPrefixed([]).isEmpty)
    }

    // MARK: - Was Bild trägt und was nicht

    /// **Descriptions do not belong in the picture stream.** In the MP4 they sit in the
    /// head of the file; sent along once more they would be data without a picture to
    /// the decoder.
    @Test("Descriptions and delimiters are filtered out (HEVC)")
    func hevcParameterSetsAreRemoved() {
        let vps = Data([32 << 1, 0x01])
        let sps = Data([33 << 1, 0x01])
        let pps = Data([34 << 1, 0x01])
        let aud = Data([35 << 1, 0x01])
        let image = Data([1 << 1, 0x01])

        let kept = SampleAssembly.payloadUnits(from: [vps, sps, pps, aud, image], kind: .hevc)

        #expect(kept == [image])
    }

    @Test("The same for H.264, just with different numbers")
    func h264ParameterSetsAreRemoved() {
        let sps = Data([0x67, 0x01])
        let pps = Data([0x68, 0x01])
        let aud = Data([0x09, 0x01])
        let image = Data([0x65, 0x01])

        let kept = SampleAssembly.payloadUnits(from: [sps, pps, aud, image], kind: .h264)

        #expect(kept == [image])
    }

    // MARK: - Zeitstempel

    /// **The trickiest part of the whole remuxing.** The 33 bits of a timestamp are
    /// spread over five bytes and interrupted twice by marker bits. Whoever simply reads
    /// them one after another gets a number that is off by orders of magnitude — and a
    /// picture that appears at the wrong time or not at all.
    ///
    /// That is why this is checked against a **real** header from the test piece of
    /// "Telve 1 HEVC", whose value was recalculated by hand.
    @Test("Real PES header: the timestamp is read correctly")
    func realTimestampIsRead() {
        let header = Data([
            0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05,
            0x29, 0xD3, 0xBF, 0xA8, 0xC1,
        ])

        let pts = SampleAssembly.presentationTimestamp(inPESHeader: header)

        #expect(pts == 5_183_100_000)
        // And in seconds: exactly 57 590, because the clock is 90 000 per second.
        #expect(SampleAssembly.time(fromPTS: pts!).seconds == 57_590)
    }

    /// Not every packet carries a timestamp. An invented one would be worse than none —
    /// it would shift the picture to a place where it does not belong.
    @Test("Without a timestamp none is invented")
    func missingTimestampStaysNil() {
        // The same nine header bytes, but the flags say "nothing attached".
        let header = Data([
            0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x00, 0x00,
            0x29, 0xD3, 0xBF, 0xA8, 0xC1,
        ])

        #expect(SampleAssembly.presentationTimestamp(inPESHeader: header) == nil)
    }

    @Test("Broadcast I-frames without IDR count as keyframes — with a recovery point")
    func intraSlicesWithParameterSetsAreKeyframes() {
        // ALPA SPORT+ (2026-08-16): 241 access units, not a single NAL 5 — but an I-frame
        // (slice_type 7) with SPS in front of it every 0.8 s. slice_type 7 as Exp-Golomb
        // after first_mb_in_slice=0: bits "1" + "0001000" → 0x88.
        let sps = Data([0x67, 0x64, 0x00, 0x28])
        let iSlice = Data([0x41, 0x88, 0x80])
        #expect(SampleAssembly.isKeyframe([sps, iSlice], kind: .h264))

        // Without a parameter set the I-frame does not count — in the middle of the group
        // of pictures the entry without parameter sets could not be decoded anyway.
        #expect(!SampleAssembly.isKeyframe([iSlice], kind: .h264))
        // A P-slice (slice_type 5: bits "1" + "00110" → 0x98) does not become one.
        let pSlice = Data([0x41, 0x98])
        #expect(!SampleAssembly.isKeyframe([sps, pSlice], kind: .h264))
        // IDR stays what it was.
        #expect(SampleAssembly.isKeyframe([Data([0x65, 0x88])], kind: .h264))
    }

    /// **Only the head goes into the bit reader** (AP73): a UHD I-frame of one megabyte
    /// was copied completely until then, just to read two numbers from the first bytes.
    @Test("A large I-slice is recognized at the head, the rest stays unread")
    func largeSliceOnlyAtHead() {
        let payload = Data(repeating: 0x5A, count: 1 << 20)
        #expect(SampleAssembly.isIntraSlice(Data([0x41, 0x88, 0x80]) + payload))
        #expect(!SampleAssembly.isIntraSlice(Data([0x41, 0x98]) + payload))
        // first_mb_in_slice = 8159 (last macroblock in 1080p): 12 zeros + 13 bits, then
        // slice_type 7 as 0001000 — together exactly 32 bits, so 0x00 0x0F 0xF0 0x08.
        #expect(SampleAssembly.isIntraSlice(Data([0x41, 0x00, 0x0F, 0xF0, 0x08]) + payload))
        #expect(SampleAssembly.sliceHeaderBytes == 32)
        #expect(!SampleAssembly.isIntraSlice(Data([0x41])))
    }

    @Test("If the header carries both times, the decode time is read too")
    func decodingTimestampIsRead() {
        // Flags 0b11 (0xC0): presentation AND decoding time, header length 10. The case of
        // Sola Sport Mix (2026-08-16): picture reordering — without the decoding time the writer
        // died of times jumping backwards.
        let header = Data([
            0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0xC0, 0x0A,
            0x39, 0xD3, 0xBF, 0xA8, 0xC1,
            0x19, 0xD3, 0xBF, 0x8C, 0xA1,
        ])

        #expect(SampleAssembly.presentationTimestamp(inPESHeader: header) == 5_183_100_000)
        // 3600 ticks earlier — one frame distance at 25 per second.
        #expect(SampleAssembly.decodingTimestamp(inPESHeader: header) == 5_183_096_400)
    }

    @Test("Without a decode time none is invented")
    func missingDecodingTimestampStaysNil() {
        // Only the presentation time (flags 0b10) — as with channels without picture
        // reordering; an invented decoding time would be a wrong one.
        let header = Data([
            0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05,
            0x29, 0xD3, 0xBF, 0xA8, 0xC1,
        ])
        #expect(SampleAssembly.decodingTimestamp(inPESHeader: header) == nil)
        #expect(SampleAssembly.decodingTimestamp(inPESHeader: Data()) == nil)
    }

    @Test("What is not a PES header gives no timestamp")
    func garbageHasNoTimestamp() {
        #expect(SampleAssembly.presentationTimestamp(inPESHeader: Data()) == nil)
        #expect(
            SampleAssembly.presentationTimestamp(
                inPESHeader: Data(repeating: 0xFF, count: 20)) == nil
        )
    }

    /// A truncated header occurs when a request jumps into the middle.
    @Test("A header that is too short does not crash")
    func truncatedHeaderIsSafe() {
        let short = Data([0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80])
        #expect(SampleAssembly.presentationTimestamp(inPESHeader: short) == nil)
    }

    /// The length field in front of the units and the value with which the decoder
    /// description is built **must** match. If they differ, the decoder counts at the
    /// wrong place — without an error message, because it cannot know that it counted
    /// wrong.
    @Test("The prefix length is four — the same as in the decoder description")
    func prefixSizeMatchesTheDecoder() {
        #expect(SampleAssembly.lengthPrefixSize == 4)
    }
}
