import Core
import CryptoKit
import Foundation

/// The start and end of a movie file on the device — **so that the second start does not again
/// wait ~8 s for the file header** (AP62, 2026-09-30).
///
/// **The finding:** On iptvhost the `moov` header of some MP4s sits at the end of the file (one sample film:
/// 5.5 MB behind 3.8 GB). Reproduced on the Mac: AVPlayer fetches it efficiently, but at startup
/// makes 4–5 requests one after another, and at ~0.5 s to the first byte per request plus
/// ~1.3 MB/s that adds up to ~7.5 s until "ready" — the same number as on the TV.
///
/// **What is stored here:** per title the **start** (up to 256 KB — that is where AVPlayer asks first) and
/// the **tail** from the end of the movie data to the end of the file, plus the size. Both
/// never change for an unchanged file. Not included: the movie data itself.
///
/// **Generous and still capped** (product decision 2026-09-30: "with 64 GB we can be more
/// generous"): 1 GB, the most recently used stays. tvOS clears the cache folder by itself
/// anyway when the device gets full, and Settings → Storage empties it by hand.
public final class HeadCache: @unchecked Sendable {

    public static let shared = HeadCache()

    /// This much of the start of the file is kept.
    public static let startMax = 256 * 1024
    /// Only what begins within this distance before the end of the file counts as the tail — the `moov`
    /// of a two-hour file is a few MB in size, not fifty.
    public static let tailZone: Int64 = 64 * 1024 * 1024
    /// The cap for all entries together.
    public static let limit: Int64 = 1024 * 1024 * 1024

    /// One entry — the size of the file and what of it is stored here.
    public struct ContentEntryRecord: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case size = "groesse"
            case contentType = "typ"
            case startLength = "anfangLaenge"
            case tailStart = "schwanzBeginn"
        }

        public let size: Int64
        public let contentType: String
        public let startLength: Int
        public let tailStart: Int64
    }

    private let folder: URL
    private let lock = NSLock()

    public init(folder: URL? = nil) {
        self.folder =
            folder
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Dateikoepfe", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    /// The key of a title — **without credentials.** An Xtream address carries name and
    /// password in the path; the key contains only the remote end and the last path component.
    public static func key(forItem url: URL) -> String {
        let raw = (url.host() ?? "") + "|" + url.lastPathComponent
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ key: String, _ fileExtension: String) -> URL {
        folder.appending(path: "\(key).\(fileExtension)")
    }

    public func entry(_ key: String) -> ContentEntryRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file(key, "json")),
            let entry = try? JSONDecoder().decode(ContentEntryRecord.self, from: data)
        else { return nil }
        // Last used — for clearing.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file(key, "json").path)
        return entry
    }

    public func start(_ key: String) -> Data? {
        try? Data(contentsOf: file(key, "anfang"), options: .mappedIfSafe)
    }

    public func tail(_ key: String) -> Data? {
        try? Data(contentsOf: file(key, "schwanz"), options: .mappedIfSafe)
    }

    public func save(
        _ key: String, size: Int64, contentType: String, start: Data, tailStart: Int64,
        tail: Data
    ) {
        guard !start.isEmpty, !tail.isEmpty, tailStart + Int64(tail.count) == size
        else { return }
        let entry = ContentEntryRecord(
            size: size, contentType: contentType, startLength: start.count, tailStart: tailStart)
        lock.lock()
        // Cleaning up in Settings takes the whole folder with it.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try start.write(to: file(key, "anfang"), options: .atomic)
            try tail.write(to: file(key, "schwanz"), options: .atomic)
            try JSONEncoder().encode(entry).write(to: file(key, "json"), options: .atomic)
        } catch {
            // Half-written is worse than not at all: then simply start over on the next start.
            Diagnostics.defect(
                "File head not written to the cache: \(Diagnostics.explain(error))", since: nil,
                area: "Wiedergabe")
            for fileExtension in ["anfang", "schwanz", "json"] {
                try? FileManager.default.removeItem(at: file(key, fileExtension))
            }
        }
        lock.unlock()
        cleanUp()
    }

    public func forget(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        for fileExtension in ["anfang", "schwanz", "json"] {
            try? FileManager.default.removeItem(at: file(key, fileExtension))
        }
    }

    /// How much is stored here — for Settings → Storage.
    public func taken() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return files().reduce(0) { $0 + $1.size }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for file in files() { try? FileManager.default.removeItem(at: file.url) }
    }

    /// The most recently used stays, until the limit holds again.
    func cleanUp(limit: Int64 = HeadCache.limit) {
        lock.lock()
        defer { lock.unlock() }
        var all = files()
        // Parts without their `json` are leftovers of an aborted write — nobody reads them.
        let whole = Set(
            all.filter { $0.url.pathExtension == "json" }.map {
                $0.url.deletingPathExtension().lastPathComponent
            })
        for waise in all where !whole.contains(waise.url.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: waise.url)
        }
        all.removeAll { !whole.contains($0.url.deletingPathExtension().lastPathComponent) }
        var sum = all.reduce(0) { $0 + $1.size }
        guard sum > limit else { return }
        // Per title by the age of its `json` line — that carries the last use.
        let alter = Dictionary(
            all.filter { $0.url.pathExtension == "json" }
                .map { ($0.url.deletingPathExtension().lastPathComponent, $0.date) },
            uniquingKeysWith: max)
        let row = alter.sorted { $0.value < $1.value }.map(\.key)
        for key in row where sum > limit {
            for fileExtension in ["anfang", "schwanz", "json"] {
                let url = file(key, fileExtension)
                // By name, not by URL: `/var/…` and `/private/var/…` are
                // the same file, but not the same URL.
                if let i = all.firstIndex(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                    sum -= all[i].size
                    all.remove(at: i)
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private struct File { let url: URL; let size: Int64; let date: Date }

    private func files() -> [File] {
        let resourceKeys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: resourceKeys)) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            return File(
                url: url, size: Int64(values?.fileSize ?? 0),
                date: values?.contentModificationDate ?? .distantPast)
        }
    }
}

