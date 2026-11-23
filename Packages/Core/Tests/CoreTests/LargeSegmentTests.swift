import Foundation
import Testing

@testable import Core

/// Files over two gigabytes — the bug that only hit the big films.
///
/// **The on-device finding of 2026-08-15, traced to its cause:** Hanabi (6.35 GB)
/// failed in the remuxer with `notMatroska` although header, track table and
/// seek table were flawless. The element reader carried a blanket
/// sanity limit of two billion bytes — right for leaves (there
/// such a length is a mistake in the middle of picture data), wrong for the containers:
/// The **segment** carries the length of the whole file. Every episode in the catalog
/// lies below the limit, every large feature film above it — that is why
/// remuxing worked for series and failed silently for films, and VLC got the
/// raw file (whose seek then loaded from byte zero: the reported
/// "buffer everything first").
@Suite("Matroska beyond two gigabytes")
struct LargeSegmentTests {

    /// A segment header as large files carry it: length as an 8-byte VINT.
    private func segmentHeader(size: UInt64) -> Data {
        var data = TestMatroskaFile.identifier(Matroska.ID.segment)
        // 8-byte VINT: marker 0x01, then seven bytes of length.
        data.append(0x01)
        for shift in stride(from: 48, through: 0, by: -8) {
            data.append(UInt8((size >> UInt64(shift)) & 0xFF))
        }
        return data
    }

    @Test("A six-gigabyte segment is an element, not a misparse")
    func largeSegmentParses() {
        let header = segmentHeader(size: 6_351_270_064)

        let element = Matroska.element(in: header, at: 0)

        #expect(element?.id == Matroska.ID.segment)
        #expect(element?.size == 6_351_270_064)
    }

    @Test("A leaf with a huge length remains a misparse")
    func hugeLeafIsStillRejected() {
        // The limit for leaves stays: A "CodecID of three gigabytes" is
        // not an element but an entry point in the middle of picture data — exactly the
        // confusion the limit protects against.
        var data = TestMatroskaFile.identifier(Matroska.ID.codecID)
        data.append(0x01)
        for shift in stride(from: 48, through: 0, by: -8) {
            data.append(UInt8((UInt64(3_000_000_000) >> UInt64(shift)) & 0xFF))
        }

        #expect(Matroska.element(in: data, at: 0) == nil)
    }

    /// The length of the EBML header at the start of the file.
    private func ebmlSize(of data: Data) -> Int {
        guard let ebml = Matroska.element(in: data, at: 0), let size = ebml.size else { return 0 }
        return ebml.headerSize + size
    }
}
