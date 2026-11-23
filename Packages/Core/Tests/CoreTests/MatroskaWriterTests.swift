import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The own writer for files** (F-023, 2026-09-05): What the
/// system writer makes from a Matroska, the own one must do the same —
/// the same number of frames, the same first and last presentation time, the same
/// number of audio packets — and AVFoundation must read it. The difference lies
/// only in that the own one has no input of its own that could cause a deviation.
@Suite("The in-house file writer")
struct MatroskaWriterTests {

    private static func remuxed(
        _ name: String, writer: TransportRemuxer.ChunkWriter
    ) async throws -> SegmentStore {
        let data = try MatroskaTests.fixture(name)
        let store = SegmentStore(retainsEverything: true, logsProduction: false)
        let remuxer = MatroskaRemuxer(
            store: store, options: .init(segmentDuration: .indefinite, writer: writer))
        var offset = 0
        while offset < data.count {
            let end = min(offset + 64 << 10, data.count)
            remuxer.feed(data.subdata(in: offset..<end))
            offset = end
        }
        await remuxer.finish()
        return store
    }

    private struct Balance: Equatable {
        var frames: Int
        var audio: Int
        var first: Int64
        var last: Int64
        var videoBase: UInt32
    }

    private static func balance(of store: SegmentStore) throws -> Balance {
        let header = try #require(store.headerData)
        let bases = TimelineProbeTests.timescales(header)
        var frames = 0
        var audio = 0
        var pts: [Int64] = []
        for index in 0..<store.count {
            guard let seg = store.segment(index) else { continue }
            for (_, body) in TimelineProbeTests.boxes(seg).filter({ $0.0 == "moof" }) {
                for f in TimelineProbeTests.fragments(body) {
                    if f.track == 1 {
                        frames += f.durations.count
                        var dts = f.start
                        for (i, d) in f.durations.enumerated() {
                            pts.append(dts + f.cts[i])
                            dts += d
                        }
                    } else {
                        audio += f.durations.count
                    }
                }
            }
        }
        return Balance(
            frames: frames, audio: audio, first: pts.min() ?? -1, last: pts.max() ?? -1,
            videoBase: bases[1] ?? 0)
    }
}