// MARK: - The plan of a request

/// Where the bytes of a request come from — **store or provider, in that order.**
///
/// Pure computation, so that it can be tested without a network. A request that reaches from the end of the
/// movie data into the tail is split: the provider in front, the store behind.
public enum RangeSource: Sendable, Equatable {
    case cachedStart(Range<Int64>)
    case cachedTail(Range<Int64>)
    case provider(Range<Int64>)

    public var area: Range<Int64> {
        switch self {
        case .cachedStart(let b), .cachedTail(let b), .provider(let b): b
        }
    }
}

public enum RangePlan {

    /// - Parameters:
    ///   - von: the first requested position (`currentOffset` of the request).
    ///   - bis: the position **after** the last requested one, at most the file size.
    public static func plan(from: Int64, until: Int64, entry: HeadCache.ContentEntryRecord?) -> [RangeSource]
    {
        guard from < until else { return [] }
        guard let entry else { return [.provider(from..<until)] }
        var split: [RangeSource] = []
        var location = from
        let startEnd = Int64(entry.startLength)
        if location < startEnd {
            let end = min(until, startEnd)
            split.append(.cachedStart(location..<end))
            location = end
        }
        if location < until, location < entry.tailStart {
            let end = min(until, entry.tailStart)
            split.append(.provider(location..<end))
            location = end
        }
        if location < until {
            split.append(.cachedTail(location..<until))
        }
        return split
    }
}

// MARK: - The rules for the single stream

/// When the stream to the provider rests, restarts or keeps running — **pure computation**, so that
/// it can be tested without a network. The numbers come from 2026-09-30 (iptvhost and the reproduction).
enum StreamRule {

    /// How far the stream may be ahead of what AVPlayer has already received before it rests.
    /// Measured against what was delivered, not against the start of the look-ahead buffer: Otherwise the stream would rest right after
    /// every refill — a new connection for 16 KB, every 13 s.
    static let aheadMax: Int64 = 32 * 1024 * 1024
    /// This much behind what was delivered stays in the look-ahead buffer: After a refill AVPlayer asks on
    /// 16 KB before the position where it broke off, and small jumps back cost nothing this way.
    static let lookbackWidth: Int64 = 4 * 1024 * 1024
    /// At the front the buffer is trimmed only in steps — a `removeFirst` on 32 MB per chunk would be expensive.
    static let shortenStep: Int64 = 4 * 1024 * 1024
    /// The hard cap for the look-ahead buffer in memory — Apple TV has little of it.
    static let leadMax: Int64 = 64 * 1024 * 1024
    /// How long waiting for the running stream is worthwhile instead of restarting: A new
    /// start costs ~0.5 s to the first byte on iptvhost.
    static let catchUpTime: TimeInterval = 0.75
    static let catchUpWidthMax: Int64 = 8 * 1024 * 1024
    static let catchUpWidthMin: Int64 = 256 * 1024
    /// The rate that applies as long as the stream has not yet measured one.
    static let assumedRate: Double = 1024 * 1024

