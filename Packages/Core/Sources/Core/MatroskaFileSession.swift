import AVFoundation
import CoreMedia
import Foundation

/// Turns an MKV file on the server into an address for the player.
///
/// **The counterpart to ``LiveRemuxSession``, and the other half of P19.**
/// There a stream without an end, here a file with one — and with the ability
/// to seek, which a live channel does not have at all.
///
/// ## Why the pieces are created on demand
///
/// A TV episode is half a gigabyte, a film three. Remuxing it in one go
/// and keeping the segments would mean holding all of it in the memory
/// of a TV — not a bottleneck but a crash. So
/// **beforehand it only reads where things are** (``MatroskaIndex``), and a piece is only
/// built when the player asks for it.
///
/// **And that is why seeking works without any extra effort.** Whoever jumps into the
/// middle asks for piece 412 like for any other; the file does not have to be
/// read from the start for that.
///
/// ## The three things that must stay the same across all pieces
///
/// **The head.** It is built **once** — at the first piece — and then delivered for
/// all of them. That is not thrift but necessity: two writers
/// do **not** produce the same head. Ten bytes differ, the
/// creation times in `mvhd` and `tkhd`; `AVAssetWriter` stamps them with the
/// clock. The pieces themselves carry no time of day, so they fit under any
/// head — but whoever delivers a new head for each piece has a bug
/// that occurs exactly once per minute.
///
/// **The shift.** It is calibrated at the first piece and then
/// held fixed — recalibrating per piece would produce a jump at every boundary.
///
/// **The timing.** Every piece carries its real start time; otherwise
/// each would claim to begin at zero.
public final class MatroskaFileSession: @unchecked Sendable {

    public enum Failure: Error, Equatable {
        case notMatroska
        case noSeekIndex
        case noVideoTrack
        case videoNotHardwareDecodable(String)
        case cannotProduceFirstPiece
    }

    /// How much of the beginning is read to get the head.
    ///
    /// **256 kilobytes suffice for everything that was measured**, and for
    /// a three-gigabyte film they are a ten-thousandth. If it still is not enough —
    /// a file with very many chapters or an embedded cover image —,
    /// it follows up once instead of giving up.
    static let headSize = 256 << 10
    static let largeHeadSize = 4 << 20

    /// How many finished pieces at most stay in memory — and how many
    /// bytes.
    ///
    /// **Six were too few once read-ahead was added** (F-022, 2026-09-04,
    /// S latple Micutror): eight pieces ahead with four builds at the same time refilled
    /// a store of six from the front, and the oldest entry was evicted — that
    /// was regularly exactly the piece the player demanded next.
    /// It fetched it again, the read-ahead rebuilt and evicted again: piece
    /// 481 fetched seven times, 482 eight times, and 7.5 MB took 9.7 s from the
    /// own server because three requests at the same time pulled on the same disk.
    /// The store must hold what the read-ahead builds: depth plus builds plus
    /// two behind (``readAheadDepth``, ``readAheadWorkers``).
    ///
    /// The byte limit is the second barrier: a UHD piece can weigh 60 MB,
    /// and sixteen of those fit in no Apple TV process. Who gets
    /// evicted is defined in ``evict(_:um:atMost:bytes:)`` —
    /// never the piece the player needs right now.
    static let bufferPieces = 16
    static let bufferBytes = 192 << 20

    /// From what gap at a seam the audio is really missing.
    ///
    /// **Forty milliseconds** — one audio frame. Below that it is the normal
    /// interleaving of two tracks, above it the gap adds up from seam to
    /// seam into the sync offset (Blibiagraik hunt, 2026-08-16).
    static let seamGapThreshold = 0.04

    private let source: ByteRangeSource
    private let audioLanguage: String?
    /// Readable within the module, so checks fetch pieces the same way as AVPlayer.
    let server: LocalMediaServer

    private let lock = NSLock()
    private var header = Matroska.Header()

    /// The text subtitles that accumulate during remuxing — see ``SubtitleCollector``.
    public let subtitles = SubtitleCollector()

    /// The subtitle tracks of the file, once its head has been read.
    public var subtitleTracks: [Matroska.Track] {
        lock.lock()
        defer { lock.unlock() }
        return header.subtitleTracks
    }
    private var pieces: [MatroskaIndex.Piece] = []
    /// The end of the file — the limit for the trailing read of the last piece.
    private var fileEnd = 0
    /// In what steps a piece reads into the next cluster.
    ///
    /// **The trailing read ends at the keyframe, not after a fixed number of
    /// bytes** (F-023, 2026-09-05). There used to be a limit of 768 KB here, and the
    /// assumption behind it was that a cluster begins with the keyframe
    /// and at most a few B-frames lie before it. "S latple Micutror" has
    /// clusters of 1.5 MB that begin somewhere in the group of pictures; the
    /// keyframe lay more than a megabyte deep in the cluster, the trailing read
    /// stopped before it — and everything in between went into no piece, because the
    /// next one discards up to its keyframe. The file probe showed
    /// holes of 0.2 to 0.5 s in picture **and** audio at three of four seams;
    /// the diagnostics had attributed them to "the source". The source is
    /// gapless (ffprobe on the server).
    ///
    /// So it reads in steps until the keyframe is there —
    /// at most to the end of the cluster, because the seek table guarantees
    /// that it lies within. The step size is adjustable so the
    /// check can force the path through several steps.
    static let trailingStepBytes = 768 << 10
    var trailingStep = MatroskaFileSession.trailingStepBytes

    /// Who writes the pieces — default is the custom writer, see
    /// ``MatroskaRemuxer/Options/writer``. Switchable for the probes that
    /// compare both under the same conditions.
    public var writer: TransportRemuxer.ChunkWriter = .own
    /// The start of the file up to the first cluster — the head for every piece.
    private var preamble = Data()
    private var initialization: Data?
    private var delay: Int64 = 0
    /// The time grid of the file, decided at the first piece — see
    /// ``MatroskaRemuxer/Options/raster``.
    private var raster: TimeGrid?
    private var gridFixed = false
    private var cache: [(index: Int, data: Data)] = []

    /// What has already been reported about this file.
    ///
    /// **Per file, not per piece** (check agent 2026-08-24): ``produce(_:delay:)``
    /// runs for EVERY piece fetched, and for "Piotfrodaus 8" this put
    /// identical lines by the dozen into the recording — 282 of 5523
    /// lines came from this one function.
    ///
    /// The lock is by **kind of finding** and not by piece: what does not
    /// change appears once; what flips in the middle of the film
    /// still gets its line. A lock "only at the first piece" would have
    /// swallowed exactly the Blupriatio Gufaidia bug of 2026-08-23.
    private var reports = FileReportGate()

    /// What becomes of the audio balance of a piece.
    enum AudioMessage: Equatable {
        case none
        /// Only behind the diagnostics switch.
        case row(String)
        /// In the error trace — which is what someone reporting a silent film sees.
        case problem(String)
    }

