import CoreMedia
import Foundation
import Network
import Testing

@testable import Core

/// **The repackager check of 2026-09-27 as permanent guards.**
///
/// Every test here was a finding (B1–B10) or a hypothesis of the check and stood red
/// against the state of the time. The guideline behind it: **data from the network is never
/// trustworthy.** A file, a stream or an answer may make a spot unreadable,
/// but never halt the app. The crashes therefore stand here as exit tests — a
/// regression would otherwise halt the whole check run instead of just one test.
enum RemuxerChecks {
    typealias T = TestMatroskaFile

    /// An MKV file whose seek table sits BEFORE the clusters (ffmpeg
    /// `-cues_to_front 1` / `-reserve_index_space`).
    static func cuesAtFrontFile() -> Data {
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
            T.element(
                Matroska.ID.cluster,
                T.element(Matroska.ID.clusterTimestamp, T.unsigned(time))
                    + T.element(Matroska.ID.simpleBlock, Data([0x81, 0, 0, 0x80, 0, 0, 0, 1, 0x65])))
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
        let cuesAt = seekHead(0).count + info.count + tracks.count
        let c1At = cuesAt + cues(0, 0).count
        let c2At = c1At + c1.count
        let body = seekHead(cuesAt) + info + tracks + cues(c1At, c2At) + c1 + c2
        return ebml + T.element(Matroska.ID.segment, body)
    }

    /// A transport stream packet with payload.
    static func packet(pid: UInt16, pusi: Bool, cc: UInt8, payload: [UInt8]) -> Data {
        var p: [UInt8] = [
            0x47, (pusi ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | (cc & 0x0F),
        ]
        p += payload.prefix(184)
        while p.count < 188 { p.append(0xFF) }
        return Data(p)
    }
}

/// Counts range requests and delays them on demand.
final class ByteCountingSource: ByteRangeSource, @unchecked Sendable {
    let data: Data
    let delay: Double
    private let lock = NSLock()
    private var _requests: [Date] = []
    init(_ data: Data, delay: Double = 0) {
        self.data = data
        self.delay = delay
    }
    var fetches: [Date] { lock.withLock { _requests } }
    func length() async throws -> Int { data.count }
    func bytes(in range: Range<Int>) async throws -> Data {
        lock.withLock { _requests.append(Date()) }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return try await DataByteRangeSource(data).bytes(in: range)
    }
}

/// Records every requested range — for R5: learns which range the build
/// of a particular chunk requests, without rebuilding the internal calculation of
/// ``MatroskaFileSession``.
final class RangeRecordingSource: ByteRangeSource, @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var _ranges: [Range<Int>] = []
    init(_ data: Data) { self.data = data }
    var sections: [Range<Int>] { lock.withLock { _ranges } }
    func length() async throws -> Int { data.count }
    func bytes(in range: Range<Int>) async throws -> Data {
        lock.withLock { _ranges.append(range) }
        return try await DataByteRangeSource(data).bytes(in: range)
    }
}

/// Delays only requests whose end reaches beyond a threshold, and counts them —
/// for R5: everything up to a learned chunk stays fast, everything after it slow.
final class SelectivelySlowSource: ByteRangeSource, @unchecked Sendable {
    let data: Data
    let threshold: Int
    let delay: Double
    private let lock = NSLock()
    private var _slowRequests = 0
    init(_ data: Data, threshold: Int, delay: Double) {
        self.data = data
        self.threshold = threshold
        self.delay = delay
    }
    var slowRequests: Int { lock.withLock { _slowRequests } }
    func length() async throws -> Int { data.count }
    func bytes(in range: Range<Int>) async throws -> Data {
        if range.upperBound > threshold {
            lock.withLock { _slowRequests += 1 }
            try await Task.sleep(for: .seconds(delay))
        }
        return try await DataByteRangeSource(data).bytes(in: range)
    }
}

