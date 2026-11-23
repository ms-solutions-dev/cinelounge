import AVFoundation
import CoreMedia
import Foundation

/// Repackages an MKV file continuously into fMP4.
///
/// **The counterpart to ``TransportRemuxer``, and the bigger catch.** The channel
/// case affects eight channels; this one covers 96 percent of the library — and the
/// measured 925 milliseconds to 14.5 seconds that the server currently needs
/// because it does the same thing, just on the other side of the network.
///
/// ## What differs here from the channel case
///
/// **The header comes first and is complete.** No waiting for tables, no
/// collecting descriptions from the running stream: what exists is in the track
/// table before the first picture arrives. That makes the start simpler.
///
/// **In return, the decode times are missing.** A transport stream carries them in
/// every packet header, MKV does not — they have to be produced (``DecodeOrder``).
/// That makes the rest harder.
///
/// **And there is more than one audio track.** Three languages are the normal case,
/// and the choice is made here, not in the player: an fMP4 stream carries exactly
/// the tracks that were registered at setup.
public final class MatroskaRemuxer: @unchecked Sendable {

    /// Why nothing comes out, if nothing does.
    public enum Refusal: Error, Equatable {
        case noVideoTrack
        case videoNotHardwareDecodable(String)
        case noParameterSets
        case fileIsUnreadable
    }

    /// How this remuxer is supposed to work.
    public struct Options: Sendable {
        /// Which audio language is wanted. `nil` means: the default track.
        public var audioLanguage: String?
        /// An already known shift — see ``DecodeOrder/init(window:delay:)``.
        public var delay: Int64?
        /// The time grid of the picture track, if it is already settled — like
        /// ``delay`` decided once per file, at the first piece, and handed on to
        /// all further pieces. Otherwise each piece estimated on its own, and
        /// where the estimate came out differently, the delay deviated by up to one
        /// frame: audio and picture offset at the seam.
        public var raster: TimeGrid?
        /// Whether ``raster`` has already been decided — `nil` then means
        /// "deliberately none", not "not yet known".
        public var gridFixed: Bool
        /// At which length to cut. `.indefinite` means: not at all.
        public var segmentDuration: CMTime
        /// Which time the resulting piece carries to the outside.
        public var initialStart: CMTime
        /// Who writes the pieces — see ``TransportRemuxer/ChunkWriter``.
        ///
        /// **The default is the custom writer** (F-023, 2026-09-05): On the Apple TV the
        /// system writer held its input for up to 15 s with large pieces (the interleaving
        /// lock that three rebuilds failed to get around) and then discarded packets — a
        /// hole in the picture, an offset in the audio. The custom writer collects both
        /// tracks separately, writes them in one go and has no input that could be
        /// held. The system writer remains as an option for comparison on the test bench.
        public var writer: TransportRemuxer.ChunkWriter

        /// A writer build in place of ``writer`` — **only for the checks**.
        ///
        /// Module-internal: with it a build that throws can be supplied, and thereby the
        /// connection "writer dead → failure track" can be checked (stall stage 5). A
        /// real film does not deliver this case on demand.
        var writerFactory: (@Sendable (CMFormatDescription, CMFormatDescription?) throws -> any SampleSink)?

        /// Where the text subtitles go — see ``SubtitleCollector``.
        public var subtitles: SubtitleCollector?

        public init(
            audioLanguage: String? = nil,
            delay: Int64? = nil,
            raster: TimeGrid? = nil,
            gridFixed: Bool = false,
            segmentDuration: CMTime = FragmentWriter.segmentDuration,
            initialStart: CMTime = .zero,
            writer: TransportRemuxer.ChunkWriter = .own
        ) {
            self.audioLanguage = audioLanguage
            self.delay = delay
            self.raster = raster
            self.gridFixed = gridFixed
            self.segmentDuration = segmentDuration
            self.initialStart = initialStart
            self.writer = writer
        }
    }

    private let store: SegmentStore
    private let options: Options
    private let lock = NSLock()

    private let reader = MatroskaReader()
    private var order: DecodeOrder

    private var videoTrack: Matroska.Track?
    /// The chosen audio track.
    ///
    /// **Readable inside the package so that the choice can be tested** (AP6 · Q9): The
    /// check "The requested language is taken" compared, until 2026-09-02, the **number**
    /// of audio tracks in the header and the picture shift — if ``chooseAudio()``
    /// ignored the language choice entirely, it would stay green. What it meant to
    /// check is here.
    private(set) var audioTrack: Matroska.Track?
    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMFormatDescription?
    private var lengthSize = SampleAssembly.lengthPrefixSize
    private var audioSampleRate = 48000
    private var audioSamplesPerFrame = AudioAssembly.samplesPerFrame
    /// Records where the audio is **transcoded** instead of passed through: MPEG audio
    /// via ``MPEGAudioTranscoder``, the DTS core via ``DTSTranscoder``. Then the
    /// writer receives AAC. This used to say "only for MPEG audio" — since 2026-09-04. DTS
    /// is the second case, and the fact that it was missing obscured the question of
    /// who actually vouches for the path (see ``audioBalance``).
    private var audioTranscoder: (any AudioTranscoding)?
    /// Frames that went into the transcoder, and packets that came out.
    ///
    /// **Counted here and not in the transcoder**, although it could do it just as
    /// well: ``AudioTranscoding`` is a public interface, and the sister app on the
    /// phone depends on the same package. Adding a counting obligation there would
    /// demand bookkeeping from every future transcoder that only this one reader
    /// needs.
    private var audioFramesIn = 0
    private var audioPacketsOut = 0