    /// **The whole chain from the balance to the error trace, as a calculation**
    /// (counter-check 2026-09-24).
    ///
    /// **What was checked was the calculation, not the connection.** ``AudioTally`` judged
    /// correctly, but whether its verdict reaches the error trace stood as an `if` in the holder —
    /// and that is a session with its own server and thread. A check that would stay green
    /// if the message were removed here would be worthless; that is why the
    /// decision lives here, and the holder only says what it says.
    ///
    /// **`claim` comes in and is not rebuilt**: it is the lock that
    /// makes sure two pieces served at the same time do not both report.
    static func audioMessage(
        _ balance: AudioTally?, piece: Int, claim: (FileReportGate.Finding) -> Bool
    ) -> AudioMessage {
        guard let balance else { return .none }
        if let finding = balance.silenceFinding, claim(.audioSilent) {
            return .problem("Piece \(piece): \(finding)")
        }
        return .row("Piece \(piece): \(balance.row)")
    }

    /// Which findings of a file have already been reported.
    ///
    /// As its own type, so the rule can be tested without a film.
    struct FileReportGate {
        enum Finding: Hashable {
            case timelineEven, timelineDuplicates, timelineHistogram
            case reorderClean, reorderCorrected
            case seam, seamGap
            case trailingWithoutKeyframe
            case audioSilent
            /// The writer of a piece has failed (stall stage 5).
            case writerDead
        }

        private var done: Set<Finding> = []

        /// `true` the first time, `false` afterwards.
        mutating func claim(_ finding: Finding) -> Bool { done.insert(finding).inserted }

        /// Whether a finding has already been reported — without claiming it.
        func hasReported(_ finding: Finding) -> Bool { done.contains(finding) }
    }

    /// **The writer failure of a piece, as a calculation** (stall stage 5,
    /// 2026-09-25) — the same shape as ``audioMessage(_:piece:claim:)``.
    ///
    /// Until now nobody read ``MatroskaRemuxer/failure``: if the writer failed,
    /// the piece came back empty, the player got a rejection, and the trace
    /// at best said "the first piece is not created" — without a reason. Once per
    /// file, not per piece: a writer that fails on this film fails on
    /// each of its pieces.
    ///
    /// - Returns: The line for the error trace, or `nil` if there is nothing to say
    ///   or it has already been said.
    static func writerMessage(
        _ error: Error?, piece: Int, claim: (FileReportGate.Finding) -> Bool
    ) -> String? {
        guard let error, claim(.writerDead) else { return nil }
        return "Piece \(piece): the writer failed (\(error)) — "
            + "the piece stays empty, the player gets nothing"
    }