    /// A waiting request from AVPlayer, as ``demand(_:)`` sees it.
    struct Waiter: Equatable {
        var location: Int64
        var prefetcher: Bool
        /// The number in order of arrival — higher is younger.
        var order: Int
        init(location: Int64, prefetcher: Bool, order: Int) {
            self.location = location
            self.prefetcher = prefetcher
            self.order = order
        }
    }

    /// **Which waiting request the stream serves** (diagnostic F-048, 2026-10-11): First
    /// the foremost of the small readers — they sit at the position AVPlayer needs *now*;
    /// at startup 2.8 MB before the read-ahead reader (2026-09-30), after a jump far
    /// behind it. The old rule "the foremost of all" sent the stream, after the second
    /// jump, back to the **old** read-ahead reader at 770 MB while the reader at 1.7 GB
    /// waited — 50 s of still frame. If only read-ahead readers are waiting, the youngest counts: After a
    /// jump in either direction that is the one at the new position.
    static func demand(_ waiters: [Waiter]) -> Int64? {
        if let reader = waiters.filter({ !$0.prefetcher }).map(\.location).min() { return reader }
        return waiters.max { $0.order < $1.order }?.location
    }

    /// A read-ahead reader that lies further than ``aheadMax`` from a younger request
    /// is **overtaken**: AVPlayer left it behind at the jump, and
    /// neither the demand nor the trimming of the look-ahead buffer is based on it any more. It is still served
    /// if the stream ever comes by.
    static func superseded(alter: Int64, newer: Int64) -> Bool {
        abs(alter - newer) > aheadMax
    }

    /// For this long nobody may be served before the stream counts as "reading past".
    static let stallMax: TimeInterval = 1.5
    /// This many seconds of reading up to the wanted position the stream still tolerates before it
    /// restarts — **more than the catch range, on purpose** (diagnostic D3AA, 2026-10-11):
    /// AVPlayer reads picture and sound at two positions, 1–2 MB apart on iptvhost. If the
    /// stream restarted already after the catch range (0.75 s), it oscillated between the two — three
    /// restarts in ten seconds, each 0.5 s and with an empty look-ahead buffer, and no position
    /// was completed. Five seconds of reading through are cheaper than this oscillation; only at
    /// 6.8 MB (15 s, diagnostic F-048) is the restart worthwhile.
    static let detourMax: TimeInterval = 5

    /// **The stream reads past everyone** (diagnostic F-048, first jump): 6.8 MB behind
    /// the one waiting request, for 15 s, because after it arrived nobody
    /// checked again. If nobody has been served since ``stallMax`` and the next position
    /// would lie more than ``detourMax`` of reading time ahead, the stream restarts. At
    /// startup this does not apply: There the stream serves the readers continuously, and the silence stays
    /// under one second.
    static func readsPast(
        streamPosition: Int64, needs: Int64, rate: Double?, idleFor: TimeInterval
    ) -> Bool {
        let detour = Int64((rate ?? assumedRate) * detourMax)
        return idleFor >= stallMax && needs > streamPosition + max(catchUpWidth(rate: rate), detour)
    }

    /// How far a wanted position may lie before the stream position so that the stream waits instead of
    /// restarting — **as much as the stream delivers in ``catchUpTime``.** On iptvhost at
    /// 0.52 MB/s a fixed 8 MB would be 16 s of waiting; at 1.3 MB/s 8 MB is enough for 6 s.
    ///
    /// **In the tail the whole range applies:** When reading the `moov`, AVPlayer jumps forward and
    /// back (2.6 MB forward, then 2.5 MB back), but in the end needs every byte of it. A
    /// stream that simply reads through the tail is 1–1.3 s faster there than two new
    /// starts (2026-09-30, reproduction).
    static func catchUpWidth(rate: Double?, inTail: Bool = false) -> Int64 {
        if inTail { return catchUpWidthMax }
        let bytes = Int64((rate ?? assumedRate) * catchUpTime)
        return min(catchUpWidthMax, max(catchUpWidthMin, bytes))
    }

