import CryptoKit
import Foundation
import Testing

@testable import Downloads

/// **A block appears exactly once in the file, and a broken file is never finished** —
/// check of the shell, H5, 2026-09-27.
///
/// Two paths write into the same partial file: the running ``BackgroundSession`` and the
/// straggler that the system delivers after a restart (`Bridge.writeTo`).
/// Only the straggler checked the state. If it arrived while the new session was fetching the same block,
/// the block appeared twice in the file, everything behind it was shifted — and the
/// file counted as finished anyway.
@Suite("Stragglers, size and checksum")
struct StragglerTests {

    /// Delivers every range of a sample file — and on request plays the straggler once,
    /// corrupts a byte, appends one too many or names a checksum.
    private final class StubFetcherSimple: BlockFetcher, @unchecked Sendable {
        let length: Int64
        let writer: PartialWriter
        var straggler = false
        var tampered = false
        var oneTooMany = false
        var checksum: Data?

        init(length: Int64, writer: PartialWriter) {
            self.length = length
            self.writer = writer
        }

        private static let patterns = Data((0..<251).map { UInt8($0) })

        /// Byte `i` of the sample file is `i % 251` — a shift by one block is noticed.
        static func bytes(_ area: ClosedRange<Int64>) -> Data {
            var data = Data(capacity: area.count)
            var location = Int(area.lowerBound % 251)
            var rest = area.count
            while rest > 0 {
                let piece = min(rest, 251 - location)
                data.append(patterns[location..<(location + piece)])
                rest -= piece
                location = 0
            }
            return data
        }

        func fetch(
            _ area: ClosedRange<Int64>, from target: TargetAddress
        ) async throws
            -> BlockResponse
        {
            let end = min(area.upperBound, length - 1)
            var data = Self.bytes(area.lowerBound...end)
            if straggler, try writer.append(data, from: area.lowerBound) {
                straggler = false
            }
            if tampered, area.lowerBound == 0 { data[0] ^= 0xFF }
            if oneTooMany, end == length - 1 { data.append(0) }
            return BlockResponse(
                status: 206, data: data, totalLength: length, tag: "abc",
                acceptsRanges: "bytes", checksum: checksum)
        }
    }

    private struct Setup {
        let folder: URL
        let writer: PartialWriter
        let fetcher: StubFetcherSimple
        let session: BackgroundSession

        init(length: Int64) throws {
            folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            writer = PartialWriter(folder: folder, identifier: .init("x"))
            fetcher = StubFetcherSimple(length: length, writer: writer)
            session = BackgroundSession(
                job: PortalJob(
                    portal: "animehub", key: "elvaran/s1/f12", host: "hosta",
                    version: "(DE)"),
                fetcher: fetcher,
                addresses: FixedAddress(URL(string: "https://host.example/1.mp4")!),
                writer: writer)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    }

    @Test("H5: A straggler block during the fetch does not appear twice in the file")
    func noDuplicateBlock() async throws {
        let length: Int64 = 20 * 1024 * 1024
        let setup = try Setup(length: length)
        defer { setup.cleanUp() }
        setup.fetcher.straggler = true

        let file = try await setup.session.load(mbit: nil)
        let content = try Data(contentsOf: file)
        #expect(setup.fetcher.straggler == false, "the straggler did not arrive at all")
        #expect(Int64(content.count) == length)
        #expect(content == StubFetcherSimple.bytes(0...(length - 1)), "block doubled, rest shifted")
    }

    @Test("The bolt appends only where the file stands")
    func lock() throws {
        let setup = try Setup(length: 10)
        defer { setup.cleanUp() }
        #expect(try setup.writer.append(Data([1, 2]), from: 0))
        #expect(try !setup.writer.append(Data([1, 2]), from: 0))
        #expect(try setup.writer.append(Data([3]), from: 2))
        #expect(setup.writer.reached() == 3)
    }

    @Test("A file with the wrong size is discarded and not reported finished")
    func wrongSize() async throws {
        let setup = try Setup(length: 1024 * 1024)
        defer { setup.cleanUp() }
        setup.fetcher.oneTooMany = true

        await #expect(throws: LoadError.corrupted) {
            try await setup.session.load(mbit: nil)
        }
        #expect(!setup.writer.isFinished)
        #expect(setup.writer.reached() == 0)
        #expect(await setup.session.job.reached == 0)
    }

    @Test("If the server's checksum does not match, the file is not finished")
    func wrongChecksum() async throws {
        let length: Int64 = 1024 * 1024
        let setup = try Setup(length: length)
        defer { setup.cleanUp() }
        setup.fetcher.checksum = Data(SHA256.hash(data: StubFetcherSimple.bytes(0...(length - 1))))
        setup.fetcher.tampered = true

        await #expect(throws: LoadError.corrupted) {
            try await setup.session.load(mbit: nil)
        }
        #expect(!setup.writer.isFinished)
    }

    @Test("If the checksum matches, the file is finished")
    func correctChecksum() async throws {
        let length: Int64 = 1024 * 1024
        let setup = try Setup(length: length)
        defer { setup.cleanUp() }
        setup.fetcher.checksum = Data(SHA256.hash(data: StubFetcherSimple.bytes(0...(length - 1))))

        let file = try await setup.session.load(mbit: nil)
        #expect(try Data(contentsOf: file).count == Int(length))
    }

    @Test("Repr-Digest and Digest deliver the SHA-256 sum, other methods do not")
    func headers() {
        let sum = Data(SHA256.hash(data: Data("cinelounge".utf8)))
        let text = sum.base64EncodedString()
        #expect(
            BlockResponse.checksum(reprDigest: "sha-512=:AAAA:, sha-256=:\(text):", digest: nil) == sum)
        #expect(BlockResponse.checksum(reprDigest: nil, digest: "MD5=abc, SHA-256=\(text)") == sum)
        #expect(BlockResponse.checksum(reprDigest: "sha-256=\(text)", digest: nil) == nil)
        #expect(BlockResponse.checksum(reprDigest: nil, digest: "MD5=\(text)") == nil)
        #expect(BlockResponse.checksum(reprDigest: nil, digest: nil) == nil)
    }
}
