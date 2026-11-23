import Foundation
import Testing

@testable import Core

/// **Testing is done on real files from the media library**, not on built ones.
///
/// The beginnings of four titles, one megabyte each: HEVC with AAC, HEVC with E-AC-3,
/// H.264 with AAC, H.264 with AC-3. These are not four examples but the
/// four combinations that make up 96 percent of the catalog — what runs here
/// runs on the media library.
@Suite("Reading MKV")
struct MatroskaTests {

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "mkv"))
        return try Data(contentsOf: url)
    }

    // MARK: - Zahlen und Elemente

    /// **The building block everything stands on.** If it is off, every
    /// position in the file is off — and without an error message.
    @Test("Variable-length numbers")
    func varints() {
        // One byte: 1xxxxxxx — marker removed, value 1.
        #expect(Matroska.varint(in: Data([0x81]), at: 0)?.value == 1)
        #expect(Matroska.varint(in: Data([0x81]), at: 0)?.width == 1)
        // Zwei Bytes: 01xxxxxx xxxxxxxx
        #expect(Matroska.varint(in: Data([0x40, 0x7F]), at: 0)?.value == 127)
        // Identifiers keep the marker, because they are compared as a whole.
        #expect(Matroska.varint(in: Data([0xA3]), at: 0, keepMarker: true)?.value == 0xA3)
        // All payload bits set means "length unknown".
        #expect(Matroska.varint(in: Data([0xFF]), at: 0)?.isUnknown == true)
        #expect(Matroska.varint(in: Data([0x81]), at: 0)?.isUnknown == false)
        // A zero byte does not exist — it would mean "more than eight bytes".
        #expect(Matroska.varint(in: Data([0x00, 0x01]), at: 0) == nil)
        // Truncated: better nothing than half a number.
        #expect(Matroska.varint(in: Data([0x40]), at: 0) == nil)
    }

    @Test("An element consists of an ID and a length")
    func elements() throws {
        // 0x1A45DFA3 (four bytes of identifier), length 0x23 in one byte.
        let data = Data([0x1A, 0x45, 0xDF, 0xA3, 0xA3])
        let element = try #require(Matroska.element(in: data, at: 0))
        #expect(element.id == Matroska.ID.ebml)
        #expect(element.headerSize == 5)
        #expect(element.size == 0x23)

        // Open length: not an error but a piece of information.
        let open = try #require(Matroska.element(in: Data([0x18, 0x53, 0x80, 0x67, 0xFF]), at: 0))
        #expect(open.id == Matroska.ID.segment)
        #expect(open.size == nil)
    }

    // MARK: - Kopf

    // MARK: - Blöcke

    // MARK: - Bündelung

    /// **With audio, several frames lie in one block.** Three ways to state their
    /// lengths; whoever implements only the first gets audio that breaks off after one second,
    /// without an error anywhere.
    @Test("Bundled frames are separated")
    func lacing() throws {
        // Without lacing: everything is one frame.
        #expect(Matroska.frames(in: Data([1, 2, 3]), lacing: 0) == [Data([1, 2, 3])])

        // Xiph: count minus one, then for all but the last frame the
        // length as a sequence of 255s.
        let xiph = Data([2, 3, 2] + [1, 1, 1] + [2, 2] + [3, 3, 3])
        #expect(
            Matroska.frames(in: xiph, lacing: 1)
                == [Data([1, 1, 1]), Data([2, 2]), Data([3, 3, 3])])

        // Fixed: equal length, the length results from the division.
        #expect(
            Matroska.frames(in: Data([1, 7, 7, 8, 8]), lacing: 2)
                == [Data([7, 7]), Data([8, 8])])

        // EBML: first length as a number, each further one as a difference from the previous.
        // 0x82 = 2, then 0xBF = 63 - 63 = 0 (same length as the previous one).
        let ebml = Data([2, 0x82, 0xBF] + [1, 1] + [2, 2] + [3, 3])
        #expect(
            Matroska.frames(in: ebml, lacing: 3)
                == [Data([1, 1]), Data([2, 2]), Data([3, 3])])
    }

    // MARK: - Was einmal je Datei berichtet wird

    /// **282 of 5523 lines came from a single function** (test agent
    /// 2026-08-24). ``MatroskaFileSession/produce(_:delay:)`` runs per fetched
    /// piece; the findings almost never change in the process. What is tested is the lock
    /// as a pure calculation — that is why it is a type of its own.
    ///
    /// Claiming is done into a separate variable each time: `#expect` takes an
    /// expression apart into its parts and would not get past ``FileReportGate/claim(_:)``
    /// as a mutating method.
    @Test("A finding is reported once per file, not per piece")
    func reportOncePerFile() {
        var gate = MatroskaFileSession.FileReportGate()
        let first = gate.claim(.reorderClean)
        #expect(first)
        for _ in 0..<50 {
            let again = gate.claim(.reorderClean)
            #expect(!again)
        }
    }

    /// **The actual requirement.** The obvious fix — reporting only for the
    /// first piece — would look just the same in everyday use and would have swallowed the
    /// Jade Comet bug of 2026-08-23: It only appeared in the middle of the film.
    /// The lock is therefore per kind of finding, not per piece.
    @Test("A degradation in the middle of the film is still reported")
    func laterFindingStillReported() {
        var gate = MatroskaFileSession.FileReportGate()
        // Piece 3 is clean.
        let clean = gate.claim(.reorderClean)
        #expect(clean)
        // Piece 400 tips over — and gets through anyway.
        let tipped = gate.claim(.reorderCorrected)
        #expect(tipped)
        let repeated = gate.claim(.reorderCorrected)
        #expect(!repeated)
    }

    /// So that the locks do not block each other: Every kind of finding has
    /// its own slot, and none uses up that of another.
    @Test("Each kind of finding has its own lock")
    func everyFindingHasItsOwnGate() {
        let all: [MatroskaFileSession.FileReportGate.Finding] = [
            .timelineEven, .timelineDuplicates, .timelineHistogram,
            .reorderClean, .reorderCorrected,
            .seam, .seamGap,
            .writerDead,
        ]
        var gate = MatroskaFileSession.FileReportGate()
        for finding in all {
            let claimed = gate.claim(finding)
            #expect(claimed, "\(finding) must pass the first time")
        }
        for finding in all {
            let again = gate.claim(finding)
            #expect(!again, "\(finding) must not pass a second time")
        }
    }

    // MARK: - Die Verteilung der Bildabstände

    private func timeline(gaps: [Double]) -> MatroskaRemuxer.PictureTimeline {
        MatroskaRemuxer.PictureTimeline(
            count: gaps.count + 1, duplicates: gaps.filter { $0 == 0 }.count,
            rate: nil, jitter: nil, gaps: gaps)
    }

    /// **The one distinguishing question** (2026-08-23, "Jade Comet"): So far the
    /// recording only said THAT frames share a time — not
    /// WHERE FROM. Zeros and duplicates in equal numbers are the signature of our
    /// reordering: one frame at the time of its neighbour and behind it the
    /// double gap.
    @Test("The signature of our reordering: zeros and duplicates in equal number")
    func reorderSignatureIsVisible() {
        let line = timeline(gaps: Array(repeating: [0.04, 0, 0.08], count: 16).flatMap { $0 })
        let bars = line.histogram

        #expect(line.medianGap == 0.04)
        #expect(bars.zero == 16)
        #expect(bars.single == 16)
        #expect(bars.double == 16)
        #expect(bars.longer == 0)
        #expect(line.irregularShare > 0.6)
    }

    /// **Otherwise the threshold would be a claim.** Every Matroska file
    /// stamps onto a millisecond grid; at 23.976 Hz the spacings alternate between
    /// 41 and 42 ms. That is the same case on which ``FrameCadence/rate``
    /// missed once before — here it must not
    /// ring.
    @Test("A millisecond grid is not a finding")
    func millisecondGridIsNoFinding() {
        let line = timeline(
            gaps: (0..<40).map { $0 % 2 == 0 ? 0.041 : 0.042 })

        #expect(line.irregularShare == 0)
        #expect(line.irregularShare <= MatroskaFileSession.gapHistogramThreshold)
        #expect(line.histogram.zero == 0)
    }

    /// **And the line distinguishes the two causes instead of merely
    /// ringing.** A 3:2 pulldown or true VFR has not a single
    /// zero — then it is the file's doing, not ours.
    @Test("3:2 looks different from our reordering")
    func pulldownLooksDifferent() {
        let line = timeline(gaps: (0..<40).map { $0 % 2 == 0 ? 0.0334 : 0.0501 })

        #expect(line.histogram.zero == 0)
        #expect(line.irregularShare > MatroskaFileSession.gapHistogramThreshold)
    }

    /// **The worst conceivable case of the reordering, and it almost stayed
    /// silent:** If more than half of all spacings are zero, so is
    /// the median — and every derived quantity would bail out on `median > 0`.
    /// Of all files the most broken one would get no line.
    @Test("A median remains even with mostly duplicate timestamps")
    func medianSurvivesMajorityOfDuplicates() {
        let line = timeline(gaps: [0, 0, 0, 0, 0, 0, 0.04, 0.08, 0.08])

        #expect(line.medianGap == 0.08)
        #expect(line.irregularShare > MatroskaFileSession.gapHistogramThreshold)
        #expect(line.histogram.zero == 6)
    }

    /// Without two frames there is no spacing — and no division.
    @Test("Without two frames there are no gaps")
    func emptyTimelineDoesNotDivide() {
        for count in [0, 1] {
            let line = MatroskaRemuxer.PictureTimeline(
                count: count, duplicates: 0, rate: nil, jitter: nil, gaps: [])
            #expect(line.gaps.isEmpty)
            #expect(line.medianGap == nil)
            #expect(line.irregularShare == 0)
            #expect(line.histogram == MatroskaRemuxer.PictureTimeline.Histogram())
        }
    }
}