/// A server that ignores the partial request and sends a short 200 response
/// (Xtream: substitute video / error page with status 200).
final class Ignored200: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "50000"])!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 50_000))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A panel that rejects every request with 403 and a small error page.
final class RejectionPanel: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rejection-panel")
    private let lock = NSLock()
    private var _connections = 0
    var connections: Int { lock.withLock { _connections } }
    private(set) var port: UInt16 = 0

    let mainContent: String
    init(mainContent: String = "<html><body><h1>403 Forbidden</h1></body></html>") throws {
        self.mainContent = mainContent
        let parameter = NWParameters.tcp
        parameter.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameter)
    }

    func start() async throws {
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port?.rawValue {
                ready.continuation.yield(port)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            lock.withLock { _connections += 1 }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let mainContent = self.mainContent
                let reply =
                    "HTTP/1.1 403 Forbidden\r\nContent-Type: text/html\r\nContent-Length: \(mainContent.utf8.count)\r\n"
                    + "Connection: close\r\n\r\n" + mainContent
                connection.send(
                    content: Data(reply.utf8),
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        for await port in ready.stream {
            self.port = port
            return
        }
    }

    func stop() { listener.cancel() }
}

@Suite("Remuxer checks")
struct RemuxerChecksTests {

    // MARK: B1 — Cues vor den Clustern

    @Test("B1: A file with its seek table before the clusters does not crash on start")
    func cuesAtFront() async {
        await #expect(processExitsWith: .success) {
            let session = try? MatroskaFileSession(
                source: DataByteRangeSource(RemuxerChecks.cuesAtFrontFile()))
            _ = try? await session?.start()
        }
    }

    @Test("B1b: A seek table with positions against the time order does not crash")
    func positionsBackward() async {
        await #expect(processExitsWith: .success) {
            let index = MatroskaIndex(entries: [
                .init(time: 0, position: 5000), .init(time: 10_000, position: 1000),
            ])
            _ = index.pieces(
                targetDuration: 2, timestampScale: 1_000_000, fileSize: 9000, totalDuration: nil)
        }
    }

    @Test("B1c: With cues before the clusters the last piece reaches to the end of the file")
    func cuesAtFrontDirectoryEnd() throws {
        let file = RemuxerChecks.cuesAtFrontFile()
        let state = try #require(MatroskaIndex.locateCues(inHead: file))
        let table = MatroskaIndex.parse(
            cues: file.subdata(in: state.cues..<file.count), segmentStart: state.segmentStart, track: 1)
        let last = try #require(table.entries.last)
        #expect(state.cues < last.position, "the check file has its cues up front")
        let end = MatroskaFileSession.directoryEnd(
            cues: state.cues, lastPosition: last.position, fileEnd: file.count)
        #expect(end == file.count)
        let pieces = table.pieces(
            targetDuration: 2, timestampScale: 1_000_000, fileSize: end, totalDuration: 10)
        #expect(pieces.count == 2)
        #expect(pieces.last?.range.upperBound == file.count)
    }

    @Test("B1c control: Cues behind the clusters remain the end of the last piece")
    func cuesAtBackDirectoryEnd() {
        #expect(
            MatroskaFileSession.directoryEnd(cues: 9000, lastPosition: 5000, fileEnd: 12_000) == 9000)
    }

    @Test("B1d: A seek table never produces an empty or reversed range")
    func piecesAlwaysForward() {
        let index = MatroskaIndex(entries: [
            .init(time: 0, position: 5000), .init(time: 2000, position: 1000),
            .init(time: 4000, position: 7000), .init(time: 6000, position: 7000),
            .init(time: 8000, position: 9000),
        ])
        for fileEnd in [0, 8000, 9000, 20_000] {
            let pieces = index.pieces(
                targetDuration: 2, timestampScale: 1_000_000, fileSize: fileEnd, totalDuration: nil)
            #expect(
                pieces.allSatisfy { $0.range.lowerBound < $0.range.upperBound }, "file end \(fileEnd)")
            #expect(pieces.map(\.index) == Array(pieces.indices))
        }
        let pieces = index.pieces(
            targetDuration: 2, timestampScale: 1_000_000, fileSize: 20_000, totalDuration: nil)
        #expect(pieces.map(\.range.lowerBound) == [5000, 7000, 9000])
    }

    // MARK: B2 — HTTP 200 instead of 206 with a short body

    @Test("B2: A partial request ignored by the server with a short 200 response does not crash")
    func ignored200() async {
        await #expect(processExitsWith: .success) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Ignored200.self]
            let source = HTTPByteRangeSource(
                url: URL(string: "http://provider.invalid/movie/1.mkv")!,
                session: URLSession(configuration: configuration), allowsHead: false)
            _ = try? await source.bytes(in: 1_000_000..<(1_000_000 + 16_384))
        }
    }

    @Test("B2b: A 200 without the requested position never delivers bytes from zero as bytes from there")
    func ignored200Excerpt() throws {
        let errorPage = Data(repeating: 0x41, count: 16_384)
        #expect(throws: ByteRangeFailure.self) {
            try HTTPByteRangeSource.slice(fromWholeFile: errorPage, area: 1_000_000..<1_016_384)
        }
        #expect(throws: ByteRangeFailure.self) {
            try HTTPByteRangeSource.slice(fromWholeFile: errorPage, area: 100..<16_484)
        }
        let file = Data((0..<200).map { UInt8($0) })
        #expect(
            try HTTPByteRangeSource.slice(fromWholeFile: file, area: 10..<20)
                == file.subdata(in: 10..<20))
        #expect(
            try HTTPByteRangeSource.slice(fromWholeFile: file, area: 0..<50) == file.prefix(50))
        // **2026-09-27, fix round B (follow-up to B2):** until then this said `== file` — the
        // decision of the time "from byte zero it stays at the prefix" was exactly the spot at
        // which an error page of a blocked Xtream account passed as a short but apparently
        // valid file start. See the rationale at ``HTTPByteRangeSource/slice(fromWholeFile:area:)``.
        #expect(throws: ByteRangeFailure.self) {
            try HTTPByteRangeSource.slice(fromWholeFile: file, area: 0..<500)
        }
    }

    @Test("R6-3: A short response from byte zero is a shortRead, not a silent error page")
    func ignored200FromZeroShort() throws {
        // An error page of a blocked Xtream account: a few hundred bytes of HTML instead of
        // the first kilobytes of a Matroska file — it is requested from byte zero anyway,
        // because the header request does not yet know the real file size.
        let errorPage = Data("<html><body>Account expired</body></html>".utf8)
        #expect(errorPage.count < 65_536)
        #expect(throws: ByteRangeFailure.self) {
            try HTTPByteRangeSource.slice(fromWholeFile: errorPage, area: 0..<65_536)
        }
    }

    // MARK: B3 — EBML lacing with one frame

    @Test("B3: EBML lacing with a frame count of 1 does not crash")
    func ebmlBundlingOneFrame() async {
        await #expect(processExitsWith: .success) {
            // Track 1, time 0, keyframe + EBML bundling, "0 further frames".
            _ = Matroska.parseBlock(Data([0x81, 0x00, 0x00, 0x86, 0x00, 0x81, 0xAA]))
        }
    }

    @Test("B3b: EBML lacing with one frame delivers exactly that frame")
    func ebmlBundlingOneFrameContent() throws {
        let single = try #require(Matroska.parseBlock(Data([0x81, 0x00, 0x00, 0x86, 0x00, 0xAA, 0xBB])))
        #expect(single.frames == [Data([0xAA, 0xBB])])
        let two = try #require(Matroska.parseBlock(Data([0x81, 0x00, 0x00, 0x86, 0x01, 0x81, 0xAA, 0xBB])))
        #expect(two.frames == [Data([0xAA]), Data([0xBB])])
    }

    // MARK: B4 — Numbers from the file

    @Test("B4: An eight-byte cluster time does not crash the reader")
    func clusterTimeEightByte() async {
        await #expect(processExitsWith: .success) {
            let file = TestMatroskaFile.element(
                Matroska.ID.cluster,
                TestMatroskaFile.element(
                    Matroska.ID.clusterTimestamp, Data(repeating: 0xFF, count: 8)))
            _ = MatroskaReader().read(file)
        }
    }

    @Test("B4b: Sample rate NaN in the track table does not crash")
    func sampleRateNaN() async {
        await #expect(processExitsWith: .success) {
            typealias T = TestMatroskaFile
            let entry =
                T.element(Matroska.ID.trackNumber, T.unsigned(2))
                + T.element(Matroska.ID.trackType, T.unsigned(2))
                + T.element(Matroska.ID.codecID, Data("A_AAC".utf8))
                + T.element(
                    Matroska.ID.audio, T.element(Matroska.ID.samplingFrequency, T.float(.nan)))
            _ = Matroska.track(inTrackEntry: entry)
        }
    }

    @Test("B4c: Impossible numbers in the seek table and directory are discarded, not converted")
    func seekTableImpossibleNumbers() async {
        await #expect(processExitsWith: .success) {
            typealias T = TestMatroskaFile
            let eight = Data(repeating: 0xFF, count: 8)
            let point = T.element(
                Matroska.ID.cuePoint,
                T.element(Matroska.ID.cueTime, eight)
                    + T.element(
                        Matroska.ID.cueTrackPositions,
                        T.element(Matroska.ID.cueTrack, eight)
                            + T.element(Matroska.ID.cueClusterPosition, eight)))
            let valid = T.element(
                Matroska.ID.cuePoint,
                T.element(Matroska.ID.cueTime, T.unsigned(0))
                    + T.element(
                        Matroska.ID.cueTrackPositions,
                        T.element(Matroska.ID.cueTrack, T.unsigned(1))
                            + T.element(Matroska.ID.cueClusterPosition, eight)))
            let table = MatroskaIndex.parse(
                cues: T.element(Matroska.ID.cues, point + valid), segmentStart: 40, track: 1)
            let seek = T.element(
                Matroska.ID.seek,
                T.element(Matroska.ID.seekID, T.identifier(Matroska.ID.cues))
                    + T.element(Matroska.ID.seekPosition, eight))
            let state = MatroskaIndex.cuesPosition(inSeekHead: seek)
            guard table.isEmpty, state == nil else { exit(1) }
        }
    }

    @Test("B4d: Timescale and length from the file only when they are computable")
    func infoImpossibleNumbers() {
        typealias T = TestMatroskaFile
        let info =
            T.element(Matroska.ID.timestampScale, Data(repeating: 0xFF, count: 8))
            + T.element(Matroska.ID.duration, T.float(.infinity))
        let (scale, duration) = Matroska.info(inInfoElement: info)
        #expect(scale == nil)
        #expect(duration == nil)
        let valid =
            T.element(Matroska.ID.timestampScale, T.unsigned(1_000_000))
            + T.element(Matroska.ID.duration, T.float(5000))
        #expect(Matroska.info(inInfoElement: valid) == (1_000_000, 5000))
    }

    @Test("B4e: A cluster time beyond nanoseconds makes the file unreadable — in an orderly way")
    func clusterTimeUnreadable() {
        typealias T = TestMatroskaFile
        let file = T.element(
            Matroska.ID.cluster,
            T.element(Matroska.ID.clusterTimestamp, T.unsigned(UInt64(Int64.max / 1000), width: 8)))
        let reader = MatroskaReader()
        _ = reader.read(file)
        #expect(reader.isBroken)
        let remuxer = MatroskaRemuxer(store: SegmentStore(retainsEverything: true, logsProduction: false))
        remuxer.feed(file)
        #expect(remuxer.refusal == .fileIsUnreadable)
    }

    @Test("B4f: Sample rate and channel count outside the audible range count as not given")
    func audioEntriesOutside() throws {
        typealias T = TestMatroskaFile
        func makeTrack(_ audio: Data) throws -> Matroska.Track {
            try #require(
                Matroska.track(
                    inTrackEntry: T.element(Matroska.ID.trackNumber, T.unsigned(2))
                        + T.element(Matroska.ID.trackType, T.unsigned(2))
                        + T.element(Matroska.ID.codecID, Data("A_AAC".utf8))
                        + T.element(Matroska.ID.audio, audio)))
        }
        let nonsense = try makeTrack(
            T.element(Matroska.ID.samplingFrequency, T.float(1e30))
                + T.element(Matroska.ID.channels, Data(repeating: 0xFF, count: 8)))
        #expect(nonsense.sampleRate == nil)
        #expect(nonsense.channels == nil)
        let valid = try makeTrack(
            T.element(Matroska.ID.samplingFrequency, T.float(48000))
                + T.element(Matroska.ID.channels, T.unsigned(6)))
        #expect(valid.sampleRate == 48000)
        #expect(valid.channels == 6)
    }

    @Test("B4g: The central helper survives every conversion without crashing")
    func networkNumber() {
        #expect(NetNumber.total(UInt64.max) == nil)
        #expect(NetNumber.int64(UInt64(Int64.max) + 1) == nil)
        #expect(NetNumber.roundedValue(.nan) == nil)
        #expect(NetNumber.roundedValue(-.infinity) == nil)
        #expect(NetNumber.roundedValue(1e300) == nil)
        #expect(NetNumber.roundedValue(47_999.6) == 48_000)
        #expect(NetNumber.clamped(.nan, in: 0...1000) == 0)
        #expect(NetNumber.clamped(1e12, in: 0...1000) == 1000)
        #expect(NetNumber.product(Int64.max, 2) == nil)
        #expect(NetNumber.saturatedProduct(Int64.max, 2) == .max)
        #expect(NetNumber.saturatedProduct(Int64.min, 2) == .min)
        #expect(NetNumber.saturatedSum(.max, 1) == .max)
        #expect(NetNumber.saturatedSum(.min, -1) == .min)
        #expect(NetNumber.sum(.max, 1) == nil)
        #expect(NetNumber.toNanoseconds(Int64.max / 1000, scale: 1_000_000) == nil)
        #expect(NetNumber.toNanoseconds(5, scale: 1_000_000) == 5_000_000)
        #expect(
            NetNumber.portion(Int.max, mal: 31, finished: 32) == Int.max / 32 * 31 + (Int.max % 32) * 31 / 32)
        #expect(NetNumber.portion(1000, mal: 3, finished: 4) == 750)
    }

    @Test("B4h: The walk through the clusters splits a huge claimed length without overflow")
    func passHugeLength() async {
        await #expect(processExitsWith: .success) {
            let source = DataByteRangeSource(Data())
            _ = try? await MatroskaClusterWalk.index(
                source: source, firstCluster: 0, fileSize: Int.max, workers: 32)
        }
    }

    // MARK: B5 — Time-shift ring with a gap

    @Test("B5: If an offload fails, every playlist address still shows its own piece")
    func ringGap() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ring = TimeShiftRing(root: root, capacity: 1 << 30)
        let store = SegmentStore(logsProduction: false)
        store.setHeader(Data([0]))
        store.enableTimeShift(ring)
        // Exactly ONE offload fails (as with a full disk): at the spot of
        // chunk 1 there is a folder, and atomic writing cannot replace it.
        let lock = ring.directory.appending(path: "segment1.m4s")
        try FileManager.default.createDirectory(
            at: lock.appending(path: "content"), withIntermediateDirectories: true)
        for i in 0..<21 { store.append(Data("s\(i)".utf8), duration: 2) }
        store.append(Data("s21".utf8), duration: 2)
        store.append(Data("s22".utf8), duration: 2)
        store.append(Data("s23".utf8), duration: 2)
        store.awaitOffload()

        let list = store.playlist(isLive: true, base: "http://x")
        let names = list.split(separator: "\n")
            .filter { $0.hasPrefix("http://x/segment") }
            .map { String($0.dropFirst("http://x/".count)) }
        var wrong: [String] = []
        for name in names {
            guard case .segment(let n)? = RemuxPlaylist.request(forName: name) else { continue }
            if store.segment(n) != Data("s\(n)".utf8) { wrong.append(name) }
        }
        // And the list must reach up to the most recent chunk.
        #expect(wrong.isEmpty, "playlist addresses without their piece: \(wrong)")
        #expect(names.last == "segment23.m4s", "last address: \(names.last ?? "-")")
    }

    @Test("B5b: After a write error the ring only starts again at a keyframe")
    func ringRestartAtKeyframe() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ring = TimeShiftRing(root: root, capacity: 1 << 30)
        try FileManager.default.createDirectory(
            at: ring.directory.appending(path: "segment1.m4s/content"), withIntermediateDirectories: true)
        ring.store(index: 0, data: Data([0]), duration: 1, independent: true, period: 0)
        ring.store(index: 1, data: Data([1]), duration: 1, independent: false, period: 0)
        #expect(ring.count == 0, "the ring is empty after the error")
        ring.store(index: 2, data: Data([2]), duration: 1, independent: false, period: 0)
        #expect(ring.count == 0, "it does not start in the middle of a group of pictures")
        ring.store(index: 3, data: Data([3]), duration: 1, independent: true, period: 0)
        ring.store(index: 4, data: Data([4]), duration: 1, independent: false, period: 0)
        #expect(ring.pieces.map(\.index) == [3, 4])
    }

    @Test("B5c: The upper limit displaces whole groups of pictures")
    func ringDisplacesGOPs() {
        let root = FileManager.default.temporaryDirectory.appending(path: "ring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ring = TimeShiftRing(root: root, capacity: 350)
        for i in 0..<5 {
            ring.store(
                index: i, data: Data(repeating: 0, count: 100), duration: 1, independent: i % 3 == 0,
                period: 0)
        }
        #expect(ring.pieces.first?.independent == true)
        #expect(ring.pieces.map(\.index) == [3, 4])
    }

    // MARK: B6 — Walk through the clusters at the end of the file

    @Test("B6: The walk through the clusters needs no thousands of requests at the end of the file")
    func passAtEndOfFile() async throws {
        typealias T = TestMatroskaFile
        let cluster = T.element(
            Matroska.ID.cluster,
            T.element(Matroska.ID.clusterTimestamp, T.unsigned(0))
                + T.element(Matroska.ID.simpleBlock, Data([0x81, 0, 0, 0x80, 0, 0, 0, 1, 0x65])))
        // Behind the last cluster: tags (17,000 bytes) — no cluster anymore.
        let tags = T.element(Matroska.ID.tags, Data(repeating: 0, count: 17_000))
        let source = ByteCountingSource(cluster + tags)
        let headers = try await MatroskaClusterWalk.index(
            source: source, firstCluster: 0, fileSize: (cluster + tags).count, workers: 1)
        #expect(headers.count == 1)
        #expect(
            source.fetches.count < 50,
            "\(source.fetches.count) range requests for a file with one cluster"
        )
    }

    @Test("B6b: The walk skips elements between the clusters and finds the one behind them")
    func passOverTags() async throws {
        typealias T = TestMatroskaFile
        func cluster(_ time: UInt64) -> Data {
            T.element(
                Matroska.ID.cluster,
                T.element(Matroska.ID.clusterTimestamp, T.unsigned(time))
                    + T.element(Matroska.ID.simpleBlock, Data([0x81, 0, 0, 0x80, 0, 0, 0, 1, 0x65])))
        }
        let tags = T.element(Matroska.ID.tags, Data(repeating: 0, count: 40_000))
        let file = cluster(0) + tags + cluster(1000) + tags
        let source = ByteCountingSource(file)
        let headers = try await MatroskaClusterWalk.index(
            source: source, firstCluster: 0, fileSize: file.count, workers: 1)
        #expect(headers.map(\.time) == [0, 1000])
        #expect(source.fetches.count <= 5, "\(source.fetches.count) range requests")
    }

    // MARK: B7 — avcC mit zwei PPS

    @Test("B7: All PPS from the avcC header of an MKV file arrive")
    func avcCTwoPPS() throws {
        let avcC = Data([
            1, 100, 0, 40, 0xFF, 0xE1, 0x00, 0x04, 0x67, 0x64, 0x00, 0x28,
            0x02, 0x00, 0x02, 0x68, 0xAA, 0x00, 0x02, 0x68, 0xBB,
        ])
        let description = try #require(VideoConfiguration.description(from: avcC, kind: .h264))
        #expect(description.sets.allPPS.count == 2, "PPS: \(description.sets.allPPS.map { Array($0) })")
    }

    @Test("B7b: All SPS and PPS from avcC and hvcC, empty sets are dropped")
    func headerRecordsComplete() throws {
        let avcC = Data([
            1, 100, 0, 40, 0xFF, 0xE3,
            0x00, 0x04, 0x67, 0x64, 0x00, 0x28,
            0x00, 0x00,
            0x00, 0x04, 0x67, 0x64, 0x00, 0x29,
            0x02, 0x00, 0x02, 0x68, 0xAA, 0x00, 0x02, 0x68, 0xBB,
        ])
        let h264 = try #require(VideoConfiguration.description(from: avcC, kind: .h264))
        #expect(h264.sets.allSPS.count == 2)
        #expect(h264.sets.allPPS.count == 2)

        var hvcC = Data(repeating: 0, count: 22)
        hvcC[0] = 1
        hvcC[21] = 0x03
        hvcC.append(3)
        hvcC += Data([0x20, 0x00, 0x01, 0x00, 0x02, 0x40, 0x01])
        hvcC += Data([0x21, 0x00, 0x02, 0x00, 0x02, 0x42, 0x01, 0x00, 0x02, 0x42, 0x02])
        hvcC += Data([0x22, 0x00, 0x02, 0x00, 0x02, 0x44, 0x01, 0x00, 0x02, 0x44, 0x02])
        let hevc = try #require(VideoConfiguration.description(from: hvcC, kind: .hevc))
        #expect(hevc.sets.allSPS == [Data([0x42, 0x01]), Data([0x42, 0x02])])
        #expect(hevc.sets.allPPS == [Data([0x44, 0x01]), Data([0x44, 0x02])])
    }

    @Test("B7c: The sets from the frames themselves arrive as well")
    func frameRecordsComplete() {
        let frame = Data([
            0, 0, 0, 3, 0x67, 0x64, 0x28,
            0, 0, 0, 2, 0x68, 0xAA,
            0, 0, 0, 2, 0x68, 0xBB,
        ])
        let wordings = VideoConfiguration.parameterSets(inFrames: [frame], kind: .h264, lengthSize: 4)
        #expect(wordings.allPPS == [Data([0x68, 0xAA]), Data([0x68, 0xBB])])
    }

    @Test("B7d: An empty parameter set is none — an orderly refusal instead of pointer games")
    func emptyRecord() {
        var wordings = TransportStream.ParameterSets()
        wordings.sps = Data()
        wordings.pps = Data()
        #expect(throws: SampleAssembly.AssemblyFailure.noParameterSets) {
            try SampleAssembly.formatDescription(from: wordings, kind: .h264)
        }
    }

    // MARK: B8 — Vorauslesen nach dem Halt

    // MARK: B9 — PES ohne Grenze

    @Test("B9: A PES without a new packet boundary does not grow past the emergency brake")
    func pesWithoutBoundary() {
        let reader = TransportStreamReader()
        var stream = Data()
        stream += RemuxerChecks.packet(
            pid: 0, pusi: true, cc: 0,
            payload: [
                0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE1, 0x00, 0, 0, 0, 0,
            ])
        stream += RemuxerChecks.packet(
            pid: 0x100, pusi: true, cc: 0,
            payload: [
                0x00, 0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x01, 0xF0, 0x00,
                0x1B, 0xE1, 0x01, 0xF0, 0x00, 0, 0, 0, 0,
            ])
        stream += RemuxerChecks.packet(
            pid: 0x101, pusi: true, cc: 0,
            payload: [0, 0, 1, 0xE0, 0, 0, 0x80, 0x00, 0x00] + [UInt8](repeating: 0x11, count: 175))
        var pieces: [TransportStreamReader.Piece] = []
        pieces += reader.read(stream)
        let continuation = [UInt8](repeating: 0x22, count: 184)
        var cc: UInt8 = 1
        for _ in 0..<30 {
            var block = Data()
            for _ in 0..<1000 {
                block += RemuxerChecks.packet(pid: 0x101, pusi: false, cc: cc, payload: continuation)
                cc &+= 1
            }
            pieces += reader.read(block)
        }
        pieces += reader.read(
            RemuxerChecks.packet(
                pid: 0x101, pusi: true, cc: cc,
                payload: [0, 0, 1, 0xE0, 0, 0, 0x80, 0x00, 0x00] + [UInt8](repeating: 0x11, count: 175)))
        let largest = pieces.filter { $0.pid == 0x101 }.map(\.data.count).max() ?? 0
        #expect(largest <= TransportStreamReader.maximumBuffer, "a PES of \(largest >> 10) KB")
        #expect(reader.discardedOversize >= 1)
    }

    // MARK: B10 — Absage mit Fehlerseite

    @Test("B10: A 403 with an error page remains a rejection and does not stall the retreat")
    func rejectionWithBody() async throws {
        let panel = try RejectionPanel()
        try await panel.start()
        defer { panel.stop() }
        let session = try LiveRemuxSession(
            source: URL(string: "http://127.0.0.1:\(panel.port)/live/u/p/1.ts")!,
            label: "check", readyTimeout: 4, timeOffset: 1 << 20)
        var failure: Error?
        do { try await session.startUp() } catch { failure = error }
        let attempts = panel.connections
        #expect(
            (failure as? LiveRemuxSession.SessionFailure) == .refused(status: 403),
            "failure: \(String(describing: failure)) after \(attempts) attempts")
        #expect(attempts <= 4, "\(attempts) attempts in 4 s against a panel that says 403 every time")
    }

    // MARK: Follow-up — the same pattern outside the reported places

    @Test("N2: The estimated grid tolerates marks from a nonsensical timescale")
    func gridNonsensicalScale() async {
        await #expect(processExitsWith: .success) {
            let marks = (0..<30).map { Int64($0) * 5 }
            _ = TimeGrid.estimate(marks: marks, scale: 1 << 62)
        }
        #expect(TimeGrid.estimate(marks: (0..<30).map { Int64($0) * 5 }, scale: 1 << 62) == nil)
    }

    @Test("N3: An empty MPEG audio frame does not stop the transcoder")
    func emptyMPEGFrame() async {
        await #expect(processExitsWith: .success) {
            var frame = Data([0xFF, 0xFB, 0x90, 0x64])
            frame += Data(repeating: 0, count: 413)
            guard let info = MPEGAudio.info(in: frame),
                let transcoder = try? MPEGAudioTranscoder(checking: info)
            else { exit(2) }
            _ = transcoder.transcode(Data(), at: .zero)
        }
    }

    // MARK: Vermutungen

    @Test("V1: A PTS overflow right behind the entry point drops the boundary")
    func entryOverflow() {
        let shortlyBeforeEnd: UInt64 = (1 << 33) - 3000
        #expect(TransportRemuxer.entry(pts: 600, limit: shortlyBeforeEnd) == .boundaryFalls)
        #expect(TransportRemuxer.entry(pts: shortlyBeforeEnd - 3600, limit: shortlyBeforeEnd) == .discard)
        #expect(TransportRemuxer.entry(pts: (1 << 33) - 1000, limit: 2000) == .discard)
    }

    @Test("V3: Offloading into the ring does not write under the lock of the store")
    func offloadWithoutLock() {
        let root = FileManager.default.temporaryDirectory.appending(path: "ring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SegmentStore(logsProduction: false)
        store.setHeader(Data([0]))
        let ring = TimeShiftRing(root: root, capacity: 1 << 30)
        store.enableTimeShift(ring)
        // The disk "hangs": whatever is offloaded stays in transit.
        store.suspendOffload()
        for i in 0..<21 { store.append(Data("s\(i)".utf8), duration: 2) }
        #expect(ring.count == 0, "the append itself wrote to disk")
        let list = store.playlist(isLive: true, base: "http://x")
        #expect(list.contains("http://x/segment0.m4s"), "in flight and still in the playlist")
        #expect(store.segment(0) == Data("s0".utf8))
        store.resumeOffload()
        store.awaitOffload()
        #expect(ring.count == 1)
        #expect(store.segment(0) == Data("s0".utf8))
        let following = store.playlist(isLive: true, base: "http://x")
        #expect(following.components(separatedBy: "segment0.m4s").count == 2, "exactly once in the playlist")
        #expect(following.contains("http://x/segment20.m4s"))
    }

    @Test("B10 control: The same 403 WITHOUT a body is recognized as a rejection")
    func rejectionWithoutBody() async throws {
        let panel = try RejectionPanel(mainContent: "")
        try await panel.start()
        defer { panel.stop() }
        let session = try LiveRemuxSession(
            source: URL(string: "http://127.0.0.1:\(panel.port)/live/u/p/2.ts")!,
            label: "check", readyTimeout: 4, timeOffset: 1 << 20)
        var failure: Error?
        do { try await session.startUp() } catch { failure = error }
        #expect((failure as? LiveRemuxSession.SessionFailure) == .refused(status: 403))
    }

    // MARK: Fix-Runde B (27.09.2026) — ultra-Befunde e6 Umpacker
}

/// What goes wrong when a test file does not have the expected shape — never expected,
/// but better a clear jump than a guessed number.
enum TestFailure: Error {
    case badFixture
}
