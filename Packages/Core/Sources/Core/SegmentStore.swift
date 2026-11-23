import Foundation

/// Holds the finished segments from which AVFoundation is served.
///
/// **A ring buffer and not an archive.** A channel runs for hours; whoever keeps every
/// segment fills the memory in a quarter of an hour at two seconds per piece and a few
/// megabytes. So only a window is kept — enough for the player to jump back when it stalls,
/// and little enough that it goes unnoticed.
///
/// **The header segment is exempt from this** and stays forever: It carries the descriptions
/// of the stream, and without them the decoder cannot start again after any discarding.
public final class SegmentStore: @unchecked Sendable {

    /// How many data segments are kept.
    ///
    /// Twenty at two seconds per piece are forty seconds of look-back — more than any buffer
    /// needs, and for a channel at 17 Mbit/s about 85 megabytes. That is the upper bound that
    /// has to be reckoned with.
    ///
    /// **Since the short pieces, the airtime counts alongside** (2026-09-03): At half a second per
    /// piece, twenty pieces would be ten seconds — too little for the look-back. So whichever is
    /// longer is kept: twenty pieces or ``windowSeconds``.
    public static let windowSize = 20

    /// How much broadcast is kept at least, in seconds.
    public static let windowSeconds: Double = 40

    private let lock = NSLock()
    /// The header segments, one per period — the first is `header.mp4`.
    private var headers: [Data] = []
    /// Number and content, in the order of arrival — whether the piece begins with a keyframe,
    /// and which period it belongs to.
    private var segments: [(index: Int, data: Data, duration: Double, independent: Bool, period: Int)] = []
    private var nextIndex = 0
    /// Counts every change to the catalog — the key of the playlist cache, see
    /// ``playlist(isLive:base:)``.
    private var revision = 0
    private var listCache: (key: ListKey, text: String)?
    /// How often the playlist was actually built — for the checks.
    private(set) var listBuilds = 0
    private let retainsEverything: Bool
    private var complete = false
    /// The sum of all airtime ever cut — for the tally at teardown.
    private var producedSeconds: Double = 0
    /// Siehe ``init(retainsEverything:label:logsProduction:)``.
    private let logsProduction: Bool

    /// The name in the log lines — with the channel, if one is known.
    ///
    /// **Without it two sessions cannot be told apart** (user question 2026-08-15): In the zapping
    /// race two remuxers cut their piece 0 at the same time, and from the trace one could only
    /// guess from the port numbers which line belongs to which channel.
    private let tag: String

    /// - Parameters:
    ///   - retainsEverything: Whether nothing is thrown away.
    ///
    ///     **Only for short, finite streams.** A full-length film remuxed occupies as much as
    ///     the source file — at three gigabytes that is not a possibility but a crash.
    ///     Whoever wants to keep a whole file in one piece must know beforehand that it is
    ///     small.
    ///   - label: The channel or title for the log lines.
    ///   - logsProduction: Whether cut pieces are worth a log line. **Off for throwaway
    ///     stores** (device finding 2026-08-15, eighth evening test): The Matroska session builds
    ///     its own store for each window piece, whose count starts at zero — every one of these
    ///     lines read "piece 0", and the first-and-every-tenth rule therefore fired on EVERY
    ///     piece. Ten lines in two seconds, exactly the flood the rule was built against.
    public init(retainsEverything: Bool = false, label: String? = nil, logsProduction: Bool = true) {
        self.retainsEverything = retainsEverything
        self.logsProduction = logsProduction
        tag = label.map { "Remuxer “\($0)”" } ?? "Remuxer"
    }

    // MARK: - Filling

    /// Accepts a header segment. **The second opens a period** (AP7 · 4): A new writer after
    /// the audio-track switch writes its own header segment, and all pieces after it belong to
    /// it — the playlist tells the player as a break. A repeated header segment without a piece
    /// in between replaces the last one instead of leaving an empty period.
    public func setHeader(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        revision += 1
        if headers.isEmpty || segments.contains(where: { $0.period == headers.count - 1 }) {
            headers.append(data)
        } else {
            headers[headers.count - 1] = data
        }
    }

    /// The running period — that of the youngest header segment.
    public var currentPeriod: Int {
        lock.lock()
        defer { lock.unlock() }
        return max(0, headers.count - 1)
    }

    /// The header segment of a period.
    public func header(period: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return headers.indices.contains(period) ? headers[period] : nil
    }

