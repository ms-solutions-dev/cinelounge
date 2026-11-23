import Foundation
import Testing

@testable import Core

/// The walk through the clusters (F-008, 2026-09-04): a directory for files
/// without cues — truncated downloads, muxers without a seek table.
struct MatroskaClusterWalkTests {

    /// Builds a cluster of known length: identifier, length, optionally a
    /// CRC-32 in front (like ffmpeg), the timestamp, then filler bytes.
    static func cluster(
        time: UInt32, payload: Int, crc: Bool = false, keyframe: Bool? = nil
    ) -> Data {
        var body = Data()
        if crc { body += Data([0xBF, 0x84, 0x11, 0x22, 0x33, 0x44]) }
        body += Data([0xE7, 0x84]) + withUnsafeBytes(of: time.bigEndian) { Data($0) }
        if let keyframe {
            // An audio block (track 2) first, then the picture block (track 1) with a flag.
            body += Data([0xA3, 0x85, 0x82, 0x00, 0x00, 0x00, 0x00])
            body += Data([0xA3, 0x85, 0x81, 0x00, 0x00, keyframe ? 0x80 : 0x00, 0x00])
        }
        body += Data(repeating: 0xEC, count: 0)
        body += Data([0xEC]) + vintSize(payload) + Data(repeating: 0x00, count: payload)
        var out = Data([0x1F, 0x43, 0xB6, 0x75])
        // Length as a 4-byte VINT: 0x10 | bits
        let size = UInt32(body.count)
        out += Data([
            0x10 | UInt8((size >> 24) & 0x0F), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
        ])
        out += body
        return out
    }

    static func vintSize(_ size: Int) -> Data {
        let value = UInt32(size)
        return Data([
            0x10 | UInt8((value >> 24) & 0x0F), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }

    static func file(
        clusters: [(time: UInt32, payload: Int, crc: Bool)], junk: Int = 300
    ) -> (Data, first: Int) {
        // A segment of unknown length, with a little "header" in front.
        var data = Data([0x1A, 0x45, 0xDF, 0xA3, 0x80])
        data += Data([0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        data += Data([0xEC, 0x40, 0x00]) + Data(repeating: 0, count: 0)
        let first = data.count
        for entry in clusters {
            data += cluster(time: entry.time, payload: entry.payload, crc: entry.crc)
        }
        return (data, first)
    }

    @Test("A cluster header is read, even behind a CRC-32")
    func readsHead() {
        let plain = Self.cluster(time: 5000, payload: 100)
        let head = try! #require(MatroskaClusterWalk.head(in: plain, at: 0, base: 1000))
        #expect(head.position == 1000)
        #expect(head.time == 5000)
        #expect(head.end == 1000 + plain.count)
        #expect(head.startsWithKeyframe == nil)

        // With blocks: the picture block (track 1) behind an audio block says it.
        let keyed = Self.cluster(time: 1, payload: 10, keyframe: true)
        #expect(
            MatroskaClusterWalk.head(in: keyed, at: 0, base: 0, videoTrack: 1)?.startsWithKeyframe
                == true)
        let plainVideo = Self.cluster(time: 1, payload: 10, keyframe: false)
        #expect(
            MatroskaClusterWalk.head(in: plainVideo, at: 0, base: 0, videoTrack: 1)?.startsWithKeyframe
                == false)
        #expect(
            MatroskaClusterWalk.head(in: plainVideo, at: 0, base: 0, videoTrack: 3)?.startsWithKeyframe
                == nil)

        let withCRC = Self.cluster(time: 7000, payload: 50, crc: true)
        #expect(MatroskaClusterWalk.head(in: withCRC, at: 0, base: 0)?.time == 7000)

        // Unknown length: no header.
        var open = Data([0x1F, 0x43, 0xB6, 0x75, 0xFF, 0xE7, 0x81, 0x01])
        open += Data(repeating: 0, count: 8)
        #expect(MatroskaClusterWalk.head(in: open, at: 0, base: 0) == nil)
    }

    @Test("The scan finds the header behind garbage that contains the ID")
    func scansPastFalseMarkers() {
        var data = Data(repeating: 0x00, count: 40)
        data += Data([0x1F, 0x43, 0xB6, 0x75, 0x00, 0x00])  // Kennung ohne echten Kopf
        data += Data(repeating: 0x11, count: 20)
        let real = Self.cluster(time: 42, payload: 10)
        let start = data.count
        data += real
        let found = MatroskaClusterWalk.scan(data, base: 100)
        #expect(found?.position == 100 + start)
        #expect(found?.time == 42)
    }

    @Test("The walk delivers every cluster, in several sections and without duplicates")
    func walksTheFile() async throws {
        var clusters: [(time: UInt32, payload: Int, crc: Bool)] = []
        for number in 0..<25 {
            clusters.append(
                (time: UInt32(number * 5000), payload: 700 + (number % 5) * 90, crc: number % 3 == 0))
        }
        let (data, first) = Self.file(clusters: clusters)
        let entries = try await MatroskaClusterWalk.index(
            source: DataByteRangeSource(data), firstCluster: first, fileSize: data.count,
            workers: 4, window: 900)
        #expect(entries.count == 25)
        #expect(MatroskaClusterWalk.entries(from: entries).keyframesKnown == false)
        let times: [Int64] = entries.map { $0.time }
        let expected: [Int64] = clusters.map { Int64($0.time) }
        #expect(times == expected)
        #expect(entries.first?.position == first)
        #expect(entries == entries.sorted { $0.position < $1.position })
    }

    @Test("Only clusters with a keyframe become piece starts — if there are any")
    func keyframeClustersBecomeEntries() {
        func head(_ position: Int, _ key: Bool?) -> MatroskaClusterWalk.ClusterHead {
            .init(position: position, end: position + 100, time: Int64(position), startsWithKeyframe: key)
        }
        let mixed = [head(0, true), head(100, false), head(200, false), head(300, true), head(400, nil)]
        let chosen = MatroskaClusterWalk.entries(from: mixed)
        #expect(chosen.keyframesKnown)
        #expect(chosen.entries.map(\.position) == [0, 300])

        let unknown = [head(0, nil), head(100, nil)]
        let all = MatroskaClusterWalk.entries(from: unknown)
        #expect(!all.keyframesKnown)
        #expect(all.entries.count == 2)
    }

    @Test("The cache returns what it was given")
    func cacheRoundTrip() {
        let key = MatroskaIndexCache.key(for: URL(string: "http://x/Videos/1/stream?api=1")!, size: 123)
        #expect(key == MatroskaIndexCache.key(for: URL(string: "http://x/Videos/1/stream?api=2")!, size: 123))
        #expect(key != MatroskaIndexCache.key(for: URL(string: "http://x/Videos/1/stream")!, size: 124))
        defer { MatroskaIndexCache.forget(key: key) }
        let entries = [
            MatroskaIndex.Entry(time: 0, position: 800), .init(time: 5000, position: 9_000_000_000),
        ]
        MatroskaIndexCache.save(entries, keyframesKnown: true, key: key)
        #expect(MatroskaIndexCache.load(key: key)?.entries == entries)
        MatroskaIndexCache.forget(key: key)
        #expect(MatroskaIndexCache.load(key: key) == nil)
    }
}
