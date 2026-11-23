import Foundation

/// The disk ring for time-shifted TV (AP9).
///
/// **The buffer holds 40 seconds in memory** — pausing for minutes needs the
/// disk. What falls out of the buffer's window lands here as a file; the
/// playlist continues it, AVPlayer seeks in it by itself. The ring has a
/// fixed upper limit (500 MB ≈ ten minutes at 6 Mbit/s, four at 17) and
/// throws away the oldest when it is exceeded. Every session has its own
/// folder; it disappears with it, and app start clears what a crash left
/// behind (``sweep(root:)``).
public final class TimeShiftRing: @unchecked Sendable {

    /// The upper limit — product requirement 2026-09-04: blocking 500 MB is
    /// acceptable.
    public static let defaultCapacity: Int64 = 500 * 1_000_000
    public static let rootDirectoryName = "zeitversatz"

    public struct Entry: Sendable, Equatable {
        public let index: Int
        public let url: URL
        public let bytes: Int64
        public let duration: Double
        public let independent: Bool
        public let period: Int
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var _bytes: Int64 = 0
    public let directory: URL
    public let capacity: Int64

    /// The root folder of all rings — in the cache, so that the system may clear
    /// it itself in an emergency.
    public static func root(under base: URL? = nil) -> URL {
        let caches =
            base
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: rootDirectoryName)
    }

    public init(root: URL? = nil, capacity: Int64 = TimeShiftRing.defaultCapacity) {
        self.capacity = capacity
        directory = Self.root(under: root).appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { removeAll() }

    /// Takes in a segment that the buffer no longer holds.
    ///
    /// **If writing fails, the ring is emptied** (remuxer check B5, 2026-09-27).
    /// Here the segment silently dropped out, and the playlist numbers ring and
    /// window consecutively from the first entry: from the gap on, every address
    /// stood at the list position of its successor, the gap itself ran into a
    /// 404, and the most recent segment was missing. With a full disk — realistic
    /// on an Apple TV with 32 GB — the time shift thereby played wrong segments.
    /// An empty ring is gapless; it fills anew from the next segment — and only
    /// from a segment that begins with a keyframe: a playlist that starts in the
    /// middle of a group of pictures shows blocks when rewinding to the start. For
    /// the same reason the upper limit evicts group by group, like the buffer's
    /// window.
    public func store(index: Int, data: Data, duration: Double, independent: Bool, period: Int) {
        guard independent || count > 0 else { return }
        let url = directory.appending(path: "segment\(index).m4s")
        guard (try? data.write(to: url, options: .atomic)) != nil else {
            clear()
            return
        }
        lock.lock()
        entries.append(
            Entry(
                index: index, url: url, bytes: Int64(data.count), duration: duration,
                independent: independent, period: period))
        _bytes += Int64(data.count)
        var discarded: [URL] = []
        while _bytes > capacity, entries.count > 1 {
            let old = entries.removeFirst()
            _bytes -= old.bytes
            discarded.append(old.url)
        }
        while let first = entries.first, !first.independent, entries.count > 1 {
            _bytes -= first.bytes
            discarded.append(entries.removeFirst().url)
        }
        lock.unlock()
        for url in discarded { try? FileManager.default.removeItem(at: url) }
    }

    /// Whether a segment is in the ring — without reading it (AP72).
    /// ``SegmentStore/waitForSegment`` used to ask via ``data(for:)`` and read
    /// the whole file from disk just to check `!= nil`; the provider then read it
    /// a second time.
    public func contains(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.index == index }
    }

    public func data(for index: Int) -> Data? {
        lock.lock()
        let entry = entries.first { $0.index == index }
        lock.unlock()
        guard let entry else { return nil }
        return try? Data(contentsOf: entry.url)
    }

    /// The segments in order — for the playlist.
    public var pieces: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public var firstIndex: Int? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first?.index
    }

    public var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return entries.reduce(0) { $0 + $1.duration }
    }

    public var bytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _bytes
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Discards all entries together with their files, the folder stays.
    private func clear() {
        lock.lock()
        let route = entries.map(\.url)
        entries.removeAll()
        _bytes = 0
        lock.unlock()
        for url in route { try? FileManager.default.removeItem(at: url) }
    }

    /// Clears the ring — at the end of the session.
    public func removeAll() {
        lock.lock()
        entries.removeAll()
        _bytes = 0
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Clears all rings — at app start, for what a crash left behind.
    public static func sweep(root: URL? = nil) {
        try? FileManager.default.removeItem(at: Self.root(under: root))
    }

    /// How much currently lies on disk, across all rings.
    public static func usage(root: URL? = nil) -> Int64 {
        let folder = Self.root(under: root)
        guard
            let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var sum: Int64 = 0
        for case let url as URL in walker {
            sum += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return sum
    }
}