    /// Whether a finding for this file is already in the trace — for the checks.
    func hasReported(_ finding: FileReportGate.Finding) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reports.hasReported(finding)
    }

    /// A writer build in place of the configured one — see
    /// ``MatroskaRemuxer/Options/writerFactory``. For the checks only.
    var writerFactory: (@Sendable (CMFormatDescription, CMFormatDescription?) throws -> any SampleSink)?

    public init(source: ByteRangeSource, audioLanguage: String? = nil) throws {
        self.source = source
        self.audioLanguage = audioLanguage
        server = try LocalMediaServer()

        server.provider = { [weak self] name in
            guard let self else { return nil }
            switch name {
            case "media.m3u8":
                return (Data(self.playlist().utf8), "application/vnd.apple.mpegurl")
            case RemuxPlaylist.headerName:
                guard let data = self.initializationSegment else { return nil }
                return (data, "video/mp4")
            default:
                guard case .segment(let index)? = RemuxPlaylist.request(forName: name),
                    let data = self.piece(index)
                else { return nil }
                return (data, "video/mp4")
            }
        }
    }

    /// What was in the track table — only filled after ``start()``.
    public var trackHeader: Matroska.Header {
        lock.lock()
        defer { lock.unlock() }
        return header
    }

    /// How much of the seek table is read at most — see ``start()``.
    static let cuesMaximum = 4 << 20
    /// The first grab at the seek table: enough for the element head and the table of
    /// most films (30–300 KB for two hours).
    static let cuesFirstGrab = 64 << 10

    /// **The seek table at its size, not a blanket 4 MB** (AP72, 2026-10-11). Until then
    /// 4 MB always came from `cues` on — at the end of the file the file length cut it off, but if the cues
    /// lay **before** the clusters (`-cues_to_front`, mkvmerge; case in ``seekIndex``), that was
    /// 4 MB of picture data for nothing, three seconds of startup over 10 Mbit/s. Now: first
    /// ``cuesFirstGrab``, size from the element head (``Matroska/element(in:at:)``), and
    /// fetch the remainder exactly. Without a readable size the old cap stays.
    func readCues(from location: Int, fileEnd: Int) async throws -> Data {
        let started = Date()
        let firstGrabEnd = min(location + Self.cuesFirstGrab, fileEnd)
        var data = try await source.bytes(in: location..<firstGrabEnd)
        if let element = Matroska.element(in: data, at: 0), element.id == Matroska.ID.cues,
            let total = element.totalSize
        {
            let end = min(location + total, fileEnd)
            if end > location + data.count {
                data.append(try await source.bytes(in: (location + data.count)..<end))
            }
        } else if data.count == Self.cuesFirstGrab {
            let end = min(location + Self.cuesMaximum, fileEnd)
            if end > location + data.count {
                data.append(try await source.bytes(in: (location + data.count)..<end))
            }
        }
        Diagnostics.playbackStep(
            "Cues: \(data.count >> 10) KB in \(Int(Date().timeIntervalSince(started) * 1000)) ms",
            since: nil)
        return data
    }

    /// Where the index came from — for diagnostics and checks.
    public enum IndexOrigin: Sendable, Equatable {
        case cues
        case cache
        case walk
    }

    public private(set) var indexOrigin: IndexOrigin?

    /// How many pieces the plan has — for checks.
    var chunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pieces.count
    }

    /// For probes: per built piece index, bytes, fetch time and remux time.
    public var onProduced: ((Int, Int, TimeInterval, TimeInterval) -> Void)?

    /// Whoever wants to use the cache for indexes found by walking sets
    /// a key provider before ``start()`` — it receives the file length
    /// (``MatroskaIndexCache/key(for:size:)``).
    public var indexCacheKey: ((Int) -> String)?

    /// The seek index: from the cues — or, if the file has none
    /// or they lie past the end of the file (truncated file, F-008),
    /// from the cache or from the walk through the clusters.
    /// Also returned is the position where the index ends: the last piece
    /// extends up to there.
    private func seekIndex(head: Data, size: Int, track: Int) async throws -> (MatroskaIndex, Int) {
        var found = MatroskaIndex.locateCues(inHead: head)
        // **One level of indirection** (F-002): if the first SeekHead does not name the cues but
        // a second SeekHead, that one is fetched — a request of a few kilobytes instead of
        // a walk through all clusters. Not deeper, so a cycle does not circle.
        if found == nil, let reference = MatroskaIndex.locateSeekHeadReference(inHead: head),
            reference.seekHead < size
        {
            let end = min(reference.seekHead + Self.seekHeadMaximum, size)
            if let second = try? await source.bytes(in: reference.seekHead..<end),
                let position = MatroskaIndex.cuesPosition(inSeekHeadElement: second),
                let cues = NetNumber.sum(reference.segmentStart, position)
            {
                Diagnostics.playbackStep("Cues found via a second SeekHead", since: nil)
                found = (reference.segmentStart, cues)
            }
        }
        if let located = found, located.cues < size {
            let cues = try await readCues(from: located.cues, fileEnd: size)
            let parsed = MatroskaIndex.parse(
                cues: cues, segmentStart: located.segmentStart, track: track)
            if let last = parsed.entries.map(\.position).max() {
                indexOrigin = .cues
                return (
                    parsed, Self.directoryEnd(cues: located.cues, lastPosition: last, fileEnd: size)
                )
            }
        }

        guard let firstCluster = MatroskaIndex.locateFirstCluster(inHead: head) else {
            throw Failure.noSeekIndex
        }
        let key = indexCacheKey?(size)
        if let key, let cached = MatroskaIndexCache.load(key: key) {
            // **The knowledge comes along, not only the positions** (AP31, 2026-09-23). Until
            // now the cache carried only the list; whether its clusters are
            // keyframes stayed behind on the first attempt. The second then took
            // them for keyframes, made the pieces short — and a piece that begins in the middle of
            // a group of pictures shows no picture. Reported as `F-024`.
            if !cached.keyframesKnown { walkedWithoutKeyframes = true }
            // **As an anomaly and not as a step**, when the pieces have to become long:
            // exactly this line was missing from the submitted report, because steps
            // are only recorded with "record verbosely" — and without it there was
            // no way to see where the index came from.
            if cached.keyframesKnown {
                Diagnostics.playbackStep(
                    "Seek index from the cache: \(cached.entries.count) clusters",
                    since: nil)
            } else {
                Diagnostics.playbackProblem(
                    "Seek index from the cache: \(cached.entries.count) clusters, "
                        + "none with a keyframe — the pieces get long",
                    since: nil)
            }
            indexOrigin = .cache
            return (MatroskaIndex(entries: cached.entries), size)
        }

        // **As an anomaly**, because the walk can take minutes for a large file —
        // and without this line a report would only show "no picture after 5 s" (F-025).
        Diagnostics.playbackProblem(
            "File without a seek index — walking the clusters (\(size / (1 << 20)) MB); "
                + "the walk runs to the end even if playback is aborted",
            since: nil)
        // On its own, narrow line (``HTTPByteRangeSource/runSession``).
        let sourceItem: any ByteRangeSource = (source as? HTTPByteRangeSource)?.forPass() ?? source
        let (heads, duration) = try await MatroskaGearWorkshop.run(
            key: key,
            work: {
                try await MatroskaClusterWalk.index(
                    source: sourceItem, firstCluster: firstCluster, fileSize: size, videoTrack: track,
                    workers: MatroskaClusterWalk.gearConnections)
            },
            persist: { heads in
                guard let key, !heads.isEmpty else { return }
                let (walked, keyed) = MatroskaClusterWalk.entries(from: heads)
                MatroskaIndexCache.save(walked, keyframesKnown: keyed, key: key)
            })
        guard !heads.isEmpty else {
            Diagnostics.playbackProblem(
                "Cluster walk without a result after \(duration) ms — clusters without a length field?",
                since: nil)
            throw Failure.noSeekIndex
        }
        let (walked, keyed) = MatroskaClusterWalk.entries(from: heads)
        // **The case without keyframes is an anomaly and not a step.** It
        // decides the piece length and thereby whether a picture comes at all;
        // in report `F-024` it was missing because steps only run along with "record verbosely"
        // — and exactly it would have been the answer.
        if keyed {
            Diagnostics.playbackStep(
                "Seek index from \(heads.count) clusters in \(duration) ms — "
                    + "\(walked.count) start with a keyframe",
                since: nil)
        } else {
            Diagnostics.playbackProblem(
                "Seek index from \(heads.count) clusters in \(duration) ms — "
                    + "none starts with a keyframe, pieces get long",
                since: nil)
        }
        if !keyed { walkedWithoutKeyframes = true }
        indexOrigin = .walk
        return (MatroskaIndex(entries: walked), size)
    }

    /// Where the last piece ends when the seek table provides the index.
    ///
    /// **The cues behind the last cluster are the rule, not a requirement**
    /// (remuxer check B1, 2026-09-27). ffmpeg with `-cues_to_front 1` and mkvmerge on
    /// request put them **before** the clusters. Here the position of the
    /// cues was taken as the end without distinction — the last piece became `position..<cues` with an end before
    /// the start, and startup halted the app. If the cues do not lie behind the last
    /// entry, the last piece extends to the end of the file.
    static func directoryEnd(cues: Int, lastPosition: Int, fileEnd: Int) -> Int {
        cues > lastPosition ? cues : fileEnd
    }

    /// True if the walk found no clusters with a keyframe: then
    /// the pieces become long enough that each contains a keyframe.
    private var walkedWithoutKeyframes = false

    /// This much is read for a second SeekHead — it names a handful of positions.
    static let seekHeadMaximum = 16 << 10

    /// Piece length: that of the writer — or ten seconds if the pieces begin at
    /// arbitrary clusters and the start up to the keyframe
    /// is discarded.
    private var pieceTargetSeconds: Double {
        walkedWithoutKeyframes ? 10 : FragmentWriter.segmentDuration.seconds
    }

    /// Into how many pieces the file splits.
    public var pieceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pieces.count
    }

    /// How long the file really is according to its index, in seconds —
    /// the sum of the piece durations.
    ///
    /// **Not the runtime from the head.** A truncated file
    /// (Bringrarn Piosiaspeit Slausnonspel, F-008: 6.46 of 11.7 GB) promises the
    /// full length in its head but has only the pieces up to the cut. Whoever assumes a
    /// start position beyond that starts into nothing — the player reports
    /// the end after a second (F-026, 2026-09-05).
    /// Where a truncated file ends and what its head promises — `nil`
    /// if index and head match. The player shows it to the
    /// viewer (F-027: "keeps crashing" — it was the end of the file).
    public private(set) var truncated: (end: Double, promised: Double)?

    public var totalDuration: Double {
        lock.lock()
        defer { lock.unlock() }
        return pieces.reduce(0) { $0 + $1.duration }
    }

    public var assetURL: URL {
        URL(string: RemuxPlaylist.address("media.m3u8", base: base))!
    }

    public var base: String { "http://127.0.0.1:\(server.port)" }

    /// Stops the session — the server, the read-ahead and everything that is being built.
    ///
    /// **Until 2026-09-27 `stop()` only stopped the server** (remuxer check B8).
    /// The read-ahead chain held on to the session itself and kept scheduling: after
    /// leaving a film, up to ``readAheadDepth`` piece requests of
    /// several megabytes kept running. With an Xtream account with **one** connection this
    /// occupies exactly the line the next title needs.
    public func stop() {
        lock.lock()
        halted = true
        let pending = Array(running.values)
        running.removeAll()
        cache.removeAll()
        lock.unlock()
        for task in pending { task.cancel() }
        server.stop()
    }

    /// Whether ``stop()`` was called — after that no piece is created any more.
    private var halted = false

    deinit { server.stop() }

    // MARK: - Aufsetzen

    /// Reads head and seek table and returns the address for the `AVURLAsset`.
    @discardableResult
    public func start() async throws -> URL {
        let size = try await source.length()

        var head = try await source.bytes(in: 0..<min(Self.headSize, size))
        var reader = MatroskaReader()
        _ = reader.read(head)
        if !reader.isHeaderComplete, size > Self.headSize {
            // Follow up once: chapters and embedded cover images can push the
            // head beyond the usual size.
            head = try await source.bytes(in: 0..<min(Self.largeHeadSize, size))
            reader = MatroskaReader()
            _ = reader.read(head)
        }
        guard !reader.header.tracks.isEmpty else { throw Failure.notMatroska }

        guard let video = reader.header.video else { throw Failure.noVideoTrack }
        guard video.isVideoHardwareDecodable else {
            throw Failure.videoNotHardwareDecodable(video.codecID)
        }

        // **With an upper limit** (AP7 · L8, expert review 2026-08-24): when reading the
        // cues this used to say `located.cues..<size` — up to the **end of the file**. For
        // a file whose seek table lies **before** the clusters (mkvmerge
        // puts it there on request), startup thus loaded practically the
        // whole film before the first picture appeared. Four megabytes go a long way:
        // a seek point weighs about 20 bytes, a two-hour film with 1440
        // points thus a good 30 kilobytes — see ``seekIndex(head:size:track:)``.
        //
        // **Without cues it is no longer over** (F-008, 2026-09-04): if they are missing or lie
        // past the end of the file, the walk through the clusters provides the
        // index (``MatroskaClusterWalk``).
        let (index, indexEnd) = try await seekIndex(head: head, size: size, track: video.number)
        guard let first = index.entries.first else { throw Failure.noSeekIndex }
        if first.position > head.count {
            head = try await source.bytes(in: 0..<min(first.position, size))
        }

        let seconds = reader.header.duration.map {
            $0 * Double(reader.header.timestampScale) / Double(NSEC_PER_SEC)
        }.flatMap { $0.isFinite ? $0 : nil }
        // **The end is determined by the index, not the head** (F-028,
        // 2026-09-05): for a truncated file the head promises the
        // full runtime (Bringrarn Piosiaspeit Slausnonspel: 7593 s), the index from the
        // walk through the clusters ends at 55 %. The last piece got the
        // difference as its duration, the session considered the file complete,
        // the start position at the cut counted as valid — and the player hit
        // the real end after a second. Without a seek table the head is
        // a claim; then the last cluster plus an ordinary
        // interval applies.
        let honestEnd = Self.honestEnd(
            entries: index.entries, timestampScale: reader.header.timestampScale)
        let total: Double?
        if indexOrigin == .cues {
            // **Cues without `Duration` in the head** (remuxer check, finding 4, 2026-09-27):
            // here it only said `total = seconds` — if the file names no `Duration`,
            // `seconds` is `nil`, `index.pieces(...)` falls back to `max(0.001, …)`, and the
            // last piece got a duration of 0.001 s instead of its real length. As
            // with the walk through the clusters (``.walk``) and the index cache
            // (``.cache``), the same ``honestEnd`` estimate now steps in when the head
            // is silent.
            total = seconds ?? honestEnd
        } else {
            total = honestEnd
            if let seconds, let honestEnd, seconds - honestEnd > 60 {
                truncated = (honestEnd, seconds)
                Diagnostics.playbackProblem(
                    "File truncated: the header promises \(Int(seconds)) s, the index "
                        + "ends at \(Int(honestEnd)) s — playback ends there",
                    since: nil)
            }
        }
        let plan = index.pieces(
            targetDuration: pieceTargetSeconds,
            timestampScale: reader.header.timestampScale,
            // The seek table lies behind the last cluster; the last piece
            // ends there and not at the end of the file. Without a seek table the
            // end of the file is the limit.
            fileSize: indexEnd,
            totalDuration: total
        )
        guard !plan.isEmpty else { throw Failure.noSeekIndex }

        install(
            header: reader.header, pieces: plan,
            preamble: head.subdata(in: 0..<min(first.position, head.count)))

        // **The first piece is built immediately**, for two reasons: it
        // supplies the head that all further ones share, and it calibrates the
        // shift that applies to the whole film.
        // **The grid from the seek table**, before the first piece is created —
        // see ``TimeGrid/detect(marks:scale:)``. With the first piece at the
        // start of the file it could not be recognised, and afterwards "none"
        // would be locked in.
        fixGrid(
            TimeGrid.detect(marks: plan.map(\.start), scale: reader.header.timestampScale))
        guard var opening = try await produce(plan[0], delay: nil) else {
            throw Failure.cannotProduceFirstPiece
        }
        // **No grid from the table and none from the file?** Then the
        // step from the marks of the first piece (regression line) — and the
        // first piece once more, so it carries the same drift as all
        // further ones. It is the smallest of the file; the second build costs
        // a few dozen milliseconds.
        if gridChoice().0 == nil, opening.raster == nil,
            let estimated = TimeGrid.estimate(
                marks: opening.frameMarks, scale: reader.header.timestampScale)
        {
            fixGrid(estimated, origin: "from the marks of the first piece")
            if let retry = try await produce(plan[0], delay: nil) { opening = retry }
        }
        install(opening: opening)

        try await server.start()
        return assetURL
    }

    // MARK: - Ausliefern

    private var initializationSegment: Data? {
        lock.lock()
        defer { lock.unlock() }
        return initialization
    }

    private func playlist() -> String {
        lock.lock()
        let durations = pieces.map(\.duration)
        lock.unlock()
        return RemuxPlaylist.build(durations: durations, firstIndex: 0, isLive: false, base: base)
    }

    /// Returns a piece — from the store or freshly built.
    ///
    /// **Blocking here is deliberate.** The server runs on its own
    /// thread, and the player is waiting for the response anyway; there is no
    /// "coming right up" in HTTP.
    private func piece(_ index: Int) -> Data? {
        lock.lock()
        if halted {
            lock.unlock()
            return nil
        }
        if let found = cache.first(where: { $0.index == index })?.data {
            // **A hit also kicks off the read-ahead** (AP72, 2026-10-11): piece 0
            // is always in the store after ``start()``, and until now this path produced
            // no read-ahead — piece 1 was only built on request, blocking, in the middle of
            // startup. Now its build runs as soon as the player fetches piece 0.
            lastRequested = index
            lock.unlock()
            readAhead(from: index + 1)
            return found
        }
        guard index >= 0, index < pieces.count else {
            lock.unlock()
            return nil
        }
        let wanted = pieces[index]
        let known = delay
        let inFlight = running[index]
        lastRequested = index
        // **A seek invalidates what is being built for the old position**
        // (playback probe 2026-09-05: after the jump to 1900 s the chain kept building
        // pieces 2 to 36 from the start of the file, 229 MB in one
        // minute, and the player starved at piece 511). What lies outside the
        // window around the new position is cancelled; the request
        // releases the line.
        for (number, task) in running
        where number < index - 1 || number > index + Self.readAheadDepth {
            task.cancel()
            running[number] = nil
        }
        lock.unlock()

        // **If the read-ahead is currently running for this piece, it waits** —
        // it does not build a second time (probe 2026-09-04).
        if let inFlight {
            let wait = DispatchGroup()
            wait.enter()
            let fetcher = Task {
                defer { wait.leave() }; _ = await inFlight.value
            }
            let timedOut = wait.wait(timeout: .now() + pieceDeadline) == .timedOut
            if timedOut { fetcher.cancel() }
            lock.lock()
            let found = cache.first(where: { $0.index == index })?.data
            lock.unlock()
            if let found {
                readAhead(from: index + 1)
                return found
            }
            // **The running build is reused, not duplicated**
            // (remuxer check, finding 5, 2026-09-27): there was no return here — after
            // the wait period the flow below fell into a second, independent build with
            // its own full deadline. Two builds ran for the same piece, and the
            // wait time doubled to 40 instead of 20 s. The read-ahead build keeps running in the
            // background — ``readAhead(from:)`` puts its result into the
            // store itself once it is finished —, so withdrawing here costs only this one
            // request, no second build.
            if timedOut {
                Diagnostics.playbackProblem(
                    "Piece \(index) not ready from read-ahead after \(Int(pieceDeadline)) s — "
                        + "aborted, the build keeps running in the background",
                    since: nil)
                return nil
            }
        }

        let outcome = Outcome()
        let group = DispatchGroup()
        group.enter()
        let task = Task { [weak self] in
            defer { group.leave() }
            outcome.data = try? await self?.produce(wanted, delay: known)?.segment
        }
        // **With a deadline** (AP6 · Q8, expert review 2026-08-24). There was a
        // `group.wait()` without a limit here — on the **only** queue of the
        // local server. A hanging range request thus froze it
        // for as long as the URL session's timeout runs: up to two minutes, during
        // which the player gets not a single piece and playback
        // stands still without an error message.
        //
        // The deadline is calculated generously and is still finite: three attempts
        // of a range request including pauses are well below it
        // (``HTTPByteRangeSource``), and whatever takes longer no longer arrives.
        if group.wait(timeout: .now() + pieceDeadline) == .timedOut {
            task.cancel()
            Diagnostics.playbackProblem(
                "Piece \(index) not built after \(Int(pieceDeadline)) s — aborted, "
                    + "so the local server keeps serving",
                since: nil)
            return nil
        }

        guard let result = outcome.data else { return nil }
        lock.lock()
        remember(index: index, data: result)
        lock.unlock()
        // **The next piece in advance** (AP7 · L8): a piece was only created
        // on demand, and fetching and remuxing ran one after the other in it
        // instead of overlapping. The player asks for the pieces in order;
        // which one comes next is therefore known.
        //
        // **Exactly one**, and only if it is not there yet: two would be
        // a second range request against the same remote end, and the
        // one-connection rule applies here too. The result lands in the same
        // store the next request draws from — and if it is never
        // requested (the viewer seeks), it costs one request and
        // nothing else.
        readAhead(from: index + 1)
        return result
    }

    /// Builds a piece in the background so it is already there on the next request.
    /// Builds the next pieces in the background — up to ``readAheadDepth`` pieces
    /// ahead, with up to ``readAheadWorkers`` builds at the same time.
    ///
    /// **Until 2026-09-04 nothing ran here after the first piece**: the
    /// check "is still running" asked `isCancelled` of a finished task — that
    /// is never cancelled, so it "ran" forever, and every further piece came
    /// only on request. Hence the dropouts in the first seconds after
    /// joining (F-029: S latple Micutror, Bringrarn Piosiaspeit Slausnonspel).
    /// The piece most recently demanded by the player — the read-ahead measures
    /// its distance from that, not from the most recently finished piece.
    private var lastRequested = 0

    private func readAhead(from start: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !halted else { return }
        // **Bound to the player's position** (F-030: after joining
        // 27 pieces in ten seconds, with duplicate builds — every finished task
        // appended four more to its own end, and the chain ran away from the
        // player until server and processor were full and the picture
        // stood still while the audio kept running from the store).
        // **And the chain hangs on the player, not on its own end.**
        // Every finished build appended the next piece to itself —
        // after a jump forward it thus ran behind the player
        // and still stayed "under the limit", because the limit only applied
        // upward. Only what lies before the most recently demanded piece is built;
        // what was begun behind it ends with its build.
        let limit = lastRequested + Self.readAheadDepth
        var index = max(start, lastRequested + 1)
        var planned = 0
        // What the store already weighs, including what is currently being built — nothing
        // beyond ``bufferBytes`` is started, otherwise the
        // read-ahead evicts what it has just built.
        var taken =
            cache.reduce(0) { $0 + $1.data.count }
            + running.keys.reduce(0) { $0 + (pieces.indices.contains($1) ? pieces[$1].range.count : 0) }
        while index < pieces.count, index <= limit,
            running.count < max(1, readAheadWorkers)
        {
            let alreadyThere = cache.contains { $0.index == index } || running[index] != nil
            if !alreadyThere {
                let wanted = pieces[index]
                guard taken == 0 || taken + wanted.range.count <= Self.bufferBytes else { break }
                taken += wanted.range.count
                let known = delay
                let number = index
                running[number] = Task { [weak self] in
                    guard let self else { return nil }
                    let data = try? await produce(wanted, delay: known)?.segment
                    if let data { memorize(index: number, data: data) }
                    forget(number)
                    // And the next one after it, as long as the store is not sufficient.
                    readAhead(from: number + 1)
                    return data
                }
                planned += 1
            }
            index += 1
        }
    }

    /// The congestion report of the file remuxer: what is in the store, what is being
    /// built, what the player demanded last.
    public var state: String {
        lock.lock()
        defer { lock.unlock() }
        let cached = cache.map(\.index).sorted()
        let build = running.keys.sorted()
        return "Stock pieces \(cached), building \(build), last requested \(lastRequested) of \(pieces.count)"
    }

    /// How many pieces are built ahead of the player.
    /// F-031: during the congestion exactly the piece was missing that had been hanging in the
    /// request for four seconds — the server answers slowly in spikes, not narrowly.
    /// Eight ahead with four builds at the same time cover a four-second spike.
    static let readAheadDepth = 8
    /// How many of them are created at the same time.
    ///
    /// **One** (playback probe 2026-09-05). Until then three, before that four — and
    /// the server's "spikes" that were supposed to be covered by it came
    /// from exactly this parallelism: the media server reads from a
    /// hard disk (36–43 MB/s in one go, measured with `dd`), and three
    /// range requests at three positions make the head jump between
    /// them. A 3 MB piece then took 26 s, while a single
    /// request of 8 MB came in 0.4 s. The pieces of a file lie
    /// one behind the other; one worker reads them in the order of the disk,
    /// and eight pieces of depth at two and a half seconds per piece are twenty
    /// seconds of store. If the player demands a piece that is not currently
    /// being built, ``piece(_:)`` builds it alongside — at most two requests at the same time.
    static let readAheadWorkersDefault = 1
    /// Adjustable for the probes that measure the difference.
    public var readAheadWorkers = MatroskaFileSession.readAheadWorkersDefault

    private var running: [Int: Task<Data?, Never>] = [:]

    private func forget(_ number: Int) {
        lock.lock()
        running[number] = nil
        lock.unlock()
    }

    /// Puts a piece into the store under lock — for the read-ahead, which does it from
    /// within a task.
    private func memorize(index: Int, data: Data) {
        lock.lock()
        if !halted { remember(index: index, data: data) }
        lock.unlock()
    }

    /// The default for ``pieceDeadline``.
    static let pieceDeadlineDefault: TimeInterval = 20

    /// How long the local server waits for a piece.
    ///
    /// See the waiting spot in ``piece(_:)`` — it holds the server's only
    /// queue, and without a deadline it holds it for as long as it likes.
    ///
    /// **A property of the session, not of the type** (remuxer check, finding 5,
    /// 2026-09-27) — like ``readAheadWorkers``: a check sets it small on its
    /// own session so a timeout does not cost twenty real
    /// seconds, without disturbing checks running in parallel with the same
    /// timeout — a type property would have hit them all.
    var pieceDeadline: TimeInterval = MatroskaFileSession.pieceDeadlineDefault

    /// A slot into which the task puts its result.
    ///
    /// Needed because between the waiting thread and the task something
    /// must stand that both may touch; under the rules of Swift 6 they may not
    /// share an ordinary variable.
    private final class Outcome: @unchecked Sendable {
        var data: Data?
    }

    /// Builds a piece from its bytes.
    private func produce(
        _ piece: MatroskaIndex.Piece, delay: Int64?
    ) async throws -> (
        initialization: Data, segment: Data, delay: Int64, raster: TimeGrid?, frameMarks: [Int64]
    )? {
        guard !lock.withLock({ halted }) else { return nil }
        let fetchStart = Date()
        // **With trailing read** (see ``MatroskaRemuxer/trailingBegins()``): the
        // start of the next cluster is fetched along, so the pictures of the
        // own group of pictures that lie there are not lost
        // at the seam. The first step comes in the same request as the body;
        // whether more are needed is decided by the remuxer — see
        // ``trailingStep``.
        let fileEnd = self.fileEnd
        let step = max(4 << 10, trailingStep)
        let trailingEnd = min(piece.range.upperBound + step, fileEnd)
        let total = try await source.bytes(
            in: piece.range.lowerBound..<max(piece.range.upperBound, trailingEnd))
        guard !total.isEmpty else { return nil }
        let mainContent = min(piece.range.count, total.count)
        let body = total.subdata(in: total.startIndex..<(total.startIndex + mainContent))
        let trailing = total.subdata(in: (total.startIndex + mainContent)..<total.endIndex)
        var fetch = Date().timeIntervalSince(fetchStart)
        var reloaded = 0

        let (head, scale) = preambleAndScale()
        let repackStart = Date()
        // Fetching and remuxing interlock during the trailing read; for the line
        // the remuxing counts without the requests fetched afterwards.
        var reloadTime: TimeInterval = 0
        defer {
            // **Every piece reports its time** (F-020, probe 2026-09-04: individual
            // pieces took over twenty seconds, and nobody saw where).
            let repackTime = Date().timeIntervalSince(repackStart) - reloadTime
            let row =
                "Piece \(piece.index): \(body.count >> 10) KB, fetch \(Int(fetch * 1000)) ms, "
                + "remux \(Int(repackTime * 1000)) ms"
                + (reloaded > 0 ? ", trailing \(reloaded >> 10) KB reloaded" : "")
            onProduced?(piece.index, body.count, fetch, repackTime)
            if repackTime > 3 {
                Diagnostics.playbackProblem(row + " — too slow for the player", since: nil)
            } else if DebugMode.current.isOn {
                Diagnostics.verbose(row)
            }
        }

        // Without production lines: this store lives for only ONE piece, and
        // its "piece 0" lines flooded the trace — see the reasoning at the
        // switch of the ``SegmentStore``.
        let store = SegmentStore(retainsEverything: true, logsProduction: false)
        let (rasterBekannt, rasterFest) = gridChoice()
        let options = MatroskaRemuxer.Options(
            audioLanguage: audioLanguage,
            delay: delay,
            raster: rasterBekannt,
            gridFixed: rasterFest,
            // **Do not cut.** The boundaries are already fixed; a second
            // cut in the middle would produce a piece nobody requests.
            segmentDuration: .indefinite,
            initialStart: CMTime(
                value: NetNumber.saturatedProduct(piece.start, Int64(clamping: scale)),
                timescale: CMTimeScale(NSEC_PER_SEC)),
            writer: writer
        )
        var chosen = options
        chosen.writerFactory = writerFactory
        chosen.subtitles = subtitles
        let remuxer = MatroskaRemuxer(store: store, options: chosen)

        // **The start of the file precedes every piece.** The remuxer reads
        // quite normally — first the track table, then clusters. That the clusters come from
        // the middle of the file it does not notice and does not need to: their
        // timestamps are absolute.
        remuxer.feed(head)
        remuxer.feed(body)
        if !trailing.isEmpty {
            remuxer.trailingBegins()
            remuxer.feed(trailing)
            // **Read on up to the keyframe** — see ``trailingStep``.
            // The limit is the end of the cluster in which it lies: its head
            // is at the start of the trailing read and names its length. If it names
            // none, the end of the next piece applies — the keyframe
            // cannot lie further.
            var cursor = piece.range.upperBound + trailing.count
            let clusterEnd = Self.clusterEnd(inTrailing: trailing, from: piece.range.upperBound)
            let limit = min(clusterEnd ?? nextPieceEnd(after: piece) ?? fileEnd, fileEnd)
            while !remuxer.hasTrailingKeyframe, cursor < limit {
                try Task.checkCancellation()
                let upper = min(cursor + step, limit)
                let requested = upper - cursor
                let started = Date()
                let next = try await source.bytes(in: cursor..<upper)
                let duration = Date().timeIntervalSince(started)
                reloadTime += duration
                fetch += duration
                guard !next.isEmpty else { break }
                reloaded += next.count
                cursor += next.count
                remuxer.feed(next)
                // Less than requested means: the source has ended.
                if next.count < requested { break }
            }
            // **A trailing read without a keyframe is a hole at the seam** —
            // and until F-023 it was in no line. Once per file, with
            // the position, so the next probe knows where to look.
            if !remuxer.hasTrailingKeyframe, cursor < fileEnd,
                claim(.trailingWithoutKeyframe)
            {
                Diagnostics.playbackProblem(
                    "Piece \(piece.index): the trailing read reached no keyframe after "
                        + "\((trailing.count + reloaded) >> 10) KB — "
                        + "picture and sound are missing at this seam",
                    since: nil)
            }
        }
        await remuxer.finish()
        // **A dead writer says so** — before the exit below, which returns `nil`
        // silently when the store is empty. The verdict is made in
        // ``writerMessage(_:piece:claim:)``.
        if let row = Self.writerMessage(remuxer.failure, piece: piece.index, claim: claim) {
            Diagnostics.playbackProblem(row, since: nil)
        }
        // **An audio stretch that delivers nothing now says so itself** — and
        // in the error trace instead of only when recording is switched on.
        // Here the balance was only ``Diagnostics/verbose(_:since:)``, and
        // so it was absent in the one case it exists for: whoever
        // sees a film without audio has not flipped the switch beforehand.
        // The verdict is made in ``AudioTally``, here it is only spoken.
        switch Self.audioMessage(remuxer.audioBalance, piece: piece.index, claim: claim) {
        case .problem(let text): Diagnostics.playbackProblem(text, since: nil)
        case .row(let text): Diagnostics.verbose(text)
        case .none: break
        }

        // **All pieces of the writer one after another.** The custom writer
        // cuts at every keyframe; a piece from the walk through the
        // clusters can carry several. An HLS segment may contain several `moof`
        // — the player reads them as one.
        guard let initialization = store.headerData, store.count > 0 else {
            return nil
        }
        var segment = Data()
        for index in 0..<store.count {
            if let part = store.segment(index) { segment.append(part) }
        }
        guard !segment.isEmpty else { return nil }

        // **The seam measurement** (Blibiagraik hunt, 2026-08-16): per window it states what
        // picture and audio really cover. If audio is missing at the front or back, exactly
        // this gap adds up in the fMP4 to the sync offset — the audio
        // carries no timestamps of its own there, only durations in sequence. This
        // line says WHERE the audio is lost instead of guessing.
        if let coverage = remuxer.coverage {
            let video = coverage.video
            let audio = coverage.audio
            let head = audio.lowerBound - video.lowerBound
            let tail = video.upperBound - audio.upperBound
            func seconds(_ value: Double) -> String { String(format: "%.2f", value) }
            func millis(_ value: Double) -> String { String(format: "%+.0f", value * 1000) }

            // **A gaping seam is a defect, not an observation.** Until now
            // it too was only verbose and thus invisible without the diagnostics switch
            // — exactly the case the measurement was built for.
            let gaping = max(abs(head), abs(tail)) > Self.seamGapThreshold
            // Claiming happens BEFORE the line is built: with diagnostics switched
            // off, neither should the text be created nor the slot for the
            // unremarkable finding used up — whoever flips the switch in the middle
            // of the film would otherwise never see the line.
            let announces = gaping ? claim(.seamGap) : (DebugMode.current.isOn && claim(.seam))
            if announces {
                let seam =
                    "Seam at \(String(format: "%.1f", video.lowerBound)) s: "
                    + "picture \(seconds(video.lowerBound))–\(seconds(video.upperBound)), "
                    + "sound \(seconds(audio.lowerBound))–\(seconds(audio.upperBound))"
                    + " (head \(millis(head)) ms, tail \(millis(tail)) ms)"
                if gaping {
                    Diagnostics.playbackProblem(seam, since: nil)
                } else {
                    Diagnostics.verbose(seam)
                }
            }
        }
        // **The reordering says whether it worked out.**
        //
        // Every correction is a picture that got the display time of another —
        // on 2026-08-23 this hit about every fifth picture of "Blupriatio
        // Gufaidia", and nothing about it was in the whole log. As long as a
        // zero stands here, the time axis is unambiguous; if something else stands there,
        // the file reorders more than the window sees.
        // **The display time axis, in numbers** — for transport streams that has existed
        // for ever ("frame rate: 25.0 Hz, irregularity 0 %"), for files
        // there was nothing. And it was precisely there that the bug occurred.
        let timeline = remuxer.pictureTimeline
        if timeline.duplicates > 0 {
            if claim(.timelineDuplicates) {
                Diagnostics.playbackProblem(
                    "Presentation times: \(timeline.duplicates) of \(timeline.count) frames "
                        + "share a timestamp with their neighbor — they are never "
                        + "shown",
                    since: nil
                )
            }
        }

        rememberFrameRate(timeline)
        if let rate = timeline.rate, let jitter = timeline.jitter,
            timeline.duplicates == 0, DebugMode.current.isOn, claim(.timelineEven)
        {
            Diagnostics.verbose(
                "Presentation times: \(timeline.count) frames, \(rate) Hz, "
                    + "irregularity \(Int((jitter * 100).rounded())) %, "
                    + "no duplicate timestamps"
            )
        }

        // **The histogram belongs NEXT TO the two branches, not in them.** As
        // part of the `else if` it would only run at `duplicates == 0`, and
        // `duplicates` counts exactly `gap == 0` (``MatroskaRemuxer/pictureTimeline``).
        // Precisely the case it is wanted for ("Blupriatio Gufaidia",
        // `duplicates > 0`) would never get one.
        reportGapHistogram(timeline, piece: piece, scale: scale)

        if remuxer.correctionCount > 0 {
            if claim(.reorderCorrected) {
                Diagnostics.playbackProblem(
                    "Reordering: \(remuxer.correctionCount) frames corrected "
                        + "(shift \(remuxer.delay)) — the file reorders further "
                        + "than the window reaches",
                    since: nil
                )
            }
        } else if DebugMode.current.isOn, claim(.reorderClean) {
            Diagnostics.verbose(
                "Reordering: shift \(remuxer.delay), 0 corrections")
        }

        return (initialization, segment, remuxer.delay, remuxer.gridResult, remuxer.frameMarks)
    }

    // MARK: - Die Bildrate, gemessen statt geglaubt

    /// From what irregularity on nothing at all is registered.
    ///
    /// **Ten percent** (AP2 · U4). In the same second on 2026-08-23 there stood
    /// "27.78 Hz measured, irregularity 30 %" and "30.0 Hz registered (measured by the
    /// remuxer)" — the 30.0 came from `DefaultDuration` of the
    /// Matroska head, that is, from a claim of the file, and the note
    /// was simply wrong at this point. With an irregularity of thirty
    /// percent there is no frame rate that could be registered: no number is
    /// better than a wrong one — the same rule that
    /// ``FrameRateRegistration/standardRate(forItem:)`` already enforces.
    public static let maximumIrregularity = 0.10

    /// The frame rate this file can vouch for — or `nil`.
    ///
    /// Three conditions, and each catches a real case from the recording:
    /// a time axis without duplicate times (with "Blupriatio Gufaidia" about every fifth
    /// picture shared its time with its neighbour), a
    /// measured rate at all, and an irregularity below the limit.
    public static func frameRate(from timeline: MatroskaRemuxer.PictureTimeline) -> Double? {
        guard timeline.duplicates == 0, let rate = timeline.rate, let jitter = timeline.jitter,
            jitter <= maximumIrregularity
        else { return nil }
        return rate
    }

    /// The measured frame rate of the file — only known once a piece is built.
    public var measuredFrameRate: Double? {
        lock.lock()
        defer { lock.unlock() }
        return measuredRate
    }

    private var measuredRate: Double?

    /// Called once as soon as a reliable frame rate is available.
    ///
    /// **As a message and not as a return value of ``start()``**: measuring
    /// is only possible on a built piece, and `start()` builds none —
    /// it returns the playlist from the index. Whoever demands the number at
    /// start therefore inevitably gets that of the container head, and
    /// that was exactly the bug.
    public var onFrameRate: (@Sendable (Double) -> Void)?

    private func rememberFrameRate(_ timeline: MatroskaRemuxer.PictureTimeline) {
        guard let rate = Self.frameRate(from: timeline) else { return }
        lock.lock()
        let fresh = measuredRate == nil
        measuredRate = rate
        let report = onFrameRate
        lock.unlock()
        guard fresh else { return }
        Diagnostics.verbose("Frame rate of the file measured: \(rate) Hz")
        report?(rate)
    }

    /// From what irregularity on the distribution of picture intervals is
    /// reported.
    ///
    /// **Five percent, and the number is chosen, not derived.**
    /// ``MatroskaRemuxer/PictureTimeline/irregularShare`` already carries a
    /// tolerance of one fifth; the millisecond grid of a 23.976 Hz file
    /// (intervals of 41 and 42 ms, 2.4 % apart) yields a share
    /// of **exactly zero** in it and never triggers. In addition, the five percent let
    /// a handful of individual outliers in a piece pass
    /// before the line rings.
    static let gapHistogramThreshold = 0.05

    /// The distribution of the picture intervals — once per file, and only if it
    /// is not round.
    ///
    /// **The one line that separates "the file is encoded that way" from "our reordering
    /// breaks it".** Zeros and duplicates in equal numbers are the
    /// signature of the reordering: a picture on the time of its neighbour and
    /// behind it the double gap. An alternation of two unequal intervals without
    /// a single zero, on the other hand, is 3:2 or real VFR — then it is down to
    /// the file.
    ///
    /// It reports on ONE piece, not on the file: ``shownTimes`` lives
    /// no longer than the remuxer of a piece. That is why piece number
    /// and start time are in the line.
    private func reportGapHistogram(
        _ timeline: MatroskaRemuxer.PictureTimeline,
        piece: MatroskaIndex.Piece,
        scale: UInt64
    ) {
        // `claim` stands DELIBERATELY as the last condition: otherwise the
        // first, clean piece would use up the slot, and the piece in which it
        // flips in the middle of the film would never get a line — exactly the Blupriatio Gufaidia bug.
        guard timeline.irregularShare > Self.gapHistogramThreshold,
            let median = timeline.medianGap,
            claim(.timelineHistogram)
        else { return }

        let bars = timeline.histogram
        let start = Double(piece.start) * Double(scale) / 1e9
        // `playbackProblem` and not `verbose`: a finding above the
        // threshold is a defect and must not vanish behind the diagnostics switch
        // — the same reasoning as for the gaping seam.
        Diagnostics.playbackProblem(
            String(
                format: "Frame gaps (piece %d at %.0f s): %d gaps, median %.0f ms, "
                    + "%.0f %% irregular", piece.index, start, timeline.gaps.count,
                median * 1000, timeline.irregularShare * 100)
                + " — 0 ms: \(bars.zero), shorter: \(bars.shorter), single: \(bars.single), "
                + "double: \(bars.double), triple: \(bars.triple), longer: \(bars.longer)",
            since: nil)
    }

    /// The end of a file according to its index: the last entry plus
    /// the mean interval of the entries — in seconds, or `nil` without
    /// entries. See ``start()``.
    static func honestEnd(entries: [MatroskaIndex.Entry], timestampScale: UInt64) -> Double? {
        guard let last = entries.last else { return nil }
        let secondsPerTick = Double(timestampScale) / Double(NSEC_PER_SEC)
        let gaps = zip(entries, entries.dropFirst()).map { $1.time - $0.time }.sorted()
        let median = gaps.isEmpty ? Int64(0) : gaps[gaps.count / 2]
        return Double(NetNumber.saturatedSum(last.time, median)) * secondsPerTick
    }

    /// Where the cluster that begins at the start of the trailing read ends — or `nil`
    /// if there is no cluster with a length field there.
    static func clusterEnd(inTrailing trailing: Data, from position: Int) -> Int? {
        guard let element = Matroska.element(in: trailing, at: 0),
            element.id == Matroska.ID.cluster, let size = element.size
        else { return nil }
        return position + element.headerSize + size
    }

    /// The end of the piece after this one — its keyframe cannot lie
    /// further.
    private func nextPieceEnd(after piece: MatroskaIndex.Piece) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let next = piece.index + 1
        return pieces.indices.contains(next) ? pieces[next].range.upperBound : nil
    }

    /// Accepts a finding — under the lock, because the own server
    /// can serve several pieces at the same time and two threads would otherwise write the same
    /// line.
    private func claim(_ finding: FileReportGate.Finding) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reports.claim(finding)
    }

    /// **The locks stay outside of `await`.** A lock held across
    /// a suspension point is still held on another thread when the task continues there
    /// — so these small helpers do nothing but take it briefly and release it again.
    private func install(header: Matroska.Header, pieces: [MatroskaIndex.Piece], preamble: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.header = header
        self.pieces = pieces
        self.fileEnd = pieces.last?.range.upperBound ?? 0
        self.preamble = preamble
    }

    private func fixGrid(_ detected: TimeGrid?, origin: String = "from the seek table") {
        lock.lock()
        defer { lock.unlock() }
        raster = detected
        gridFixed = true
        if let detected, DebugMode.current.isOn {
            Diagnostics.verbose(
                "Time grid of the file: \(detected.step.value)/\(detected.step.timescale) s per frame, "
                    + "phase \(Int(detected.anchor.seconds * 1000)) ms, \(origin)")
        }
    }

    /// The grid of the file in words — for diagnostics and probe.
    public var timeGridReport: String {
        lock.lock()
        defer { lock.unlock() }
        let marks = pieces.prefix(4).map { "\($0.start)" }.joined(separator: ", ")
        guard let raster else {
            return "no grid (\(pieces.count) marks, scale \(header.timestampScale), first \(marks)) — "
                + TimeGrid.checkReport(marks: pieces.map(\.start), scale: header.timestampScale)
        }
        return "Grid \(raster.step.value)/\(raster.step.timescale) s, phase "
            + String(format: "%.2f", raster.anchor.seconds * 1000)
            + " ms (\(pieces.count) marks, first \(marks))"
    }

    /// The fixed grid of the file, read under lock.
    private func gridChoice() -> (TimeGrid?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (raster, gridFixed)
    }

    private func install(
        opening: (initialization: Data, segment: Data, delay: Int64, raster: TimeGrid?, frameMarks: [Int64])
    ) {
        lock.lock()
        defer { lock.unlock() }
        initialization = opening.initialization
        delay = opening.delay
        // The seek table knows step AND phase; the file's `DefaultDuration`
        // only the step. It therefore applies only if the table yielded
        // nothing.
        if raster == nil, let own = opening.raster { raster = own }
        remember(index: 0, data: opening.segment)
    }

    private func preambleAndScale() -> (Data, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (preamble, header.timestampScale)
    }

    private func remember(index: Int, data: Data) {
        cache.removeAll { $0.index == index }
        cache.append((index, data))
        Self.evict(
            &cache, um: lastRequested, atMost: Self.bufferPieces, bytes: Self.bufferBytes)
    }

    /// Makes room in the store — first to go is what lies behind the player, the
    /// oldest first; only then the farthest ahead. The piece at the position
    /// of the player and one before it always stay, because the player
    /// occasionally fetches a piece twice.
    static func evict(
        _ downloads: inout [(index: Int, data: Data)], um location: Int, atMost: Int, bytes budget: Int
    ) {
        func bytes() -> Int { downloads.reduce(0) { $0 + $1.data.count } }
        while downloads.count > 1, downloads.count > atMost || bytes() > budget {
            let rearmost = downloads.indices.filter { downloads[$0].index < location - 1 }
            if let oldest = rearmost.min(by: { downloads[$0].index < downloads[$1].index }) {
                downloads.remove(at: oldest)
                continue
            }
            guard let farthest = downloads.indices.max(by: { downloads[$0].index < downloads[$1].index })
            else { return }
            downloads.remove(at: farthest)
        }
    }
}