    /// What the audio path attests about itself — see ``AudioTally``.
    ///
    /// `nil` if the audio passes through unchanged (AAC, AC-3, E-AC-3): then there is
    /// no path that could stay silent, and a balance over zero processing steps would
    /// be a line without meaning.
    public var audioBalance: AudioTally? {
        // **Under the lock like ``heldAudioCount``.** It is written only under it; a
        // reader without it is, in an `@unchecked Sendable` class, a promise the compiler
        // no longer checks. Today only the holder reads after `finish()` — but the rule
        // should not depend on who reads.
        lock.lock()
        defer { lock.unlock() }
        guard let audioTranscoder else { return nil }
        let dts = audioTranscoder as? DTSTranscoder
        let seconds =
            audioSampleRate > 0
            ? Double(audioFramesIn * audioSamplesPerFrame) / Double(audioSampleRate)
            : 0
        return AudioTally(
            codec: dts == nil ? "MPEG audio" : "DTS",
            framesIn: audioFramesIn,
            packetsOut: audioPacketsOut,
            secondsIn: seconds,
            channels: Int(audioFormat?.audioStreamBasicDescription?.mChannelsPerFrame ?? 0),
            rejectedFrames: dts?.failedFrames,
            reason: dts?.lastError)
    }

    /// Where the finished packets go — see ``SampleSink`` and
    /// ``Options/writer``.
    private var sink: (any SampleSink)?
    private var hasSeenKeyframe = false
    /// The grid of picture times from `DefaultDuration` — see ``TimeGrid``.
    private var frameGrid: TimeGrid?
    /// The grid of audio times from frame length and sample rate.
    private var audioGrid: TimeGrid?
    /// The continuous picture axis: every picture is its predecessor plus exactly
    /// one step, as long as the file's timestamp does not deviate further — see
    /// ``AudioAxis``. A global grid is not needed for this; a file
    /// with gaps (S latple Micutror) snaps back in at the gap.
    private var frameAxis = AudioAxis()
    /// Whether the grid has been decided — no writer starts before that,
    /// because its time base depends on it.
    private var gridDecided = false
    /// Whether the lookahead is running — see ``trailingBegins()``.
    private var inTrailing = false
    /// Whether it stopped at the keyframe of the next piece.
    private var halted = false

    /// Pictures in decode order that are still waiting for their times.
    private var pendingPictures: [(frames: [Data], isKeyframe: Bool)] = []
    /// Audio that arrived before the shift was settled.
    private var pendingSound: [(time: Int64, frames: [Data])] = []
    /// Finished packets waiting for the writer.
    private var waiting: [(time: CMTime, isAudio: Bool, sample: CMSampleBuffer)] = []

    /// Warum nichts entsteht — `nil`, solange alles seinen Gang geht.
    public private(set) var refusal: Refusal?