    /// Whether stream and wanted position both lie in the tail zone — then the header is read.
    static func inTail(streamPosition: Int64, needs: Int64, size: Int64?) -> Bool {
        guard let size else { return false }
        let zone = size - HeadCache.tailZone
        return streamPosition >= zone && needs >= zone
    }

    /// Whether the stream may rest: nobody is waiting, and it is far enough ahead of what was delivered.
    static func mayRest(streamPosition: Int64, deliveredUpTo: Int64, waiting: Bool) -> Bool {
        !waiting && streamPosition - deliveredUpTo > aheadMax
    }

    /// Up to where the look-ahead buffer is trimmed at the front: the ``lookbackWidth`` behind what was delivered
    /// stays, a waiting request is never cut off, trimming happens only in steps —
    /// and above the hard cap in every case.
    ///
    /// **In the tail nothing is trimmed:** AVPlayer reads the `moov` first in one piece and then
    /// once more from the front (2026-09-30, iptvhost: after 8.6 MB again from the start of the header). If the
    /// start were already gone, the whole header would come from the provider a second time — 6 s on first start.
    /// The zone is at most ``HeadCache/tailZone`` in size; the cap holds it anyway.
    static func shortenTo(
        leadStart: Int64, leadEnd: Int64, deliveredUpTo: Int64, earliestWaiting: Int64?,
        tailZoneHint: Int64? = nil
    ) -> Int64 {
        var target = deliveredUpTo - lookbackWidth
        if let waiters = earliestWaiting { target = min(target, waiters) }
        // Never behind the end: what would lie there does not exist in the look-ahead buffer.
        target = min(target, leadEnd)
        if leadEnd - leadStart > leadMax {
            return max(leadStart, max(target, leadEnd - leadMax))
        }
        if let tailZoneHint, leadEnd > tailZoneHint { return leadStart }
        return target - leadStart >= shortenStep ? target : leadStart
    }
}

// MARK: - Writing along on the first start

/// Collects what passes through on first start — **and says when start and tail are completely
/// there.**
///
/// The start is the gapless range from 0 (at most ``HeadCache/startMax``),
/// the tail the gapless range that ends at the end of the file and begins within
/// ``HeadCache/tailZone``. AVPlayer fetches exactly these ranges anyway — nothing
/// extra is requested here.
public struct Transcript: Sendable {

    public let size: Int64
    private(set) var start = Data()
    /// Pieces in the tail zone, by start position — **one piece per stream**, not per
    /// chunk: What connects gaplessly to the last one taken is appended. Otherwise
    /// after a 64 MB stream there would be four thousand entries here, and ``done()`` would search them on
    /// every chunk anew.
    private(set) var pieces: [Int64: Data] = [:]
    private var lastChunk: Int64?

    public init(size: Int64) { self.size = size }

    public mutating func take(_ data: Data, at location: Int64) {
        guard !data.isEmpty else { return }
        // Start: only what connects gaplessly.
        let startEnd = Int64(start.count)
        if location <= startEnd, startEnd < Int64(HeadCache.startMax) {
            let offset = Int(startEnd - location)
            if offset < data.count {
                let rest = HeadCache.startMax - start.count
                start.append(
                    data[data.startIndex + offset..<data.startIndex + min(data.count, offset + rest)])
            }
        }
        // Tail: everything that lies in the zone.
        let zoneStart = size - HeadCache.tailZone
        let end = location + Int64(data.count)
        guard end > zoneStart else { return }
        let begin = max(location, zoneStart)
        let part = data[data.startIndex + Int(begin - location)..<data.endIndex]
        if let last = lastChunk, let previous = pieces[last], last + Int64(previous.count) == begin {
            pieces[last]!.append(part)
            return
        }
        if let available = pieces[begin], available.count >= part.count { return }
        pieces[begin] = Data(part)
        lastChunk = begin
    }

