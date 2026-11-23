import Foundation
import Testing

@testable import Core

/// How many range requests the walk through the clusters makes **at the same time**.
///
/// **The occasion is a read storm on a hard disk** (on-device test build 1332, report
/// `F-021`, 2026-09-27): When starting a file without cues, 31 requests of 2 MiB
/// each ran simultaneously against the CineLounge server, evenly distributed across the
/// file, each taking 4 to 12.5 seconds. The pattern is exactly the walk with 32
/// sections: Every section except the first looks for its first cluster with a 2 MiB
/// window at its boundary.
@Suite("Cluster pass: parallelism")
struct ClusterPassParallelismTests {

    /// A file consisting only of cluster heads that **never lives in memory**: Every request
    /// is generated from the position. That way a file of 256 MiB stays cheap in a check —
    /// only from 64 MiB on would the old walk get 32 sections at all.
    final class GeneratedFile: ByteRangeSource, @unchecked Sendable {
        let size: Int
        let spacing: Int
        private let lock = NSLock()
        private var running = 0
        private var _maximum = 0

        init(size: Int, spacing: Int) {
            self.size = size
            self.spacing = spacing
        }

        /// The most requests that were ever in flight at the same time.
        var atMost: Int { lock.withLock { _maximum } }

        func length() async throws -> Int { size }

        /// A cluster of known length `spacing`, timestamp = number.
        private func header(number: Int) -> Data {
            var header = Data([0x1F, 0x43, 0xB6, 0x75])
            let content = UInt32(spacing - 8)
            header += Data([
                0x10 | UInt8((content >> 24) & 0x0F), UInt8((content >> 16) & 0xFF),
                UInt8((content >> 8) & 0xFF), UInt8(content & 0xFF),
            ])
            header += Data([0xE7, 0x84]) + withUnsafeBytes(of: UInt32(number).bigEndian) { Data($0) }
            return header
        }

        func bytes(in range: Range<Int>) async throws -> Data {
            lock.withLock {
                running += 1
                _maximum = max(_maximum, running)
            }
            defer { lock.withLock { running -= 1 } }
            // A little waiting time so that simultaneous requests overlap at all.
            try await Task.sleep(for: .milliseconds(3))
            let top = min(range.upperBound, size)
            var buffer = Data(count: max(0, top - range.lowerBound))
            var number = range.lowerBound / spacing
            while number * spacing < top {
                let location = number * spacing
                for (i, byte) in header(number: number).enumerated() {
                    let target = location + i - range.lowerBound
                    if target >= 0, target < buffer.count { buffer[target] = byte }
                }
                number += 1
            }
            return buffer
        }
    }

    /// **A hard disk does not tolerate 32 read heads.** The same lesson as with reading
    /// ahead of the pieces (2026-09-05, "one worker"): Parallel requests at widely separated
    /// places make the head jump, and every single one gets slower instead of all finishing
    /// faster together.
    @Test("The pass makes at most four fetches at once, even for a large file")
    func atMostFour() async throws {
        let file = GeneratedFile(size: 256 << 20, spacing: 1 << 20)
        let headers = try await MatroskaClusterWalk.index(
            source: file, firstCluster: 0, fileSize: file.size)
        #expect(headers.count == 256)
        #expect(file.atMost <= 4, "\(file.atMost) fetches at once")
    }

    /// The session through which the repackager reads carries as many connections as the
    /// walk has sections — and the walk no more than the small fixed number.
    @Test("The read session and the pass share the same small limit")
    func sessionMatches() {
        #expect(
            HTTPByteRangeSource.parallelSession.configuration.httpMaximumConnectionsPerHost
                == MatroskaClusterWalk.defaultWorkers)
        #expect(MatroskaClusterWalk.defaultWorkers <= 4)
    }
}