    /// Why the writer failed, if it did — for the search.
    ///
    /// **Also when it was never created** (stall stage 5, 2026-09-25). Here there was
    /// only `sink?.failure`, and the build ran with `try?`: if it failed,
    /// `sink` was empty and the reason vanished with it — the same gap that stage 1
    /// closed in ``TransportRemuxer``. With the custom writer (the default)
    /// the failed build is even the **only** way to a content: ``CMAFWriter``
    /// knows no persistent error state.
    public var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return sink?.failure ?? sinkFailure
    }

    /// Why the writer build failed — `nil` as long as none failed.
    private var sinkFailure: Error?

    public init(store: SegmentStore, options: Options = Options()) {
        self.store = store
        self.options = options
        order = DecodeOrder(delay: options.delay)
        if options.gridFixed {
            frameGrid = options.raster
            gridDecided = true
        }
    }

    /// The grid this remuxer has committed to — for the next pieces of the same
    /// file (``Options/raster``).
    public var gridResult: TimeGrid? {
        lock.lock()
        defer { lock.unlock() }
        return frameGrid
    }

    /// The raw presentation stamps of the pictures, as the file states them — for
    /// ``TimeGrid/estimate(marks:scale:)``.
    public var frameMarks: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return shownTimes
    }

    public convenience init(store: SegmentStore, audioLanguage: String?) {
        self.init(store: store, options: Options(audioLanguage: audioLanguage))
    }

    /// What was in the track table.
    public var header: Matroska.Header { reader.header }

    /// Whether the writer is running — that is, whether anything is being produced yet.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sink != nil
    }

    /// By how much the time calculation has been shifted back. See ``DecodeOrder``.
    /// The coverage of both tracks of this run — for the seam measurement of the
    /// windows (Blibiagraik hunt, 2026-08-16), see ``FragmentWriter/coverage``.
    public var coverage: (video: ClosedRange<Double>, audio: ClosedRange<Double>)? {
        lock.lock()
        defer { lock.unlock() }
        guard let firstVideo, let lastVideo, let firstAudio, let lastAudio,
            firstVideo <= lastVideo, firstAudio <= lastAudio
        else { return nil }
        return (firstVideo...lastVideo, firstAudio...lastAudio)
    }

    /// The coverage of both tracks, measured at the funnel — what the remuxer
    /// feeds to the writer, in presentation time. Previously the system writer kept
    /// these numbers; with the custom writer they belong here, so that the seam
    /// measurement applies to both.
    private var firstVideo: Double?
    private var lastVideo: Double?
    private var firstAudio: Double?
    private var lastAudio: Double?

    /// Whether the lookahead has reached its keyframe — the point at which the next
    /// piece begins. If it does not, the lookahead ended before the keyframe, and
    /// what lies in between is taken by no piece: **picture and audio are missing at
    /// the seam** (F-023, 2026-09-05: at three of four seams 0.2–0.5 s).
    /// ``MatroskaFileSession`` therefore reads on until this mark is set.
    public var hasTrailingKeyframe: Bool {
        lock.lock()
        defer { lock.unlock() }
        return halted
    }

    public var delay: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return order.delay
    }

    /// The display times of this piece, in output order.
    private var shownTimes: [Int64] = []

    /// What the display time axis of this piece looks like.
    ///
    /// **The one quantity that matters for judder — and it was never collected for
    /// files.** For transport streams there has always been "frame rate: 25.0 Hz,
    /// irregularity 0 %"; for Matroska there was nothing, and the error occurred
    /// precisely there (2026-08-23, "Blupriatio Gufaidia"). Dropouts, buffer messages and
    /// discarded pictures were all at zero, while every fifth picture carried the
    /// time of its neighbor.
    ///
    /// `duplicates` is the core: **two pictures at the same instant**. Everything
    /// else can look clean while this counts.
    public var pictureTimeline: PictureTimeline {
        lock.lock()
        defer { lock.unlock() }

        let ordered = shownTimes.sorted()
        guard ordered.count > 1 else {
            return PictureTimeline(
                count: ordered.count, duplicates: 0, rate: nil, jitter: nil, gaps: [])
        }

        let secondsPerTick = Double(reader.header.timestampScale) / 1e9
        var cadence = FrameCadence()
        var duplicates = 0
        var gaps: [Double] = []
        gaps.reserveCapacity(ordered.count - 1)
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            let ticks = next - previous
            if ticks == 0 { duplicates += 1 }
            let gap = Double(ticks) * secondsPerTick
            gaps.append(gap)
            // The median stays filtered — the distribution does not.
            cadence.add(gap)
        }
        return PictureTimeline(
            count: ordered.count, duplicates: duplicates,
            rate: cadence.rate, jitter: cadence.jitter, gaps: gaps)
    }

    /// What the display time axis of ONE PIECE looks like.
    ///
    /// **One piece, not the file**: ``MatroskaFileSession`` builds a fresh remuxer for
    /// each requested piece, and ``shownTimes`` lives no longer than that. Whoever
    /// reports the numbers must name the piece.
    public struct PictureTimeline: Sendable, Equatable {
        public let count: Int
        public let duplicates: Int
        public let rate: Double?
        public let jitter: Double?

        /// The **raw** gaps in seconds, in display order.
        ///
        /// **Raw, because ``FrameCadence/add(_:)`` discards exactly what this is about**:
        /// the gap of zero — two pictures at the same instant — drops out there under
        /// `gap > 0.001`, the jump under `gap < 0.5`. For the median that is right; for
        /// the distribution it is the opposite of what one is looking for.
        public let gaps: [Double]

        /// The mean gap — median over the raw gaps.
        ///
        /// **And a fallback if the median itself becomes zero.** That happens as soon as
        /// MORE THAN HALF of the gaps are zero — that is, in the worst conceivable case
        /// of reordering. Without the fallback every derived quantity would drop out here,
        /// ``irregularShare`` would be zero, and the worst file of all would get no line.
        public var medianGap: Double? {
            guard !gaps.isEmpty else { return nil }
            let sorted = gaps.sorted()
            let median = sorted[sorted.count / 2]
            if median > 0 { return median }
            let moving = sorted.filter { $0 > 0 }
            guard !moving.isEmpty else { return nil }
            return moving[moving.count / 2]
        }

        /// Share of the gaps that deviate from the median by more than a fifth —
        /// **including** the zeros.
        ///
        /// Not the same as ``jitter``: that one computes on the filtered list
        /// and never sees the zeros.
        public var irregularShare: Double {
            guard let median = medianGap, median > 0, !gaps.isEmpty else { return 0 }
            let off = gaps.filter { abs($0 - median) / median > 0.2 }.count
            return Double(off) / Double(gaps.count)
        }

        /// The gaps counted in multiples of the median.
        public struct Histogram: Sendable, Equatable {
            /// Two pictures at the same instant.
            public var zero = 0
            public var shorter = 0
            public var single = 0
            public var double = 0
            public var triple = 0
            public var longer = 0
        }

        /// **The one separating question** (AP1): zeros and doubles in equal numbers
        /// mean that a picture was moved onto its neighbor and the gap behind it is
        /// twice as large — our reordering. No zeros, but instead an alternation of
        /// two unequal gaps, means: the file is encoded that way.
        public var histogram: Histogram {
            var out = Histogram()
            guard let median = medianGap, median > 0 else { return out }
            for gap in gaps {
                if gap == 0 {
                    out.zero += 1
                    continue
                }
                switch gap / median {
                case ..<0.7: out.shorter += 1
                case ..<1.3: out.single += 1
                case ..<2.3: out.double += 1
                case ..<3.3: out.triple += 1
                default: out.longer += 1
                }
            }
            return out
        }
    }

    /// How often the reordering had to adjust a time.
    ///
    /// **The counter was always kept and read by no one** — and it is exactly the
    /// number that would have proved the Blupriatio Gufaidia error: every correction means a
    /// picture at the time of another. On 2026-08-23 that was about twenty percent of all
    /// pictures of the film, and not a single line in the log said so.
    public var correctionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return order.correctionCount
    }

    // MARK: - Füttern

    public func feed(_ chunk: Data) {
        let blocks = reader.read(chunk)

        lock.lock()
        defer { lock.unlock() }

        if reader.isBroken { refusal = .fileIsUnreadable }
        for block in blocks { handle(block) }
        startIfPossible()
        drainWaiting()
    }

    /// Finishes the file and emits the last piece.
    /// From now on comes the **lookahead**: the start of the next piece.
    ///
    /// **Finding F-005 (2026-09-04, S latple Micutror):** zero dropouts, zero discarded
    /// pictures — and every two and a half seconds a still frame of 167 ms. The file
    /// puts the last P picture of a group of pictures at the end of a cluster and the
    /// three B pictures shown before it at the start of the next. One piece ended at
    /// the cluster end; the next began at the cluster start and discarded everything
    /// before its keyframe — exactly these three pictures. At every piece boundary
    /// three pictures were missing.
    ///
    /// Therefore a piece reads beyond its end into the next cluster and stops at the
    /// first keyframe there: what precedes it belongs to its own group of pictures —
    /// picture and audio alike. The boundary thus lies at the keyframe, not at the
    /// cluster.
    public func trailingBegins() {
        lock.lock()
        defer { lock.unlock() }
        inTrailing = true
    }

    public func finish() async {
        let sink = closeInput()
        await sink?.finish()
        store.markComplete()
    }

    private func closeInput() -> (any SampleSink)? {
        lock.lock()
        defer { lock.unlock() }

        for block in reader.flush() { handle(block) }
        // What lies in the lookahead window must still come out — otherwise half a second
        // is missing at the end of every film.
        emit(order.flush())
        startIfPossible()
        drainWaiting()
        // **On finishing: report the picture track done, THEN the remaining
        // audio.** Why is stated at ``heldAudio`` and
        // ``FragmentWriter/finishPictures()``.
        (sink as? FragmentWriter)?.finishPictures()
        releaseHeldAudio(upTo: nil)
        return sink
    }

    // MARK: - Innen

    private func handle(_ block: MatroskaReader.Block) {
        prepareIfNeeded(block)

        if block.track == videoTrack?.number {
            handlePicture(block)
        } else if block.track == audioTrack?.number {
            handleSound(block)
        } else if let collector = options.subtitles,
            let subtitleTrack = reader.header.subtitleTracks.first(where: { $0.number == block.track })
        {
            // Subtitles do not go into the file — AVFoundation would not accept most of them
            // anyway — but to the collector, which hands them to the player.
            collector.take(block, track: subtitleTrack, scale: reader.header.timestampScale)
        }
    }

    /// Chooses the tracks and builds the descriptions — once, at the first block.
    private func prepareIfNeeded(_ block: MatroskaReader.Block) {
        guard videoTrack == nil, reader.isHeaderComplete else { return }

        guard let video = reader.header.video else {
            refusal = .noVideoTrack
            return
        }
        guard let kind = video.stream, video.isVideoHardwareDecodable else {
            refusal = .videoNotHardwareDecodable(video.codecID)
            return
        }
        videoTrack = video
        // **The grid is settled with the track**: from `DefaultDuration`, or
        // predefined by the session (recognized from the seek table). If the file names
        // nothing and the session knows nothing, the raw stamps remain.
        if !gridDecided {
            frameGrid = TimeGrid(nanosecondsPerFrame: video.defaultDuration)
            gridDecided = true
        }
        audioTrack = chooseAudio()

        if let codecPrivate = video.codecPrivate,
            let description = VideoConfiguration.description(from: codecPrivate, kind: kind)
        {
            lengthSize = description.lengthSize
            if description.sets.isComplete(for: kind) {
                videoFormat = try? SampleAssembly.formatDescription(
                    from: description.sets, kind: kind, lengthSize: lengthSize)
            }
        }
        prepareAudio()
        _ = block
    }

    /// **The audio track is chosen here and not in the player.** An fMP4 stream carries
    /// the tracks that were registered at setup; what is not chosen here is not
    /// available for choice later.
    private func chooseAudio() -> Matroska.Track? {
        let candidates = reader.header.audioTracks.filter {
            $0.stream?.isHardwareDecodable ?? false
        }
        if let audioLanguage = options.audioLanguage,
            let match = candidates.first(where: { LanguageCode.matches($0.language, audioLanguage) })
        {
            return match
        }
        return candidates.first { $0.isDefault } ?? candidates.first
    }

    private func prepareAudio() {
        guard let track = audioTrack, let kind = track.stream else { return }

        switch kind {
        case .aac:
            // From the description in the header, otherwise from the track table — which
            // also knows sample rate and channel count.
            let fromConfig = track.codecPrivate.flatMap(
                AudioAssembly.configuration(fromAudioSpecificConfig:))
            let rate = fromConfig?.sampleRate ?? track.sampleRate ?? 48000
            let channels = fromConfig?.channels ?? track.channels ?? 2
            audioSampleRate = rate
            audioSamplesPerFrame = AudioAssembly.samplesPerFrame
            audioFormat = try? AudioAssembly.formatDescription(
                sampleRate: rate, channels: channels)
        case .ac3, .eac3:
            // **Here the description is not in the header but in the first frame** — it is
            // therefore built only at ``handleSound(_:)``.
            break
        case .mp2Audio:
            // **The same case, and it was missing** (check agent 2026-08-23): MP2 and MP3 also
            // carry their description in the frame, not in the header. Without this branch
            // such a file fell into `default`, `audioTrack` became `nil`, and
            // ``handleSound(_:)`` bailed out immediately — **the whole fully built
            // transcoding branch below it was unreachable**, along with its own error message.
            //
            // At the same time the engine selection sends such files exactly here, because
            // `remuxableAudioCodecs` includes mp2 and mp3. Result: a Matroska with MP2 audio
            // stayed silent without anything saying so.
            break
        case .dts:
            // Like AC-3: the description is in the frame — ``handleSound(_:)``.
            break
        default:
            audioTrack = nil
        }
    }

    private func handlePicture(_ block: MatroskaReader.Block) {
        guard let kind = videoTrack?.stream else { return }

        // **For the files whose header carries no descriptions.** One of the four test
        // files has an `hvcC` with "zero fields"; there they are in the picture stream,
        // as in the channel case, only with lengths instead of start codes.
        if videoFormat == nil {
            let sets = VideoConfiguration.parameterSets(
                inFrames: block.frames, kind: kind, lengthSize: lengthSize)
            guard sets.isComplete(for: kind),
                let format = try? SampleAssembly.formatDescription(
                    from: sets, kind: kind, lengthSize: lengthSize)
            else { return }
            videoFormat = format
        }

        if halted { return }
        if !hasSeenKeyframe {
            guard block.isKeyframe else { return }
            hasSeenKeyframe = true
        } else if inTrailing, block.isKeyframe {
            // **The next piece begins here.** Everything before it in the lookahead —
            // the B pictures that still belong to the old group of pictures, and the audio
            // up to here — was ours; from here on it belongs to the next one.
            halted = true
            return
        }

        // **A block can carry several pictures** — rare, but permitted. They share one
        // timestamp and are combined here into one packet; separated, they would get the
        // same time and the writer would put two pictures on the same instant.
        pendingPictures.append((block.frames, block.isKeyframe))
        emit(order.push(block.timestamp))
    }

    private func emit(_ timings: [DecodeOrder.Timing]) {
        guard let videoFormat else { return }

        for timing in timings {
            guard !pendingPictures.isEmpty else { break }
            let picture = pendingPictures.removeFirst()
            let payload =
                picture.frames.count == 1
                ? picture.frames[0]
                : picture.frames.reduce(into: Data()) { $0.append($1) }

            // **Snapped in** (F-005): the file's stamps are milliseconds, the grid is
            // 41.708 ms — see ``TimeGrid``. Presentation and decoding both snap in; the
            // reordering delay becomes an integer multiple of a picture, so that the
            // presentation times stay on the grid.
            let decoding: CMTime
            let appearance: CMTime
            if let frameGrid {
                // The decode times are the sorted stamps — they snap in consecutively. The
                // presentation lies a whole number of pictures above: the gap of the raw stamps,
                // rounded to steps.
                let rawDecoding = time(timing.decode)
                decoding = frameAxis.start(packetTime: rawDecoding, frameDuration: frameGrid.step)
                frameAxis.next(after: decoding, frameDuration: frameGrid.step)
                // **The raw gap may be negative**: without the delay a B picture lies before its
                // decode time; only the delay (whole pictures, ``lagFrames``) lifts everything
                // above it. Both together are never negative — ``DecodeOrder`` ensures that.
                let spacing = (time(timing.presentation - order.delay) - rawDecoding).seconds
                let frames = (spacing / frameGrid.step.seconds).rounded() + lagFrames
                appearance =
                    decoding
                    + CMTimeMultiply(frameGrid.step, multiplier: NetNumber.clamped(frames, in: 0...1000))
            } else {
                decoding = time(timing.decode)
                appearance = time(timing.presentation)
            }
            guard
                let sample = try? SampleAssembly.sampleBuffer(
                    lengthPrefixed: payload,
                    presentationTime: appearance,
                    decodeTime: decoding,
                    isKeyframe: picture.isKeyframe,
                    format: videoFormat)
            else { continue }
            // **Queued by decode time, not by presentation.** The writer wants pictures in the
            // order in which they are decoded; sorted by display time the decode time would
            // run backwards, and it would refuse. For audio the two coincide, so one measure
            // suffices for the interleaving.
            enqueue(sample, at: decoding, isAudio: false)
            shownTimes.append(timing.presentation)
        }

        // As soon as the shift AND the first keyframe are settled, the accumulated audio
        // can follow — including the audio from BEFORE the keyframe, see
        // ``handleSound(_:)``.
        if order.isCalibrated, hasSeenKeyframe, !pendingSound.isEmpty {
            let held = pendingSound
            pendingSound.removeAll()
            for entry in held { makeSound(at: entry.time, frames: entry.frames) }
        }
    }

    private func handleSound(_ block: MatroskaReader.Block) {
        guard let kind = audioTrack?.stream else { return }

        if audioFormat == nil, kind == .ac3 || kind == .eac3 {
            guard let first = block.frames.first else { return }
            guard let info = AC3Audio.info(in: first) else {
                // **As in the DTS branch below** (remuxer check, finding 1, 2026-09-27): there was
                // only a `return` here — an AC-3/E-AC-3 frame whose header cannot be read left
                // `audioTrack` set forever and `audioFormat` `nil` forever. ``startIfPossible()``
                // waits for `audioTrack == nil || audioFormat != nil` and never got there — no
                // audio AND no picture.
                Diagnostics.playbackProblem(
                    "Audio: AC-3/E-AC-3 in the file, but the first frame is unreadable "
                        + "(\(first.prefix(4).map { String(format: "%02X", $0) }.joined())). "
                        + "The track stays silent",
                    since: nil)
                audioTrack = nil
                return
            }
            do {
                audioFormat = try AC3Audio.formatDescription(for: info)
                audioSampleRate = info.sampleRate
                audioSamplesPerFrame = info.samplesPerFrame
            } catch {
                // **As in the MPEG audio and DTS branches below: failure is reported, not
                // swallowed** (remuxer check, finding 1, 2026-09-27). There was a `try?` here — if
                // the description failed, `audioTrack` stayed set but `audioFormat` stayed `nil`
                // forever: ``startIfPossible()`` waits for `audioTrack == nil || audioFormat !=
                // nil` and never got there. No audio AND no picture, observed on the device on
                // 2026-08-22.
                Diagnostics.playbackProblem(
                    "Audio: AC-3/E-AC-3 in the file, but the description fails "
                        + "(\(String(describing: error))). The track stays silent",
                    since: nil)
                audioTrack = nil
                return
            }
        }
        // `A_MPEG/L3` and `/L2` — MP3 audio in old releases. The same building block as in
        // the channel case (``MPEGAudio``), requirement of 2026-08-16: one foundation for
        // library, VOD and live instead of three special paths. The AAC form of the
        // transcoder is registered — the writer's HLS profile does not accept MPEG audio.
        if audioFormat == nil, kind == .mp2Audio {
            guard let first = block.frames.first, let info = MPEGAudio.info(in: first)
            else { return }
            // As in the channel case: if the transcoder fails, that is **reported**. A `guard`
            // that returns silently looks on the TV exactly like a file without an audio track
            // (lesson of 2026-08-22).
            let transcoder: MPEGAudioTranscoder
            do {
                transcoder = try MPEGAudioTranscoder(checking: info)
            } catch {
                let reason =
                    (error as? MPEGAudioTranscoder.Obstacle)?.rawValue
                    ?? String(describing: error)
                Diagnostics.playbackProblem(
                    "Audio: MPEG audio layer \(info.layer) in the file — \(reason) "
                        + "on this device. The track stays silent",
                    since: nil
                )
                ToneProbe.reportCodecInventory()
                // **As in the DTS branch below** (remuxer check, finding 1, 2026-09-27): without
                // this line `audioTrack` stayed set but `audioFormat` stayed `nil` forever —
                // ``startIfPossible()`` waits for `audioTrack == nil || audioFormat != nil` and
                // never got there, no picture despite a reported error.
                audioTrack = nil
                return
            }
            audioSampleRate = info.sampleRate
            audioSamplesPerFrame = info.samplesPerFrame
            audioTranscoder = transcoder
            audioFormat = transcoder.outputDescription
        }
        // DTS (2026-09-04): the core via libdcadec to PCM, then on to AAC — see
        // ``DTSAudio``. Here too a failure is **reported**.
        if audioFormat == nil, kind == .dts {
            guard let first = block.frames.first else { return }
            guard let info = DTSAudio.info(in: first) else {
                Diagnostics.playbackProblem(
                    "Audio: DTS in the file, but the first frame is unreadable "
                        + "(\(first.prefix(4).map { String(format: "%02X", $0) }.joined())). "
                        + "The track stays silent",
                    since: nil)
                audioTrack = nil
                return
            }
            let transcoder: DTSTranscoder
            do {
                transcoder = try DTSTranscoder(checking: info)
            } catch {
                let reason =
                    (error as? DTSTranscoder.Obstacle)?.rawValue ?? String(describing: error)
                Diagnostics.playbackProblem(
                    "Audio: \(info.profile) \(info.channels) channels in the file — \(reason) "
                        + "on this device. The track stays silent",
                    since: nil)
                audioTrack = nil
                return
            }
            Diagnostics.verbose(
                "Audio: \(info.profile), \(info.channels) channels, \(info.sampleRate) Hz — "
                    + "core is turned into AAC in the app")
            audioSampleRate = info.sampleRate
            audioSamplesPerFrame = info.samplesPerFrame
            audioTranscoder = transcoder
            audioFormat = transcoder.outputDescription
        }
        // **Audio before the first picture is KEPT, not discarded** — and this difference
        // was the Blibiagraik sync issue (on-device finding 2026-08-16: drift from minute 8,
        // growing, seeking heals it, only with this release). There was a `return` here:
        // audio that lies in the cluster BEFORE the keyframe — a matter of how the
        // release interleaves — was thereby dropped at EVERY window seam. In fMP4 audio
        // carries no timestamps of its own, only durations in sequence: every discarded
        // portion moved all the remaining audio of the segment forward, ~20 ms per seam,
        // seams every four seconds — seconds of offset by minute eight. A jump healed it
        // because the fresh segment carries a fresh base time.
        //
        // **Nothing may come out before calibration anyway.** The shift from
        // ``DecodeOrder`` applies to picture **and** audio; whoever lets the audio through
        // earlier has offset it by two pictures against the picture. Both cases wait in
        // the same store and flow out after the first keyframe.
        if halted { return }
        // **Audio before the first keyframe does not belong to this piece** (F-005,
        // 2026-09-04): it is in the lookahead of the previous piece, which reads up to exactly
        // this keyframe. Whoever took it here as well would put up to half a second of
        // audio twice at every seam ("front -494 ms"). What counts is the position in the
        // file, not the timestamp — that way two pieces share the blocks without gaps and
        // without overlap.
        guard hasSeenKeyframe else { return }
        guard order.isCalibrated else {
            pendingSound.append((block.timestamp, block.frames))
            return
        }
        makeSound(at: block.timestamp, frames: block.frames)
    }

    private func makeSound(at timestamp: Int64, frames: [Data]) {
        guard let audioFormat else { return }
        let duration = CMTime(
            value: CMTimeValue(audioSamplesPerFrame), timescale: CMTimeScale(clamping: audioSampleRate))

        // **The timestamp applies to the first frame**, the others are counted up. In the
        // test files eight AC-3 frames lie in one block — whoever gave them all the same
        // time would put a quarter second of audio on the same instant.
        if audioGrid == nil { audioGrid = TimeGrid(step: duration) }
        // The same delay as the picture — otherwise the audio would run up to one picture
        // early or late.
        let start = (audioGrid?.snap(time(timestamp)) ?? time(timestamp)) + lag
        for (index, frame) in frames.enumerated() {
            let at = start + CMTimeMultiply(duration, multiplier: Int32(index))
            if let audioTranscoder {
                // MPEG audio and DTS continue as AAC — see ``MPEGAudioTranscoder`` and
                // ``DTSTranscoder``.
                let packetDuration = CMTime(
                    value: CMTimeValue(audioTranscoder.packetSamples),
                    timescale: CMTimeScale(clamping: audioSampleRate))
                // Both numbers at the one place through which the audio really passes — see
                // ``AudioTally``.
                audioFramesIn += 1
                for packet in audioTranscoder.transcode(frame, at: at) {
                    guard
                        let sample = try? AudioAssembly.sampleBuffer(
                            payload: packet.payload, at: packet.time,
                            duration: packetDuration, format: audioFormat)
                    else { continue }
                    // **Counting only happens here, after the packet build** (cross-check 2026-09-24).
                    // If the counter came before, the balance also counted packets that did not become
                    // a sample buffer — if the build failed throughout, "packets out" was high and the
                    // file was silent anyway. What is counted is what goes into the segment.
                    audioPacketsOut += 1
                    enqueue(sample, at: packet.time, isAudio: true)
                }
                continue
            }
            guard
                let sample = try? AudioAssembly.sampleBuffer(
                    payload: frame, at: at, duration: duration, format: audioFormat)
            else { continue }
            enqueue(sample, at: at, isAudio: true)
        }
    }

    /// Audio that lies after the last picture — it waits instead of running into the
    /// writer's interleaving lock.
    ///
    /// **The Blibiagraik drift was exactly here** (2026-08-16, convicted on the test bench): at
    /// the end of a window the audio hangs a few packets beyond the last picture. The
    /// writer made it wait for pictures that never come, ``FragmentWriter/append(_:to:)``
    /// gave up after its deadline, and per seam zero to three audio packets vanished
    /// from the output — in fMP4, without timestamps of their own, lined up into a
    /// growing shift. Held back, nothing is lost: if another picture comes, the audio
    /// flows out up to it; if none comes, the finish opens the lock
    /// (``FragmentWriter/finishPictures()``) and lets the rest through.
    private var heldAudio: [(time: CMTime, sample: CMSampleBuffer)] = []
    /// The most recent picture handed to the writer — the limit up to which audio can
    /// safely be sent after it.
    private var lastVideoTime: CMTime?

    /// Whether an audio packet may pass immediately or has to wait.
    ///
    /// **Extracted so that the rule itself can be tested** (AP10/AP11, 2026-09-02). The
    /// checks for it until then measured only the *consequence*: run a whole file
    /// through the remuxer and then count whether audio is missing. That depends on the
    /// 200 ms deadline in ``FragmentWriter/append(_:to:)`` and thus on the machine's
    /// form on the day — without the hold-back this check failed **once** in five runs.
    /// A net that holds every fifth time is none. The rule here is a calculation
    /// without a clock and fails every time.
    static func audioPath(time: CMTime, lastFrame: CMTime?) -> AudioPath {
        // **Without a picture, hold back; do not let through.** Before the first picture
        // of a window nobody knows the limit; let through, the audio would run into the
        // writer's interleaving lock and lapse after its deadline.
        guard let lastFrame, time <= lastFrame else { return .holdBack }
        return .passThrough
    }

    /// What happens to an audio packet — see ``audioPath(time:lastFrame:)``.
    enum AudioPath: Equatable {
        /// It goes to the writer.
        case passThrough
        /// It waits for a picture behind which it may lie.
        case holdBack
    }

    /// How many audio packets are waiting right now — for the check that none is left
    /// over at the end.
    var heldAudioCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return heldAudio.count
    }

    /// How many audio packets have waited at the same time **at most**.
    ///
    /// **Without this counter nothing checks that the hold-back engages at all**
    /// (2026-09-02): "At the end none is waiting" would also be green if none had ever
    /// waited — that is, exactly when the hold-back had been removed. The peak says it
    /// has been working.
    private(set) var heldAudioPeak = 0

    private func enqueue(_ sample: CMSampleBuffer, at time: CMTime, isAudio: Bool) {
        guard let sink else {
            waiting.append((time, isAudio, sample))
            return
        }
        let presentationSeconds = sample.presentationTimeStamp.seconds
        if isAudio {
            if firstAudio == nil { firstAudio = presentationSeconds }
            lastAudio = presentationSeconds
            // **Holding back only happens for a consumer that interleaves**
            // (``SampleSink/needsInterleavedInput``). The custom writer takes the audio
            // whenever it comes.
            guard
                !sink.needsInterleavedInput
                    || Self.audioPath(time: time, lastFrame: lastVideoTime) == .passThrough
            else {
                heldAudio.append((time, sample))
                heldAudioPeak = max(heldAudioPeak, heldAudio.count)
                return
            }
            _ = sink.append(audio: sample)
        } else {
            if firstVideo == nil { firstVideo = presentationSeconds }
            lastVideo = max(lastVideo ?? presentationSeconds, presentationSeconds)
            // **Audio first, then the picture — and the audio up to the PRESENTATION TIME of
            // the picture** (F-032, 2026-09-05): until then the decode time counted as the
            // limit, and the audio trailed the picture by the reordering delay, up to 0.8 s.
            // AVAssetWriter interleaves both tracks and, on the Apple TV with large pictures
            // (10 MB pieces), accepts no further picture until the audio catches up: "input
            // not ready for more data after 3000 ms", the packet was dropped, and with every
            // discarded audio frame the offset grew. On the Mac it never occurred — the lock
            // depends on memory, not on time.
            let appearance = sample.presentationTimeStamp.isNumeric ? sample.presentationTimeStamp : time
            lastVideoTime = max(lastVideoTime ?? appearance, appearance)
            releaseHeldAudio(upTo: lastVideoTime)
            if let writer = sink as? FragmentWriter, !writer.isVideoReady {
                releaseHeldAudio(upTo: nil)
            }
            _ = sink.append(video: sample)
        }
    }

    /// Releases held-back audio up to the limit — or entirely (`nil`).
    private func releaseHeldAudio(upTo limit: CMTime?) {
        guard let sink, !heldAudio.isEmpty else { return }
        heldAudio.sort { $0.time < $1.time }
        var remaining: [(time: CMTime, sample: CMSampleBuffer)] = []
        for entry in heldAudio {
            if let limit, entry.time > limit {
                remaining.append(entry)
            } else {
                _ = sink.append(audio: entry.sample)
            }
        }
        heldAudio = remaining
    }

    private func startIfPossible() {
        guard sink == nil, let videoFormat, hasSeenKeyframe, gridDecided, !waiting.isEmpty
        else { return }
        // Audio is not waited for: unlike in the channel case, the track table already
        // says whether there is any.
        guard audioTrack == nil || audioFormat != nil else { return }

        do {
            sink = try makeWriter(videoFormat: videoFormat)
            sinkFailure = nil
        } catch {
            Diagnostics.playbackProblem("Writer not built — \(Diagnostics.explain(error))", since: nil)
            sinkFailure = error
        }
    }

    /// Builds the consumer according to ``Options/writer`` — or according to the
    /// supplied build of the checks.
    private func makeWriter(videoFormat: CMFormatDescription) throws -> any SampleSink {
        if let writerFactory = options.writerFactory {
            return try writerFactory(videoFormat, audioFormat)
        }
        let store = self.store
        let timebase = frameGrid?.timebase ?? 90_000
        switch options.writer {
        case .system:
            return try FragmentWriter(
                format: videoFormat,
                audioFormat: audioFormat,
                segmentDuration: options.segmentDuration,
                initialStart: options.initialStart,
                mediaTimeScale: timebase
            ) { segment in
                if segment.isInitialization {
                    store.setHeader(segment.data)
                } else {
                    store.append(segment.data, duration: segment.duration)
                }
            }
        case .own:
            // **One piece per group of pictures, not per half second**: the boundaries are
            // known by the caller (``MatroskaFileSession``), and a keyframe opens a new piece
            // anyway. What the writer cuts into several pieces, the caller puts one after
            // another — an HLS segment may carry several `moof`.
            return try CMAFWriter(
                format: videoFormat,
                audioFormat: audioFormat,
                fragmentDuration: options.segmentDuration,
                videoTimescale: timebase
            ) { segment in
                if segment.isInitialization {
                    store.setHeader(segment.data)
                } else {
                    store.append(
                        segment.data, duration: segment.duration,
                        independent: segment.startsWithKeyframe)
                }
            }
        }
    }

    private func drainWaiting() {
        guard sink != nil, !waiting.isEmpty else { return }
        // Via ``enqueue(_:at:isAudio:)``, not past the writer: that is where the hold-back
        // for audio after the last picture sits — the path here was the gap the Blibiagraik
        // drift slipped through.
        let ordered = waiting.sorted { $0.time < $1.time }
        waiting.removeAll()
        for entry in ordered {
            enqueue(entry.sample, at: entry.time, isAudio: entry.isAudio)
        }
    }

    /// The reordering delay that picture and audio carry together — with a grid an
    /// integer multiple of a picture, otherwise the raw shift. See
    /// ``DecodeOrder/delay``.
    private var lag: CMTime {
        let raw = time(order.delay)
        guard let frameGrid, frameGrid.step.seconds > 0 else { return raw }
        return CMTimeMultiply(
            frameGrid.step, multiplier: NetNumber.clamped(lagFrames, in: 0...100_000))
    }

    /// The delay in whole pictures — zero without a grid.
    private var lagFrames: Double {
        guard let frameGrid, frameGrid.step.seconds > 0 else { return 0 }
        let frames = (time(order.delay).seconds / frameGrid.step.seconds).rounded(.up)
        return frames.isFinite && frames >= 0 ? frames : 0
    }

    /// Converts a time of the file into CoreMedia's time arithmetic.
    ///
    /// **The unit is in the file and is not assumed.** Almost always it is
    /// milliseconds — but only almost always, and whoever does not read the value gets
    /// a factor wrong with the other files.
    ///
    /// **Saturated instead of crashed** (remuxer check B4, 2026-09-27): there was
    /// `raw * Int64(timestampScale)` here — an overflow stopped the process. Cluster
    /// times that cannot be represented in nanoseconds are already reported as
    /// unreadable by ``MatroskaReader``; what still overflows stays at the limit.
    private func time(_ raw: Int64) -> CMTime {
        CMTime(
            value: NetNumber.saturatedProduct(raw, Int64(clamping: reader.header.timestampScale)),
            timescale: CMTimeScale(NSEC_PER_SEC))
    }
}
