import Foundation
import Testing

@testable import Core

/// **The MKV startup after AP72** (2026-10-11): Piece 1 is created as soon as the player fetches piece 0,
/// and the seek table arrives in its own size instead of 4 MB.
@Suite("MKV startup (AP72)")
struct MatroskaStartupTests {

    /// Collects which pieces were built.
    final class Built: @unchecked Sendable {
        private let lock = NSLock()
        private var indices: [Int] = []
        func memorize(_ index: Int) { lock.withLock { indices.append(index) } }
        var all: [Int] { lock.withLock { indices } }
    }

    @Test("The seek table at the end of the file is fetched at its size")
    func cuesAtBack() async throws {
        let file = Self.file(cuesAtFront: false, payload: 400 << 10)
        let state = try #require(MatroskaIndex.locateCues(inHead: file))
        let source = RangeRecordingSource(file)
        let session = try MatroskaFileSession(source: source)
        _ = try? await session.start()
        session.stop()
        let grabs = source.sections.filter { $0.lowerBound == state.cues }
        #expect(grabs.count == 1, "Fetches at the cues location: \(grabs)")
        #expect(grabs.first?.upperBound == file.count)
        #expect((grabs.first?.count ?? .max) <= MatroskaFileSession.cuesFirstGrab)
        #expect(session.indexOrigin == .cues)
    }

    @Test("Cues before the clusters: one 64 KB grab, not 4 MB of picture data")
    func cuesAtFront() async throws {
        let file = Self.file(cuesAtFront: true, payload: 400 << 10)
        let state = try #require(MatroskaIndex.locateCues(inHead: file))
        let element = try #require(Matroska.element(in: file.subdata(in: state.cues..<file.count), at: 0))
        let cuesTotal = try #require(element.totalSize)
        let source = RangeRecordingSource(file)
        let session = try MatroskaFileSession(source: source)
        _ = try? await session.start()
        session.stop()
        // The grab at the cues position and a possible follow-up grab directly behind it — nothing else.
        let grabs = source.sections.filter {
            $0.lowerBound == state.cues || $0.lowerBound == state.cues + MatroskaFileSession.cuesFirstGrab
        }
        let fetched = grabs.reduce(0) { $0 + $1.count }
        #expect(grabs.count == 1, "\(grabs)")
        #expect(fetched <= MatroskaFileSession.cuesFirstGrab + cuesTotal, "\(fetched) Bytes")
        #expect(session.indexOrigin == .cues)
    }

    /// Like ``RemuxerChecks/cuesAtFrontFile()``, but with large clusters and optionally
    /// cues at the back — so that a blanket grab behind the table would measurably take picture data along.
    static func file(cuesAtFront: Bool, payload: Int) -> Data {
        typealias T = TestMatroskaFile
        let ebml = T.element(Matroska.ID.ebml, T.element(0x4282, Data("matroska".utf8)))
        let info = T.element(
            Matroska.ID.info, T.element(Matroska.ID.timestampScale, T.unsigned(1_000_000)))
        let track = T.element(
            Matroska.ID.trackEntry,
            T.element(Matroska.ID.trackNumber, T.unsigned(1))
                + T.element(Matroska.ID.trackType, T.unsigned(1))
                + T.element(Matroska.ID.codecID, Data("V_MPEG4/ISO/AVC".utf8)))
        let tracks = T.element(Matroska.ID.tracks, track)
        func cluster(_ time: UInt64) -> Data {
            var block = Data([0x81, 0, 0, 0x80, 0, 0, 0, 1, 0x65])
            block.append(Data(repeating: 0x42, count: payload))
            return T.element(
                Matroska.ID.cluster,
                T.element(Matroska.ID.clusterTimestamp, T.unsigned(time))
                    + T.element(Matroska.ID.simpleBlock, block))
        }
        func seekHead(_ cues: Int) -> Data {
            T.element(
                Matroska.ID.seekHead,
                T.element(
                    Matroska.ID.seek,
                    T.element(Matroska.ID.seekID, T.identifier(Matroska.ID.cues))
                        + T.element(Matroska.ID.seekPosition, T.unsigned(UInt64(cues), width: 8))))
        }
        func cues(_ p1: Int, _ p2: Int) -> Data {
            func point(_ time: UInt64, _ location: Int) -> Data {
                T.element(
                    Matroska.ID.cuePoint,
                    T.element(Matroska.ID.cueTime, T.unsigned(time, width: 8))
                        + T.element(
                            Matroska.ID.cueTrackPositions,
                            T.element(Matroska.ID.cueTrack, T.unsigned(1))
                                + T.element(
                                    Matroska.ID.cueClusterPosition, T.unsigned(UInt64(location), width: 8))))
            }
            return T.element(Matroska.ID.cues, point(0, p1) + point(5000, p2))
        }
        let c1 = cluster(0)
        let c2 = cluster(5000)
        let preamble = seekHead(0).count + info.count + tracks.count
        let body: Data
        if cuesAtFront {
            let c1At = preamble + cues(0, 0).count
            let c2At = c1At + c1.count
            body = seekHead(preamble) + info + tracks + cues(c1At, c2At) + c1 + c2
        } else {
            let c1At = preamble
            let c2At = c1At + c1.count
            let cuesAt = c2At + c2.count
            body = seekHead(cuesAt) + info + tracks + c1 + c2 + cues(c1At, c2At)
        }
        return ebml + T.element(Matroska.ID.segment, body)
    }
}
