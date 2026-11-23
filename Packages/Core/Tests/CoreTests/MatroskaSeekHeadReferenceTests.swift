import Foundation
import Testing

@testable import Core

/// **F-002 (2026-09-28):** "Lone Ascent" S01E14 — the first SeekHead names only a
/// second SeekHead at the end of the file, and only that one names the cues.
@Suite("Matroska: Cues via a second SeekHead")
struct MatroskaSeekHeadReferenceTests {

    private typealias T = TestMatroskaFile

    private func seek(_ id: UInt32, _ position: Int) -> Data {
        T.element(
            Matroska.ID.seek,
            T.element(Matroska.ID.seekID, T.identifier(id))
                + T.element(Matroska.ID.seekPosition, T.unsigned(UInt64(position), width: 8)))
    }

    @Test("The reference is found, and the second SeekHead names the Cues")
    func reference() throws {
        let tagsID: UInt32 = 0x1254_C367
        let first = T.element(
            Matroska.ID.seekHead, seek(Matroska.ID.seekHead, 5000) + seek(tagsID, 6000))
        let cluster = T.element(Matroska.ID.cluster, Data(repeating: 0, count: 16))
        let header = T.element(Matroska.ID.segment, first + cluster)

        #expect(MatroskaIndex.locateCues(inHead: header) == nil, "exactly the finding")
        let reference = try #require(MatroskaIndex.locateSeekHeadReference(inHead: header))
        #expect(reference.seekHead == reference.segmentStart + 5000)

        let second = T.element(Matroska.ID.seekHead, seek(Matroska.ID.cues, 4200))
        #expect(MatroskaIndex.cuesPosition(inSeekHeadElement: second) == 4200)
    }

    @Test("A chunk of data that is not a SeekHead names no Cues")
    func noSeekHead() {
        #expect(MatroskaIndex.cuesPosition(inSeekHeadElement: Data([0x1F, 0x43, 0xB6, 0x75, 0x80])) == nil)
    }
}
