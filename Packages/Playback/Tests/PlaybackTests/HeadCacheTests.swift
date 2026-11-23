import Foundation
import Testing

@testable import Playback

/// **The file-header cache** (AP62, 2026-09-30) — what is checked is the computation,
/// not the network.
///
/// Measured on the Mac against a replica of the provider (1.3 MB/s, 0.5 s per
/// request): first start 7.9 s to playback, second start from the cache 1.6 s.
@Suite("File head cache")
struct HeadCacheTests {

    private let entry = HeadCache.ContentEntryRecord(
        size: 1000, contentType: "public.mpeg-4", startLength: 16, tailStart: 900)

    // MARK: - Plan

    @Test("Without a cache everything goes to the provider")
    func withoutBacklog() {
        #expect(RangePlan.plan(from: 0, until: 1000, entry: nil) == [.provider(0..<1000)])
    }

    @Test("The request for the start is served entirely from the cache")
    func start() {
        #expect(RangePlan.plan(from: 0, until: 2, entry: entry) == [.cachedStart(0..<2)])
    }

    @Test("The request for the file head is served entirely from the cache")
    func header() {
        #expect(RangePlan.plan(from: 900, until: 1000, entry: entry) == [.cachedTail(900..<1000)])
        #expect(RangePlan.plan(from: 950, until: 1000, entry: entry) == [.cachedTail(950..<1000)])
    }

    @Test("Movie data goes to the provider")
    func movieData() {
        #expect(RangePlan.plan(from: 200, until: 900, entry: entry) == [.provider(200..<900)])
    }