    /// Whether a piece reaches to the end of the file — then the end is through, and ``done()`` has
    /// decided whether a header lies there.
    public var reachesToEnd: Bool {
        pieces.contains { $0.key + Int64($0.value.count) >= size }
    }

    /// Whether the header lies **at the front** — read off the first boxes: after `ftyp` (and `free`)
    /// comes either `moov` or `mdat`. If it lies at the front, there is nothing to store here, and the
    /// recording can go **before** it collects up to 64 MB of movie data at the end of the film. `nil`
    /// as long as the start does not yet reveal it.
    public var headAtFront: Bool? {
        let bytes = [UInt8](start)
        var location = 0
        while location + 8 <= bytes.count {
            var size =
                Int(bytes[location]) << 24 | Int(bytes[location + 1]) << 16
                | Int(bytes[location + 2]) << 8 | Int(bytes[location + 3])
            let contentType = String(decoding: bytes[location + 4..<location + 8], as: UTF8.self)
            if contentType == "moov" { return true }
            if contentType == "mdat" { return false }
            if size == 1 {
                guard location + 16 <= bytes.count else { return nil }
                size = bytes[location + 8..<location + 16].reduce(0) { $0 << 8 | Int($1) }
            }
            guard size >= 8 else { return nil }
            location += size
        }
        return nil
    }

    /// Start and gapless tail up to the end of the file — `nil` as long as one is missing.
    public func done() -> (start: Data, tailStart: Int64, tail: Data)? {
        guard start.count >= 2, !pieces.isEmpty else { return nil }
        // Assemble gaplessly from the back.
        var end = size
        var split: [(Int64, Data)] = []
        var next = true
        while next {
            next = false
            // The piece that begins furthest forward and reaches to `end`.
            let matching = pieces.filter { $0.key < end && $0.key + Int64($0.value.count) >= end }
            if let best = matching.min(by: { $0.key < $1.key }) {
                let usable = best.value.prefix(Int(end - best.key))
                split.insert((best.key, Data(usable)), at: 0)
                end = best.key
                next = true
            }
        }
        guard end < size, let first = split.first else { return nil }
        var tail = Data()
        for (_, data) in split { tail.append(data) }
        guard first.0 + Int64(tail.count) == size else { return nil }
        // **From the `moov` on it must be whole boxes** — otherwise a piece of the header is missing at the front.
        // The few KB of movie data before it stay: AVPlayer asks for the header rounded down to 16 KB,
        // and without them a request would go out again for exactly those bytes (+0.5 s).
        guard Self.boxStart(in: tail) != nil else { return nil }
        return (start, first.0, tail)
    }

    /// The earliest position from which the bytes are a ``isBoxSequence(_:)`` — the search is
    /// for the box name `moov`, preceded by four bytes of size.
    static func boxStart(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        let moov: [UInt8] = Array("moov".utf8)
        var i = 4
        while i + 4 <= bytes.count {
            if bytes[i] == moov[0], bytes[i + 1] == moov[1], bytes[i + 2] == moov[2], bytes[i + 3] == moov[3],
                isBoxSequence(data.subdata(in: data.startIndex + i - 4..<data.endIndex))
            {
                return i - 4
            }
            i += 1
        }
        return nil
    }

    /// Whether the bytes are **whole MP4 boxes** that end exactly at the end, with a `moov`
    /// among them — otherwise it is only a piece of the header, and storing waits.
    static func isBoxSequence(_ data: Data) -> Bool {
        var location = 0
        var withMoov = false
        let bytes = [UInt8](data)
        while location + 8 <= bytes.count {
            var size =
                Int(bytes[location]) << 24 | Int(bytes[location + 1]) << 16
                | Int(bytes[location + 2]) << 8 | Int(bytes[location + 3])
            let contentType = bytes[location + 4..<location + 8]
            guard contentType.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return false }
            if size == 1 {
                guard location + 16 <= bytes.count else { return false }
                size = bytes[location + 8..<location + 16].reduce(0) { $0 << 8 | Int($1) }
            }
            guard size >= 8 else { return false }
            if String(decoding: contentType, as: UTF8.self) == "moov" { withMoov = true }
            location += size
        }
        return location == bytes.count && withMoov
    }
}