    /// Takes in a data segment and throws away the oldest when the window is full.
    ///
    /// - Parameter independent: Whether the piece begins with a keyframe. **Default yes**,
    ///   because the system writer can do nothing else. Our own writer also cuts in the middle
    ///   of a group of pictures; then it says so, and the window drops only whole groups of
    ///   pictures at the front — the first piece of the playlist thus always begins with a
    ///   keyframe, and a player that joins there sees no blocky picture.
    @discardableResult
    public func append(_ data: Data, duration: Double, independent: Bool = true) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let index = nextIndex
        nextIndex += 1
        revision += 1
        segments.append((index, data, duration, independent, max(0, headers.count - 1)))
        producedSeconds += duration
        if duration <= 1 { largestPart = max(largestPart, duration) }
        if !retainsEverything { trimWindow() }
        // **The production line — but not for every piece** (requirement 2026-08-15: packets instead
        // of a flood of lines — "a series does not need a thousand lines"). In the third evening
        // test the live remuxer delivered exactly one piece and never another; whether the cutter
        // stalled or the connection did was decided by this line. For that the first piece and
        // every tenth suffice — if production stands, the next line is missing, and the tally at
        // teardown carries the totals anyway.
        if logsProduction, index % 10 == 0 {
            Diagnostics.verbose(
                "\(tag): segment \(index) cut (\(String(format: "%.1f", duration)) s)")
        }
        return index
    }

    /// Drops at the front whatever goes beyond the window — group of pictures by group of
    /// pictures.
    ///
    /// The window is full when it holds more than ``windowSize`` pieces AND more than
    /// ``windowSeconds`` of broadcast. Then it drops up to the next piece that begins with a
    /// keyframe — never less, otherwise a piece that needs its predecessor would stand at the
    /// front, and never more than necessary.
    private func trimWindow() {
        while segments.count > Self.windowSize,
            segments.reduce(0, { $0 + $1.duration }) > Self.windowSeconds
        {
            // The next independent piece after the first — up to there everything belongs to the first
            // group of pictures.
            let next = segments.dropFirst().firstIndex { $0.independent } ?? segments.count
            // **Never empty the whole list.** If no piece carries a keyframe (only a check can build
            // that), the old behaviour stays.
            guard next < segments.count else {
                spill(segments.removeFirst())
                return
            }
            for previous in segments.prefix(next) { spill(previous) }
            segments.removeFirst(next)
        }
    }

    // MARK: - Zeitversatz (AP9)

    /// The disk ring — `nil` means: What falls out of the window is gone.
    private var ring: TimeShiftRing?

    /// Switches on spilling out: What the window no longer holds goes into the ring, and the
    /// playlist keeps listing it — see ``TimeShiftRing``.
    public func enableTimeShift(_ ring: TimeShiftRing) {
        lock.lock()
        defer { lock.unlock() }
        self.ring = ring
        revision += 1
    }

    /// Pieces that have left the window and are on their way into the ring.
    ///
    /// **The disk is not written under the lock** (remuxer check, suspicion 3, 2026-09-27).
    /// ``spill(_:)`` ran out of ``trimWindow()``, i.e. under this lock — and that is held by the
    /// remuxer's writer, which in turn runs on the **one** delivery thread of all channels
    /// (``LiveRemuxSession``, shared URL session with one queue). A piece of several megabytes
    /// to a slow or full disk thus stopped reception of every channel and of the local server,
    /// which serves playlist and pieces from this store. Now a queue of its own writes; until
    /// the piece is in the ring, the playlist lists it from here and serves it from memory.
    private var inFlight: [(index: Int, data: Data, duration: Double, independent: Bool, period: Int)] = []
    private let offloader = DispatchQueue(label: "segmentstore.offload", qos: .utility)

    /// Clears the ring from the disk — **when the session stops and not only in `deinit`**
    /// (player check, V2). After the stop nobody asks for a piece any more; if something held
    /// the session longer, a few hundred megabytes would sit in the cache until then.
    /// Afterwards there is no time offset any more — ``hasTimeShift`` says so. Clearing runs on
    /// the spill queue, behind everything still in flight.
    public func clearTimeShift() {
        lock.lock()
        let previous = ring
        ring = nil
        inFlight.removeAll()
        revision += 1
        lock.unlock()
        // Queued behind the spill: a piece that is still in flight would otherwise land in the ring
        // after clearing and stay on the disk.
        offloader.async { previous?.removeAll() }
    }

    private func spill(_ previous: (index: Int, data: Data, duration: Double, independent: Bool, period: Int))
    {
        guard let ring else { return }
        inFlight.append(previous)
        offloader.async { [weak self] in
            ring.store(
                index: previous.index, data: previous.data, duration: previous.duration,
                independent: previous.independent,
                period: previous.period)
            guard let self else { return }
            lock.lock()
            inFlight.removeAll { $0.index == previous.index }
            revision += 1
            lock.unlock()
        }
    }

    /// Waits until everything spilled is in the ring — for the checks.
    func awaitOffload() { offloader.sync {} }

    /// Pauses or resumes spilling — for the checks that simulate a slow disk.
    func suspendOffload() { offloader.suspend() }
    func resumeOffload() { offloader.resume() }

    /// What stands in the playlist before the window: the ring, behind it what is still in
    /// flight. What the ring already has counts only once. Call only under the lock.
    private func beforeWindow() -> [(index: Int, piece: RemuxPlaylist.Piece)] {
        let ringPieces = (ring?.pieces ?? []).map {
            (index: $0.index, duration: $0.duration, independent: $0.independent, period: $0.period)
        }
        let last = ringPieces.last?.index ?? Int.min
        let behind = inFlight.filter { $0.index > last }.map {
            (index: $0.index, duration: $0.duration, independent: $0.independent, period: $0.period)
        }
        return (ringPieces + behind).map {
            (
                index: $0.index,
                piece: RemuxPlaylist.Piece(
                    duration: $0.duration, independent: $0.independent, period: $0.period)
            )
        }
    }

    /// How much broadcast lies in the ring, in seconds.
    public var timeShiftSeconds: Double { ring?.seconds ?? 0 }
    /// How much the ring occupies on the disk.
    public var timeShiftBytes: Int64 { ring?.bytes ?? 0 }
    public var hasTimeShift: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ring != nil
    }

    /// Says that nothing more is coming — so the playlist gets an end.
    ///
    /// **Only afterwards may `#EXT-X-ENDLIST` appear in the playlist.** Before, it would be a lie
    /// with a visible consequence: The player would take the first two seconds for the whole
    /// film and stop afterwards.
    public func markComplete() {
        lock.lock()
        defer { lock.unlock() }
        complete = true
        revision += 1
    }

    public var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete
    }

    // MARK: - Fragen

    public var headerData: Data? {
        lock.lock()
        defer { lock.unlock() }
        return headers.first
    }

    public func segment(_ index: Int) -> Data? {
        lock.lock()
        let inMemory =
            segments.first { $0.index == index }?.data
            ?? inFlight.first { $0.index == index }?.data
        let ring = self.ring
        lock.unlock()
        return inMemory ?? ring?.data(for: index)
    }

    /// Whether a piece is there — without reading it. For ``waitForSegment(_:timeout:)``, which
    /// until AP72 (2026-10-11) fetched every ring piece completely from the disk just to check
    /// `!= nil`; afterwards the provider read the same file once more.
    public func hasSegment(_ index: Int) -> Bool {
        lock.lock()
        let inMemory = segments.contains { $0.index == index } || inFlight.contains { $0.index == index }
        let ring = self.ring
        lock.unlock()
        return inMemory || ring?.contains(index) == true
    }

    /// Whether there is anything to fetch yet at all.
    ///
    /// **The header alone is not enough.** A playlist without a single segment is formally valid,
    /// and the player accepts it — only to wait silently for content it believes to exist.
    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !headers.isEmpty && !segments.isEmpty
    }

    /// What the playlist depends on — same key, same playlist.
    ///
    /// The ring shortens itself without asking the store; count and first number reveal it.
    struct ListKey: Equatable {
        let revision: Int
        let ringCount: Int?
        let ringFirst: Int?
        let isLive: Bool
        let parts: Bool
        let base: String
    }

    /// The playlist for the current catalog.
    ///
    /// **Only what has changed is built** (AP73, 2026-10-11). The player asks for the playlist at
    /// the rhythm of the target duration, with parts even more often; until then it was rebuilt
    /// every time — under the lock, with `String(format:)` per piece and the whole ring in front.
    /// Now it carries a ``ListKey``; if it matches, the text comes from the cache,
    /// otherwise it is built **outside** the lock.
    public func playlist(isLive: Bool = true, base: String) -> String {
        lock.lock()

        // The largest value so far travels along — the target duration must never decrease,
        // reasoning at ``RemuxPlaylist/build(durations:firstIndex:isLive:targetDuration:base:)``.
        largestDuration = max(largestDuration, Int(ceil(segments.map(\.duration).max() ?? 2)))

        let key = ListKey(
            revision: revision, ringCount: ring?.count, ringFirst: ring?.firstIndex,
            isLive: isLive && !complete, parts: lowLatency && partsAllowed, base: base)
        if let listCache, listCache.key == key {
            lock.unlock()
            return listCache.text
        }

        // **The ring goes first** (AP9): What lies on the disk stands in the playlist before the
        // window — AVPlayer sees minutes instead of seconds and jumps within them by itself.
        let offloaded = beforeWindow()
        let pieces =
            offloaded.map(\.piece)
            + segments.map {
                RemuxPlaylist.Piece(duration: $0.duration, independent: $0.independent, period: $0.period)
            }
        let firstIndex = offloaded.first?.index ?? segments.first?.index ?? 0
        let (targetDurationValue, next, partTargetValue) = (largestDuration, nextIndex, largestPart)
        lock.unlock()

        let text = RemuxPlaylist.build(
            pieces: pieces,
            firstIndex: firstIndex,
            isLive: key.isLive,
            targetDuration: targetDurationValue,
            base: base,
            // Parts only where the writer delivers them — see ``allowParts()``.
            parts: key.parts,
            nextIndex: next,
            partTarget: partTargetValue
        )

        lock.lock()
        listBuilds += 1
        listCache = (key, text)
        lock.unlock()
        return text
    }

    /// The largest part duration ever seen — like ``largestDuration`` it must never decrease.
    /// Capped at one second: What is longer no longer becomes a part (see ``RemuxPlaylist``), and
    /// the promise should not grow for all following parts because of a single giant.
    private var largestPart: Double = RemuxPlaylist.partTarget

    /// Whether the playlist may list parts — see ``allowParts()``.
    private var partsAllowed = false

    /// Whether the playlist offers parts and the blocking reload. The default is the global
    /// switch; ``LiveRemuxSession`` turns it off for channels where AVPlayer has rejected the
    /// parts path (``LowLatencyMemory``).
    public nonisolated(unsafe) var lowLatency = RemuxPlaylist.lowLatency

    /// Allows the playlist to list its pieces as parts.
    ///
    /// **Called by the remuxer when its own writer is at work.** The system writer cuts only at a
    /// keyframe, and listing pieces of ten seconds as "parts" would be a playlist that promises
    /// something it does not keep (`PART-TARGET` is a promise). Not guessed from the pieces: A
    /// channel with one keyframe per half second delivers nothing but independent pieces, and
    /// those are to be parts just the same.
    public func allowParts() {
        lock.lock()
        defer { lock.unlock() }
        partsAllowed = true
        revision += 1
    }

    /// Waits until a piece is there — for the server that holds a request.
    ///
    /// **Polled, not registered:** checking every 20 ms is nothing on the device itself, and it
    /// spares the bookkeeping of waiting callers that would have to be cleaned up when the store
    /// is torn down.
    ///
    /// - Returns: Whether the piece appeared within the deadline.
    @discardableResult
    public func waitForSegment(_ index: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasSegment(index) { return true }
            if isComplete || index < producedCount { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return hasSegment(index)
    }

    /// The number the next piece gets.
    public var upcomingIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    /// The largest segment duration ever seen, rounded up.
    private var largestDuration = 0

    /// How much broadcast is currently present, in seconds.
    ///
    /// **The number that matters at startup — not the count.** How long a piece becomes is not
    /// determined by ``FragmentWriter/segmentDuration`` but by the channel: Cutting is done at
    /// the keyframe, and whoever sets one every five seconds delivers pieces of five seconds,
    /// whatever is set here. Rechecked on the Telve 1 HEVC recording (2026-08-11): 10 s, then 5 s,
    /// 5 s, 5 s … — three pieces there are **fifteen seconds** of buffer, and for exactly that
    /// long the viewer saw nothing.
    public var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return segments.reduce(0) { $0 + $1.duration }
    }

    /// How many segments are currently present — for diagnosis.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return segments.count
    }

    /// How many pieces were ever cut — including those long since discarded.
    public var producedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    /// The sum of all airtime ever cut, in seconds.
    public var producedTotalSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return producedSeconds
    }
}