    @Test("A request over everything is split: start, provider, head")
    func shared() {
        #expect(
            RangePlan.plan(from: 0, until: 1000, entry: entry) == [
                .cachedStart(0..<16), .provider(16..<900), .cachedTail(900..<1000),
            ])
    }

    @Test("An empty request plans nothing")
    func empty() {
        #expect(RangePlan.plan(from: 5, until: 5, entry: entry).isEmpty)
    }

    // MARK: - Write-along

    @Test("Start and gapless tail make an entry")
    func transcript() throws {
        let size: Int64 = 100 * 1024 * 1024
        var m = Transcript(size: size)
        m.take(Data([1, 2]), at: 0)
        #expect(m.done() == nil)
        // Like AVPlayer: the header in two pieces, the second up to the end of the file.
        let moov = Self.box("moov", length: 3000)
        m.take(moov.prefix(2000), at: size - 3000)
        #expect(m.done() == nil)
        m.take(moov.suffix(1000), at: size - 1000)
        let done = try #require(m.done())
        #expect(done.start == Data([1, 2]))
        #expect(done.tailStart == size - 3000)
        #expect(done.tail == moov)
    }

    @Test("A gap in the tail makes no entry")
    func gap() {
        let size: Int64 = 100 * 1024 * 1024
        var m = Transcript(size: size)
        m.take(Data([1, 2]), at: 0)
        let moov = Self.box("moov", length: 3000)
        m.take(moov.prefix(1000), at: size - 3000)
        m.take(moov.suffix(1000), at: size - 1000)
        #expect(m.done() == nil)
    }

    @Test("Only the rear part of the head is not stored")
    func onlyLaterPart() {
        let size: Int64 = 100 * 1024 * 1024
        var m = Transcript(size: size)
        m.take(Data([1, 2]), at: 0)
        m.take(Self.box("moov", length: 3000).suffix(1000), at: size - 1000)
        #expect(m.done() == nil)
    }

    @Test("Movie data before the moov stays if everything from the moov on is whole boxes")
    func movieDataBefore() throws {
        let size: Int64 = 100 * 1024 * 1024
        var m = Transcript(size: size)
        m.take(Data([1, 2]), at: 0)
        // Like AVPlayer: from a position before the moov (rounded down to 16 KB) to the end.
        let moov = Self.box("moov", length: 3000)
        m.take(Data(repeating: 0x11, count: 500) + moov, at: size - 3500)
        let done = try #require(m.done())
        #expect(done.tailStart == size - 3500)
        #expect(done.tail.suffix(3000) == moov)
    }

    @Test("Box sequence: whole boxes with moov, otherwise not")
    func boxSequence() {
        #expect(Transcript.isBoxSequence(Self.box("moov", length: 100) + Self.box("free", length: 20)))
        #expect(!Transcript.isBoxSequence(Self.box("free", length: 20)))
        #expect(!Transcript.isBoxSequence(Self.box("moov", length: 100).prefix(60)))
        #expect(!Transcript.isBoxSequence(Data(repeating: 8, count: 100)))
    }

    static func box(_ contentType: String, length: Int) -> Data {
        var d = Data([
            UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF),
            UInt8(length & 0xFF),
        ])
        d.append(contentsOf: Array(contentType.utf8))
        d.append(Data(repeating: 0xAB, count: length - 8))
        return d
    }

    @Test("Movie data far before the end is not written along")
    func outsideTheZone() {
        let size: Int64 = 1024 * 1024 * 1024
        var m = Transcript(size: size)
        m.take(Data(repeating: 1, count: 4096), at: 500 * 1024 * 1024)
        #expect(m.pieces.isEmpty)
        #expect(!m.reachesToEnd)
    }

    @Test("Chunks of a stream become one piece — and still yield the head")
    func mergeSmallChunks() throws {
        let size: Int64 = 100 * 1024 * 1024
        var m = Transcript(size: size)
        m.take(Data([1, 2]), at: 0)
        let moov = Self.box("moov", length: 3000)
        // Like URLSession: the tail arrives in many small chunks one after another.
        var location = size - 3000
        for chunk in stride(from: 0, to: 3000, by: 128) {
            let part = moov[chunk..<min(3000, chunk + 128)]
            m.take(Data(part), at: location)
            location += Int64(part.count)
        }
        #expect(m.pieces.count == 1)
        #expect(m.reachesToEnd)
        let done = try #require(m.done())
        #expect(done.tail == moov)
        #expect(done.tailStart == size - 3000)
    }

    @Test("The start shows whether the head is at the front")
    func headAtFront() {
        let size: Int64 = 100 * 1024 * 1024
        var foreground = Transcript(size: size)
        foreground.take(Self.box("ftyp", length: 32) + Self.box("moov", length: 100), at: 0)
        #expect(foreground.headAtFront == true)
        var rearmost = Transcript(size: size)
        rearmost.take(
            Self.box("ftyp", length: 32) + Self.box("free", length: 8)
                + Self.box("mdat", length: 4000).prefix(64), at: 0)
        #expect(rearmost.headAtFront == false)
        var pending = Transcript(size: size)
        pending.take(Self.box("ftyp", length: 32).prefix(20), at: 0)
        #expect(pending.headAtFront == nil)
    }

    @Test("An end without a head reaches to the end but makes no entry")
    func endWithoutHead() {
        let size: Int64 = 100 * 1024 * 1024
        var m = Transcript(size: size)
        m.take(Data([1, 2]), at: 0)
        m.take(Data(repeating: 7, count: 2000), at: size - 2000)
        #expect(m.reachesToEnd)
        #expect(m.done() == nil)
    }

    // MARK: - Stream rule

    @Test("The catch width follows the measured rate, within limits")
    func catchUpWidth() {
        // iptvhost on 2026-09-30: 0.52 MB/s — 8 MB would be 16 s of waiting, 0.75 s is ~400 KB.
        #expect(StreamRule.catchUpWidth(rate: 520_000) == Int64(520_000 * 0.75))
        #expect(StreamRule.catchUpWidth(rate: nil) == Int64(StreamRule.assumedRate * 0.75))
        #expect(StreamRule.catchUpWidth(rate: 1_000) == StreamRule.catchUpWidthMin)
        #expect(StreamRule.catchUpWidth(rate: 100_000_000) == StreamRule.catchUpWidthMax)
        // The header is read in the tail — there the full width counts, however slow.
        #expect(StreamRule.catchUpWidth(rate: 520_000, inTail: true) == StreamRule.catchUpWidthMax)
    }

    @Test("Demand: the foremost reader first, otherwise the youngest prefetcher")
    func demand() {
        typealias W = StreamRule.Waiter
        // Start (2026-09-30): read-ahead 2.8 MB ahead of the reader — the reader counts.
        #expect(
            StreamRule.demand([
                W(location: 2_800_000, prefetcher: true, order: 1),
                W(location: 0, prefetcher: false, order: 2),
            ]) == 0)
        // Seek forward (F-048): the old read-ahead lies far ahead — the reader counts.
        #expect(
            StreamRule.demand([
                W(location: 770_417_142, prefetcher: true, order: 3),
                W(location: 1_711_316_090, prefetcher: false, order: 4),
            ]) == 1_711_316_090)
        // Only read-aheads: the youngest, in both directions.
        #expect(
            StreamRule.demand([
                W(location: 770_417_142, prefetcher: true, order: 3),
                W(location: 1_711_400_000, prefetcher: true, order: 5),
            ]) == 1_711_400_000)
        #expect(
            StreamRule.demand([
                W(location: 1_711_400_000, prefetcher: true, order: 5),
                W(location: 500_000_000, prefetcher: true, order: 6),
            ]) == 500_000_000)
        #expect(StreamRule.demand([]) == nil)
    }

    @Test("A prefetcher is superseded when it lies beyond the prefetch limit from a younger request")
    func superseded() {
        #expect(StreamRule.superseded(alter: 770_417_142, newer: 1_711_316_090))
        #expect(StreamRule.superseded(alter: 1_711_316_090, newer: 770_417_142))
        // Start: 2.8 MB apart — not overtaken, the stream comes by.
        #expect(!StreamRule.superseded(alter: 2_800_000, newer: 0))
        #expect(!StreamRule.superseded(alter: 0, newer: StreamRule.aheadMax))
    }

    @Test("Reads past: idle for one and a half seconds and more than five seconds of reading ahead")
    func readsPast() {
        // F-048, first seek: stream at 756.6 MB, request at 763.4 MB, 0.44 MB/s = 15 s.
        #expect(
            StreamRule.readsPast(
                streamPosition: 756_584_763, needs: 763_363_328, rate: 440_000, idleFor: 1.5))
        #expect(
            !StreamRule.readsPast(
                streamPosition: 756_584_763, needs: 763_363_328, rate: 440_000, idleFor: 1.4))
        // D3AA, second seek: 1 MB ahead at 0.4 MB/s = 2.5 s — read through instead of
        // oscillating.
        #expect(
            !StreamRule.readsPast(
                streamPosition: 560_296_497, needs: 561_256_283, rate: 400_000, idleFor: 1.6))
        // Without a measured rate the assumed one applies: 5 MB is five seconds.
        #expect(!StreamRule.readsPast(streamPosition: 0, needs: 5_000_000, rate: nil, idleFor: 2))
        #expect(StreamRule.readsPast(streamPosition: 0, needs: 5_500_000, rate: nil, idleFor: 2))
        // Behind the stream: that is what the lead is for, not this rule.
        #expect(
            !StreamRule.readsPast(
                streamPosition: 756_584_763, needs: 700_000_000, rate: 440_000, idleFor: 10))
    }

    @Test("Stream and demand are in the tail when both lie in the zone before the end of the file")
    func inTail() {
        let size: Int64 = 4_629_922_731
        let zone = size - HeadCache.tailZone
        #expect(StreamRule.inTail(streamPosition: zone + 16_384, needs: zone + 2_600_000, size: size))
        #expect(
            !StreamRule.inTail(
                streamPosition: 664_272_896, needs: 664_272_896 + 1_000_000, size: size))
        #expect(!StreamRule.inTail(streamPosition: 16_384, needs: zone + 100, size: size))
        #expect(!StreamRule.inTail(streamPosition: zone + 100, needs: zone + 200, size: nil))
    }

    @Test("The stream rests only when nobody is waiting and it is far ahead of what was delivered")
    func rest() {
        let mb: Int64 = 1024 * 1024
        #expect(StreamRule.mayRest(streamPosition: 40 * mb, deliveredUpTo: 0, waiting: false))
        #expect(!StreamRule.mayRest(streamPosition: 40 * mb, deliveredUpTo: 0, waiting: true))
        // After refilling: lead from 0, delivered up to 27 MB, stream at 33 MB — keeps
        // running.
        #expect(!StreamRule.mayRest(streamPosition: 33 * mb, deliveredUpTo: 27 * mb, waiting: false))
    }

    @Test(
        "At the front, trimming happens behind what was delivered, in steps, never before a waiting request")
    func shorten() {
        let mb: Int64 = 1024 * 1024
        // Too little for a step: stays.
        #expect(
            StreamRule.shortenTo(
                leadStart: 0, leadEnd: 10 * mb, deliveredUpTo: 7 * mb, earliestWaiting: nil) == 0)
        // One step: to look-back distance behind what was delivered.
        #expect(
            StreamRule.shortenTo(
                leadStart: 0, leadEnd: 20 * mb, deliveredUpTo: 9 * mb, earliestWaiting: nil) == 5
                * mb)
        // A waiting request further ahead holds the lead.
        #expect(
            StreamRule.shortenTo(
                leadStart: 0, leadEnd: 20 * mb, deliveredUpTo: 9 * mb, earliestWaiting: 2 * mb) == 0)
        // Above the cap it is trimmed in every case.
        #expect(
            StreamRule.shortenTo(
                leadStart: 0, leadEnd: 70 * mb, deliveredUpTo: 1 * mb, earliestWaiting: 0) == 6 * mb)
        // Im Schwanz bleibt alles: AVPlayer liest den Kopf zweimal.
        #expect(
            StreamRule.shortenTo(
                leadStart: 1000 * mb, leadEnd: 1009 * mb, deliveredUpTo: 1009 * mb,
                earliestWaiting: nil, tailZoneHint: 990 * mb) == 1000 * mb)
        #expect(
            StreamRule.shortenTo(
                leadStart: 0, leadEnd: 20 * mb, deliveredUpTo: 9 * mb, earliestWaiting: nil,
                tailZoneHint: 990 * mb) == 5 * mb)
    }

    /// Fable check 2026-10-01: after a seek back, ``deliveredUpTo`` still stood at the
    /// `moov` (≈ end of file) — the target lay far behind the lead, `removeFirst` crashed.
    @Test("Trimming never goes past the end of the read-ahead")
    func neverPastTheEnd() {
        let mb: Int64 = 1024 * 1024
        let target = StreamRule.shortenTo(
            leadStart: 100 * mb, leadEnd: 110 * mb, deliveredUpTo: 3800 * mb, earliestWaiting: nil)
        #expect(target >= 100 * mb && target <= 110 * mb)
        let capped = StreamRule.shortenTo(
            leadStart: 0, leadEnd: 70 * mb, deliveredUpTo: 3800 * mb, earliestWaiting: nil)
        #expect(capped <= 70 * mb)
    }

    // MARK: - Cache

    private func freshFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "kopfvorrat-\(UUID().uuidString)")
    }

    @Test("Stored, read, forgotten")
    func saving() throws {
        let downloads = HeadCache(folder: freshFolder())
        downloads.save(
            "a", size: 1000, contentType: "public.mpeg-4", start: Data(repeating: 1, count: 16),
            tailStart: 900, tail: Data(repeating: 2, count: 100))
        let read = try #require(downloads.entry("a"))
        #expect(read == entry)
        #expect(downloads.tail("a")?.count == 100)
        #expect(downloads.taken() > 116)
        downloads.forget("a")
        #expect(downloads.entry("a") == nil)
    }

    @Test("A tail that does not reach the end is not stored")
    func incomplete() {
        let downloads = HeadCache(folder: freshFolder())
        downloads.save(
            "a", size: 1000, contentType: "public.mpeg-4", start: Data([1]), tailStart: 900,
            tail: Data(repeating: 2, count: 50))
        #expect(downloads.entry("a") == nil)
    }

    @Test("Above the limit, the most recently used goes last")
    func clear() throws {
        let downloads = HeadCache(folder: freshFolder())
        for name in ["alt", "neu"] {
            downloads.save(
                name, size: 1000, contentType: "t", start: Data([1]), tailStart: 0,
                tail: Data(repeating: 2, count: 1000))
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = downloads.entry("neu")
        downloads.cleanUp(limit: 1500)
        #expect(downloads.entry("alt") == nil)
        #expect(downloads.entry("neu") != nil)
    }

    @Test("Leftovers without their json are deleted when cleaning up")
    func orphans() throws {
        let folder = freshFolder()
        let downloads = HeadCache(folder: folder)
        for name in ["a", "b"] {
            downloads.save(
                name, size: 10, contentType: "t", start: Data([1]), tailStart: 5,
                tail: Data(repeating: 2, count: 5))
        }
        let json = try #require(
            FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
        try FileManager.default.removeItem(at: json)
        downloads.cleanUp()
        let rest = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(rest.count == 3)
        #expect(rest.filter { $0.pathExtension == "json" }.count == 1)
    }

    @Test("After clearing in Settings, storing resumes")
    func afterClearing() throws {
        let folder = freshFolder()
        let downloads = HeadCache(folder: folder)
        try FileManager.default.removeItem(at: folder)
        downloads.save(
            "a", size: 10, contentType: "t", start: Data([1]), tailStart: 5,
            tail: Data(repeating: 2, count: 5))
        #expect(downloads.entry("a") != nil)
    }

    // MARK: - Addresses

    @Test("The key carries no credentials and is unique per title")
    func key() {
        let a = HeadCache.key(
            forItem: URL(string: "http://iptvhost.example:2086/movie/max/geheim/343792.mp4")!)
        let b = HeadCache.key(
            forItem: URL(string: "http://iptvhost.example:2086/movie/anders/pw/343792.mp4")!)
        let c = HeadCache.key(forItem: URL(string: "http://iptvhost.example:2086/movie/max/geheim/1.mp4")!)
        #expect(a == b)
        #expect(a != c)
        #expect(!a.contains("geheim"))
    }

    @Test("Only Xtream movies and episodes as MP4 take the cache")
    @MainActor
    func selection() {
        #expect(NativePlaybackEngine.usesHeadCache(URL(string: "http://h:2086/movie/u/p/1.mp4")!))
        #expect(NativePlaybackEngine.usesHeadCache(URL(string: "http://h:2086/series/u/p/2.mp4")!))
        #expect(!NativePlaybackEngine.usesHeadCache(URL(string: "http://h:2086/live/u/p/3.m3u8")!))
        #expect(!NativePlaybackEngine.usesHeadCache(URL(string: "http://h:2086/movie/u/p/4.mkv")!))
        #expect(!NativePlaybackEngine.usesHeadCache(URL(string: "http://jf:8096/Videos/5/stream.mp4")!))
    }

    @Test("Own and real address go back and forth losslessly")
    func addresses() throws {
        let real = URL(string: "http://iptvhost.example:2086/movie/u/p/343792.mp4?x=1")!
        let own = try #require(HeadCacheLoader.ownAddress(forItem: real))
        #expect(own.scheme == "clkopf-http")
        #expect(HeadCacheLoader.realAddress(from: own) == real)
    }
}
