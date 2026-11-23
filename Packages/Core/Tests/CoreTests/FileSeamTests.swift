import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The seam with clusters that do not start at a keyframe** (F-023,
/// 2026-09-05, "K for Kestrel").
///
/// The test files always built their clusters at keyframes — and
/// exactly for that reason no test saw what mkvmerge files with clusters by
/// the clock do: The keyframe lies somewhere inside the cluster, the trailing read of the
/// previous piece stopped after a fixed number of bytes, and the frames
/// in between were taken by no piece. Here the step size of the trailing read is
/// tiny, so that the way to the keyframe takes several steps.
@Suite("The seam at clusters by the clock")
struct FileSeamTests {

    private static func file(_ name: String) throws -> (Data, Matroska.Header) {
        let reader = MatroskaReader()
        let blocks = reader.read(try MatroskaTests.fixture(name))
        let data = TestMatroskaFile.make(
            header: reader.header, blocks: blocks, clusterSeconds: 0.7, clustersAtKeyframes: false)
        return (data, reader.header)
    }

    /// The step size of the trailing read in this test — small, so that the
    /// way to the keyframe takes several steps.
    static let step = 4 << 10

    /// How many bytes after the cluster start the keyframe with this
    /// time lies.
    static func keyframeOffset(in data: Data, cluster: Int, time: Int64, track: Int) -> Int? {
        guard let element = Matroska.element(in: data, at: cluster), let size = element.size else {
            return nil
        }
        let body = data.subdata(
            in: (cluster + element.headerSize)..<min(cluster + element.headerSize + size, data.count))
        var clusterTime: Int64 = 0
        for child in Matroska.children(of: body) {
            let content = body.subdata(in: child.range)
            if child.id == Matroska.ID.clusterTimestamp {
                clusterTime = Int64(Matroska.unsigned(content))
            }
            guard child.id == Matroska.ID.simpleBlock,
                let trackNumber = Matroska.varint(in: content, at: 0),
                Int(trackNumber.value) == track
            else { continue }
            let relative = Int16(
                bitPattern: UInt16(content[content.startIndex + trackNumber.width]) << 8
                    | UInt16(content[content.startIndex + trackNumber.width + 1]))
            let flags = content[content.startIndex + trackNumber.width + 2]
            if flags & 0x80 != 0, clusterTime + Int64(relative) == time {
                return child.range.lowerBound
            }
        }
        return nil
    }
}
