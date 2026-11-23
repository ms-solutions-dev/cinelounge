import Core
import Foundation
import Testing

@testable import Downloads

/// The loop that fetches segments — **and the places where it has to stop.**
///
/// It is checked without a line, for the same reason as with ``BackgroundSessionTests``: what
/// is difficult about a download are the decisions — from which segment, which
/// tier, when to reject. A real connection would make that slower and
/// less reliable without proving a single one of these questions.
@Suite("Stream session")
struct StreamSessionTests {

    // MARK: - Doubles

    /// A host that outputs a playlist and segments along with it and records what it was
    /// asked.
    private final class StubStream: StreamSource, @unchecked Sendable {
        /// What is answered at which address — playlists as text, segments as zeros.
        var listen: [String: String]
        var kind: DeliveryKind
        /// How many bytes a segment is large.
        let segmentSize: Int
        private(set) var fetched: [URL] = []
        private(set) var samples = 0
        /// How many more times the next segment request should fail.
        var failuresRemaining = 0
        /// Runs once at the first segment — a second writer in the same file.
        var inBetween: (() -> Void)?

        init(listen: [String: String], kind: DeliveryKind = .hls, segmentSize: Int = 1000) {
            self.listen = listen
            self.kind = kind
            self.segmentSize = segmentSize
        }

        func probe(_ target: TargetAddress) async throws -> Probe {
            samples += 1
            switch kind {
            case .hls:
                return Probe(
                    status: 206, contentType: "application/vnd.apple.mpegurl",
                    acceptsRanges: "bytes", start: Data("#EXTM3U\n".utf8))
            case .wholeFile:
                return Probe(status: 200, contentType: "video/mp4", acceptsRanges: "none")
            default:
                return Probe(
                    status: 206, contentType: "video/mp4", acceptsRanges: "bytes",
                    contentRange: "bytes 0-511/1000")
            }
        }

        func fetch(
            _ address: URL, area: ClosedRange<Int64>?, headers: [String: String]
        ) async throws -> Data {
            if let text = listen[address.absoluteString] {
                fetched.append(address)
                return Data(text.utf8)
            }
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw LoadError.network("Probe")
            }
            fetched.append(address)
            inBetween?()
            inBetween = nil
            return Data(repeating: 0, count: segmentSize)
        }

        func fetchToFile(_ target: TargetAddress, after location: URL) async throws -> Int64 {
            let data = Data(repeating: 7, count: 4321)
            try data.write(to: location)
            fetched.append(target.address)
            return Int64(data.count)
        }
    }

    private struct StubAddresses: AddressProvider {
        let address: URL
        func address() async throws -> TargetAddress { TargetAddress(address) }
    }

    /// A playlist with `count` segments, absolutely addressed.
    private static func list(_ count: Int, end: Bool = true) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for i in 1...count { text += "#EXTINF:4.000,\nhttps://cdn.example/seg-\(i).ts\n" }
        if end { text += "#EXT-X-ENDLIST\n" }
        return text
    }

    private static func folder() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func size(_ url: URL) -> Int64 {
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (values?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static let playlistAddress = "https://host.example/index.m3u8"

    /// **Made of two pieces** — `scripts/strings.py` takes `word.word` for a
    /// catalog key, and a key format looks exactly like that. The same caution as
    /// at ``DownloadLedger/stem``.
    private static let fairplay = "com.apple." + "streamingkeydelivery"

    private static func job() -> PortalJob {
        PortalJob(
            portal: "flatone", key: "clipsite/kanal", host: "", version: "")
    }

    /// **If someone else has written into the partial file, the playlist does not keep writing**
    /// (check of the shell, H5) — the same question as with the blocks, ``PartialWriter/append(_:from:)``.
    @Test("A foreign writer in the partial file stops the segment loop")
    func foreignWriter() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("fremd"))
        let stream = StubStream(listen: [Self.playlistAddress: Self.list(3)])
        stream.inBetween = { _ = try? writer.append(Data([9]), from: writer.reached()) }

        await #expect(throws: LoadError.self) {
            try await Self.session(stream, writer: writer).load()
        }
        #expect(!writer.isFinished)
    }

    private static func session(
        _ stream: StubStream, writer: PartialWriter
    ) -> StreamSession {
        StreamSession(
            job: job(), source: stream,
            addresses: StubAddresses(address: URL(string: playlistAddress)!),
            writer: writer)
    }

    // MARK: - The ordinary case

    /// **One playlist becomes ONE file.** That is the done condition of this order.
    @Test("A tier playlist becomes a single file")
    func loadsCompletely() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))
        let stream = StubStream(listen: [Self.playlistAddress: Self.list(5)])

        let done = try await Self.session(stream, writer: writer).load()

        #expect(Self.size(done) == 5000)
        #expect(!FileManager.default.fileExists(atPath: writer.part.path))
        // First the playlist, then five segments.
        #expect(stream.fetched.count == 6)
    }

    /// **The master playlist costs a second fetch, and the tier decides the
    /// upper bound.**
    @Test("A master playlist is resolved and the tier chosen")
    func mainPlaylistAndVariant() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))

        let main = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=891872,RESOLUTION=480x270
            klein.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=6029536,RESOLUTION=1920x1080
            gross.m3u8
            """
        let stream = StubStream(listen: [
            Self.playlistAddress: main,
            "https://host.example/klein.m3u8": Self.list(2),
            "https://host.example/gross.m3u8": Self.list(4),
        ])

        _ = try await Self.session(stream, writer: writer).load(atMost: .minimal)
        #expect(stream.fetched.contains(URL(string: "https://host.example/klein.m3u8")!))
        #expect(!stream.fetched.contains(URL(string: "https://host.example/gross.m3u8")!))
    }

    /// **The initialization comes before the first segment and exactly once.**
    ///
    /// Without it fMP4 segments are bytes without meaning; written a second time it
    /// would be a foreign body in the middle of the film.
    @Test("EXT-X-MAP is written as the first piece")
    func initializationFirst() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))

        var text = "#EXTM3U\n#EXT-X-MAP:URI=\"https://cdn.example/init.mp4\"\n"
        text += "#EXTINF:4.000,\nhttps://cdn.example/seg-1.m4s\n#EXT-X-ENDLIST\n"
        let stream = StubStream(listen: [Self.playlistAddress: text])

        let done = try await Self.session(stream, writer: writer).load()
        // Initialization plus one segment.
        #expect(Self.size(done) == 2000)
        #expect(stream.fetched[1].absoluteString == "https://cdn.example/init.mp4")
    }

    // MARK: - Resuming

    /// **Resuming happens from segment 143.**
    ///
    /// That is the case the whole build is about: an abort at minute forty must not
    /// cost the whole film. The partial state is the file; the slip translates its
    /// size into a segment number.
    @Test("A run resumes from segment 143")
    func resumeFrom143() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))
        let text = Self.list(200)

        // 143 segments are already there — file and slip agree.
        try writer.append(Data(repeating: 0, count: 143 * 1000))
        let state = StreamProgress(beside: writer.part)
        guard case .tier(let list) = try StreamPlaylist.read(text, from: URL(string: "https://x/")!)
        else { Issue.record("no tier playlist"); return }
        state.memorize(
            segments: 143, bytes: 143_000, trait: StreamSession.trait(list))

        let stream = StubStream(listen: [Self.playlistAddress: text])
        let done = try await Self.session(stream, writer: writer).load()

        #expect(Self.size(done) == 200_000)
        // One playlist and fifty-seven segments — not two hundred.
        #expect(stream.fetched.count == 58)
        #expect(stream.fetched[1].absoluteString == "https://cdn.example/seg-144.ts")
    }

    /// **A slip that does not match the file loses.**
    ///
    /// The case is the crash in the middle of appending: afterwards half a segment lies there.
    /// Writing on would yield a file that looks complete and falls apart at one spot
    /// — exactly the error that
    /// ``PortalJob/mayResume(length:tag:changed:)`` also guards against.
    @Test("A note that does not match the file size is discarded")
    func slipDoesNotFit() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))
        let text = Self.list(10)

        // Half a segment more than the slip claims.
        try writer.append(Data(repeating: 0, count: 3500))
        guard case .tier(let list) = try StreamPlaylist.read(text, from: URL(string: "https://x/")!)
        else { Issue.record("no tier playlist"); return }
        StreamProgress(beside: writer.part).memorize(
            segments: 3, bytes: 3000, trait: StreamSession.trait(list))

        let stream = StubStream(listen: [Self.playlistAddress: text])
        let done = try await Self.session(stream, writer: writer).load()

        // From scratch: ten segments and no half one before them.
        #expect(Self.size(done) == 10000)
    }

    /// **A different playlist means: a different partial state.** A host change cuts differently,
    /// and "segment 143" means something else there.
    @Test("A note from another playlist does not count")
    func slipFromOtherPlaylist() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))

        try writer.append(Data(repeating: 0, count: 3000))
        StreamProgress(beside: writer.part).memorize(segments: 3, bytes: 3000, trait: "99@400")

        let stream = StubStream(listen: [Self.playlistAddress: Self.list(10)])
        let done = try await Self.session(stream, writer: writer).load()
        #expect(Self.size(done) == 10000)
    }

    // MARK: - Stopping and rejecting

    /// **`mayContinue` is asked BEFORE every segment** — exactly as before every block.
    @Test("A no before the segment stops the loop")
    func stops() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))
        let stream = StubStream(listen: [Self.playlistAddress: Self.list(20)])
        let session = Self.session(stream, writer: writer)

        let counter = TallyCounter()
        await #expect(throws: LoadError.wasCancelled) {
            try await session.load(mayContinue: { await counter.threeMore() })
        }
        // Three segments are through, the partial file is there — and is not the finished one.
        #expect(Self.size(writer.part) == 3000)
        #expect(!writer.isFinished)
    }

    /// **Live is no download.** A playlist without `#EXT-X-ENDLIST` keeps growing.
    @Test("A playlist without ENDLIST is rejected with a reason")
    func liveDeclined() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))
        let stream = StubStream(listen: [Self.playlistAddress: Self.list(3, end: false)])

        await #expect(throws: LoadError.notLoadable(.liveWithoutEnd)) {
            try await Self.session(stream, writer: writer).load()
        }
    }

    /// **Rights management is not downloaded, and that is the right answer** — not
    /// "connection lost".
    @Test("A playlist with FairPlay is rejected as rights management")
    func drmDeclined() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))
        let text = Self.list(3).replacingOccurrences(
            of: "#EXT-X-PLAYLIST-TYPE:VOD",
            with: #"#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="\#(Self.fairplay)""#)
        let stream = StubStream(listen: [Self.playlistAddress: text])

        await #expect(throws: LoadError.notLoadable(.rightsManagement)) {
            try await Self.session(stream, writer: writer).load()
        }
    }

    /// **AES-128 rejects differently than FairPlay**, because with one a decryptor is missing and
    /// with the other the right — two different next steps.
    @Test("A playlist with AES-128 rejects with its method")
    func aesDeclined() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))
        let text = Self.list(3).replacingOccurrences(
            of: "#EXT-X-PLAYLIST-TYPE:VOD",
            with: #"#EXT-X-KEY:METHOD=AES-128,URI="schluessel""#)
        let stream = StubStream(listen: [Self.playlistAddress: text])

        await #expect(throws: LoadError.notLoadable(.encrypted("AES-128"))) {
            try await Self.session(stream, writer: writer).load()
        }
    }

    /// **The segment is retried and not the download job.**
    @Test("Two dropouts cost a segment and no progress")
    func retriesSegment() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))
        let stream = StubStream(listen: [Self.playlistAddress: Self.list(2)])
        stream.failuresRemaining = 2

        let done = try await Self.session(stream, writer: writer).load()
        #expect(Self.size(done) == 2000)
    }

    // MARK: - The switch

    /// **A file without a playlist still goes the old way.**
    ///
    /// That is the condition under which this whole build was allowed to be introduced: the
    /// Serieshub title that downloads today must download just the same afterwards.
    @Test("A file with ranges still takes the block loop")
    func fileKeepsOldRoute() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))

        let blocks = BlockCounter(length: 3000)
        let stream = StubStream(listen: [:], kind: .fileInPieces)
        let session = BackgroundSession(
            job: Self.job(), fetcher: blocks,
            addresses: StubAddresses(address: URL(string: Self.playlistAddress)!),
            writer: writer, stream: stream)

        let done = try await session.load(mbit: nil)
        #expect(Self.size(done) == 3000)
        // The range fetcher was used, the stream source only for the probe.
        #expect(await blocks.fetches > 0)
        #expect(stream.samples == 1)
        #expect(stream.fetched.isEmpty)
    }

    /// **And a playlist takes the new path without the call site knowing anything about it.**
    @Test("An HLS playlist is sent by the switch into the segment loop")
    func playlistTakesTheNewRoute() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))

        let blocks = BlockCounter(length: 3000)
        let stream = StubStream(listen: [Self.playlistAddress: Self.list(4)])
        let session = BackgroundSession(
            job: Self.job(), fetcher: blocks,
            addresses: StubAddresses(address: URL(string: Self.playlistAddress)!),
            writer: writer, stream: stream)

        let done = try await session.load(mbit: nil)
        #expect(Self.size(done) == 4000)
        #expect(await blocks.fetches == 0)
    }

    /// **A file without ranges is downloaded and not rejected.**
    ///
    /// Until 2026-09-09 this case ended as "choose a different version", although
    /// **this** version is downloadable — just in one go.
    @Test("A file without ranges is loaded in one piece")
    func loadedWhole() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))

        let stream = StubStream(listen: [:], kind: .wholeFile)
        let session = BackgroundSession(
            job: Self.job(), fetcher: BlockCounter(length: 10),
            addresses: StubAddresses(address: URL(string: Self.playlistAddress)!),
            writer: writer, stream: stream)

        let done = try await session.load(mbit: nil)
        #expect(Self.size(done) == 4321)
    }

    /// **Without a stream source nothing changes at all** — the path that the other checks
    /// of this package take stays the same and is not tried.
    @Test("Without a stream source nothing is tried")
    func withoutStreamSource() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("a"))

        let blocks = BlockCounter(length: 2000)
        let session = BackgroundSession(
            job: Self.job(), fetcher: blocks,
            addresses: StubAddresses(address: URL(string: Self.playlistAddress)!),
            writer: writer)

        let done = try await session.load(mbit: nil)
        #expect(Self.size(done) == 2000)
    }

    // MARK: - The extrapolation

    /// **The total size is an extrapolation and gets more precise with every segment.**
    ///
    /// An invented number would be worse than none — but a zero would be, on screen, a
    /// bar claiming that nothing has happened yet (see ``Transfer/portion``).
    @Test("The total size is extrapolated from the laid segments")
    func extrapolation() {
        #expect(StreamSession.extrapolated(bytes: 143_000, done: 143, total: 620) == 620_000)
        #expect(StreamSession.extrapolated(bytes: 0, done: 0, total: 620) == nil)
    }
}

// MARK: - Small helpers

/// Says yes three times and no afterwards.
private actor TallyCounter {
    private var pending = 3
    func threeMore() -> Bool {
        guard pending > 0 else { return false }
        pending -= 1
        return true
    }
}

/// A range fetcher that counts — for the question of which path was taken.
private actor BlockCounter: BlockFetcher {
    let length: Int64
    private(set) var fetches = 0

    init(length: Int64) { self.length = length }

    func fetch(_ area: ClosedRange<Int64>, from target: TargetAddress) async throws -> BlockResponse {
        fetches += 1
        let end = min(area.upperBound, length - 1)
        let count = max(0, Int(end - area.lowerBound + 1))
        return BlockResponse(
            status: 206, data: Data(repeating: 0, count: count), totalLength: length,
            tag: "abc", acceptsRanges: "bytes")
    }
}
