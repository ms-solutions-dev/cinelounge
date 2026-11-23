import AVFoundation
import CoreMedia
import Foundation

/// Continuously repackages a running transport stream into fMP4.
///
/// **This is the piece that turns a chain into a channel.** All the parts
/// existed before: read, extract, package, deliver. But they were all built for
/// a block you have in front of you in full. A channel has no end, no beginning
/// you could wait for, and no guarantee that the information about its content
/// arrives before the content.
///
/// ## The four things that differ here from a file
///
/// **You join in the middle.** The first pictures of a fetch belong to a
/// group whose beginning you never saw — without their predecessor they are
/// meaningless. They are discarded until the first keyframe arrives.
///
/// **The descriptions arrive with the content, not before it.** Only once the
/// parameter sets are there can the writer start — and from then on it is
/// fixed which tracks exist. An audio track appearing later would no longer get
/// a place in the header, so it is briefly waited for.
///
/// **Time overflows and breaks.** ``StreamClock`` handles both.
///
/// **It never stops.** The buffer is a ring buffer, the playlist
/// does not grow along with it, and the writer cuts at keyframes.
public final class TransportRemuxer: @unchecked Sendable {

    /// How long to wait for an audio track before starting without it.
    ///
    /// **Two seconds of material**, not two seconds of wall-clock time: on a
    /// fast fetch, two seconds of wall-clock time may be a minute
    /// of broadcast. It is measured by the timestamps of the stream.
    ///
    /// Why wait at all: if the audio track is not in the header, it will
    /// never exist — and a channel without sound is worse than one that starts
    /// a second later.
    static let audioGracePeriod = CMTime(value: 2, timescale: 1)

    /// The segment store of the HLS path — `nil` if a different sink is attached.
    private let store: SegmentStore?
    private let lock = NSLock()

    private let reader = TransportStreamReader()

    /// **The timestamps of the raw stream, per track** (measurement point 2026-09-04, F-037:
    /// the measurement at the player was blind to what the viewer saw).
    /// Counted are gaps between consecutive PTS values: backwards,
    /// gaps over one second, and the first examples with their position.
    struct Timestamps {
        var last: UInt64?
        var count = 0
        var backwards = 0
        var gaps = 0
        var samples: [String] = []
        mutating func note(_ pts: UInt64) {
            defer { last = pts; count += 1 }
            guard let last else { return }
            let delta = Int64(bitPattern: pts &- last)
            if delta < 0 || delta > 90_000 {
                if delta < 0 { backwards += 1 } else { gaps += 1 }
                if samples.count < 4 {
                    samples.append(
                        String(format: "%+.2f s at %.1f s", Double(delta) / 90_000, Double(last) / 90_000))
                }
            }
        }
        var text: String {
            var s = "\(count) timestamps"
            if backwards > 0 { s += ", \(backwards) backwards" }
            if gaps > 0 { s += ", \(gaps) gaps" }
            if !samples.isEmpty { s += " (" + samples.joined(separator: "; ") + ")" }
            return s
        }
    }

    private var pictureTimestamps = Timestamps()
    private var audioTimestamps = Timestamps()

    /// The timestamp report: picture, audio, continuity errors.
    public var timestampReport: String {
        lock.lock()
        defer { lock.unlock() }
        var split = ["Picture " + pictureTimestamps.text, "Audio " + audioTimestamps.text]
        if reader.continuityErrors > 0 { split.append("\(reader.continuityErrors) continuity errors") }
        if reader.discardedOversize > 0 {
            split.append("\(reader.discardedOversize) oversize packets discarded")
        }
        return "Timestamps: " + split.joined(separator: "; ")
    }
    private var clock = StreamClock()

    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMFormatDescription?
    private var parameterSets = TransportStream.ParameterSets()
    /// How often the channel changed its picture parameters in the middle of the stream.
    public private(set) var parameterChanges = 0

    /// Where the finished packets go — see ``SampleSink``. Created as soon as
    /// the tracks are fixed; until then everything waits in ``waiting``.
    private var sink: (any SampleSink)?
    /// Who builds the sink once the tracks are fixed. The remuxer does not know
    /// whether fMP4 segments or a renderer sit behind it — and should not
    /// know.
    private let makeSink: (CMFormatDescription, CMFormatDescription?) throws -> any SampleSink

    /// Why the last writer build failed — `nil` while one exists or
    /// none was attempted (stall stage 1, 2026-09-24).
    ///
    /// **Until here the reason was lost.** `startIfPossible()` built with `try?`, and
    /// after an audio track or picture parameter change (the TELE MOOS ad break)
    /// ``CMAFWriter`` could reject the new section — then `sink` stayed `nil` forever,
    /// and so did ``writerFailure``, and the stream dried up without a word. The
    /// property that was supposed to report exactly that never could: it asked the writer
    /// that did not exist. See `design/konzept-stall.md`, section 1.2.
    private var sinkFailure: Error?

    /// Reports a writer failure **once** per remuxer.
    private var outageGate = WriterOutage()
    private var hasSeenKeyframe = false

    /// What the picture parameter set says about fields — `nil` while it is missing or the
    /// stream is not H.264. See ``H264Fields``.
    private var fieldInfo: H264Fields.SequenceInfo?
    /// The first field of a pair while its counterpart is awaited.
    private var heldField: (units: [Data], piece: TransportStreamReader.Piece)?
    /// Which half the held field carries — computed when it is held.
    ///
    /// **So that it is not computed twice** (AP7 · L2): the second call
    /// of ``H264Fields/picture(in:info:)`` over the same bytes unpacks the
    /// whole NAL again, and that at fifty fields per second.
    private var heldPicture: H264Fields.Picture?
    /// What the pairing actually did.
    ///
    /// **Deliberately not attached to ``cadence``**: the frame cadence matures at thirty
    /// intervals and caps at two hundred. A tally that
    /// hung on it would be a startup tally over one second of broadcast and would never see
    /// pairs falling apart in the middle of a film.
    private var pairing = PairingTally()
    /// Whether the pairing tally has already been written.
    private var reportedPairing = false
    /// Whether the pairing's breakdown has already been reported — at most once per
    /// session, at the moment it tips over.
    private var reportedPairingDecay = false
    /// How many pictures actually reached the writer.
    private var emittedPictures = 0
    /// The presentation time of the first keyframe — the boundary for the
    /// leading pictures of an open group of pictures.
    private var keyframePTS: UInt64?
    /// How many of them were discarded.
    private var droppedLeadingPictures = 0
    /// And how many audio packets fell under the same boundary. They were not
    /// counted at all before.
    private var droppedLeadingSound = 0
    /// The keyframe's timestamp, as long as the entry point is still to
    /// be reported.
    private var keyframeReportedAt: UInt64?
    /// Time of the first picture — the basis for the wait for audio.
    private var firstVideoTime: CMTime?
    /// The most recently assigned decode time — for the monotonicity stopgap.
    private var lastVideoDecode: CMTime?
    /// Whatever accrues before the writer starts waits here.
    private var waiting = CappedQueue<(time: CMTime, isAudio: Bool, sample: CMSampleBuffer)>(
        cap: BufferCap(count: maximumWaiting, bytes: maximumWaitingBytes),
        size: { BufferCap.size($0.sample) })

    /// How many pictures were discarded until the first keyframe arrived.
    public private(set) var droppedBeforeKeyframe = 0

    /// The highest presentation time (raw) that went out as a picture.
    private var highestPictureTime: UInt64?
    /// The end of the previous burst, as long as the new one still lies below it — see
    /// ``seamOverlap(pts:seam:)``.
    private var seam: UInt64?
    /// Where the new burst picked up, for the seam line.
    private var seamStart: UInt64?
    /// How many picture units arrived twice at the last seam and were discarded.
    public private(set) var seamDiscarded = 0
    /// What happened at the seams — see ``SeamLedger``.
    private var seamLedger = SeamLedger()
    /// How many bytes arrived while a seam was open — see ``seamBytes``.
    private var _seamBytes = 0
    /// How many clock breaks are already in the ledger.
    private var reportedBreaks = 0

    /// The measured frame cadence — the rules are in ``FrameCadence``.
    private var cadence = FrameCadence()
    /// Whether the frame cadence has already gone into the log.
    private var reportedCadence = false

    /// Who writes the segments.
    public enum ChunkWriter: Sendable {
        /// `AVAssetWriter` — cuts only at keyframes. The path for
        /// files whose windows begin at keyframes anyway.
        case system
        /// ``CMAFWriter`` — cuts every half second, at any picture. The
        /// path for channels, see there.
        case own
    }

    /// The remuxer for the HLS path: fMP4 segments into a ``SegmentStore``.
    ///
    /// - Parameter schreiber: See ``ChunkWriter``. **The default is the
    ///   system writer**, because the file sessions need it; the
    ///   live session picks its own.
    public init(store: SegmentStore, writer: ChunkWriter = .system) {
        self.store = store
        switch writer {
        case .system:
            makeSink = { video, audio in
                try FragmentWriter(format: video, audioFormat: audio) { segment in
                    if segment.isInitialization {
                        store.setHeader(segment.data)
                    } else {
                        store.append(segment.data, duration: segment.duration)
                    }
                }
            }
        case .own:
            store.allowParts()
            makeSink = { video, audio in
                try CMAFWriter(format: video, audioFormat: audio) { segment in
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
    }

    /// The remuxer with an arbitrary build plan for the sink — for
    /// checks that want to set up the output themselves.
    init(makeSink: @escaping (CMFormatDescription, CMFormatDescription?) throws -> any SampleSink) {
        store = nil
        self.makeSink = makeSink
    }

    /// The remuxer for an arbitrary sink — the direct renderer.
    ///
    /// **The same remuxer, a different output** (2026-09-03): reading, extracting,
    /// straightening, pairing — all of it stays. Only where the packets go is
    /// different, and that is exactly the difference between twenty seconds of
    /// buffer and one keyframe.
    public init(sink: any SampleSink) {
        store = nil
        makeSink = { _, _ in sink }
        // The renderer path: Dolby arrives there only as PCM — see
        // ``DolbyDecoder``.
        decodesDolby = true
    }

    /// Whether AC-3/E-AC-3 is decoded to PCM here instead of passing through.
    /// With the segment writer, Dolby stays Dolby — AVPlayer decodes it itself.
    private var decodesDolby = false
    private var dolby: DolbyDecoder?
    private var dolbyReported = false

    /// What the stream contains according to its tables. Empty until they are read.
    public var inventory: TransportStream.Inventory { reader.inventory }

    /// Whether the first keyframe has passed — the marker for the startup breakdown.
    public var hasFirstPicture: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasSeenKeyframe
    }

    /// The measured frame cadence in hertz — `nil` while too little has been measured.
    ///
    /// **It is needed two floors up**, for the frame rate registration
    /// on the TV — see ``FrameCadence``.
    public var frameRate: Double? {
        lock.lock()
        defer { lock.unlock() }
        return cadence.rate
    }

    /// How often the audio clock was re-anchored — see ``MPEGAudioTranscoder``.
    ///
    /// **The number that makes an "audio doesn't run cleanly" verifiable.** The audio
    /// times run with the samples and not with the input timestamps;
    /// when the two drift apart, the clock jumps by up to a third of a second. Once
    /// after a reconnect is a seam; every two minutes is a
    /// sync error — and without this number the difference cannot be seen.
    ///
    /// Read under the lock like ``frameRate``: it is written from the network thread,
    /// read from another.
    public var audioReanchors: Int {
        lock.lock()
        defer { lock.unlock() }
        return mpegTranscoder?.reanchors ?? 0
    }

    /// How irregularly the pictures are spaced — see ``FrameCadence/jitter``.
    public var frameJitter: Double? {
        lock.lock()
        defer { lock.unlock() }
        return cadence.jitter
    }

    /// What the pairing has done up to here.
    ///
    /// Read under the lock like ``frameRate``: it is fed from the
    /// network thread, read from another.
    var pairingTally: PairingTally {
        lock.lock()
        defer { lock.unlock() }
        return pairing
    }

    /// Whether the sink exists — that is, whether anything is going out yet.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sink != nil
    }

    // MARK: - Füttern

    /// Takes the next chunk from the network.
    ///
    /// **The only way in.** Whether the chunks are 16 kilobytes or a megabyte,
    /// whether they come regularly or in bursts, does not matter —
    /// the boundaries of the format have nothing to do with the boundaries of the
    /// chunks anyway.
    public func feed(_ chunk: Data) {
        let pieces = reader.read(chunk)
        guard !pieces.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if seam != nil { _seamBytes += chunk.count }
        for piece in pieces { handle(piece) }
        // **Breaks go into the ledger immediately, not only at session end** (AP64): the
        // tally in ``reportPairingBalance()`` only comes when the viewer
        // switches away — a report pulled in the middle of the broadcast
        // saw none of it.
        if clock.breakCount > reportedBreaks {
            reportedBreaks = clock.breakCount
            if let row = seamLedger.recordBreak(number: clock.breakCount, note: clock.lastBreak) {
                Diagnostics.playbackStep(row, since: nil)
            }
        }
        startIfPossible()
        drainWaiting()
        reportCadenceIfReady()
        reportPairingDecayIfNeeded()
    }

    /// What arrived while a seam was open — the overlap that gets discarded.
    ///
    /// Counted per chunk, not per packet: the last chunk of a seam already carries
    /// the start of the new piece. That is enough for the stall watchdog; it measures in
    /// seconds of broadcast, and the error is below one chunk.
    public var seamBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _seamBytes
    }

    /// The writer's error, if it has one — for diagnosis.
    ///
    /// **A failed AVAssetWriter swallows everything further without a word**:
    /// every append silently returns `false`, and from outside that looks
    /// like "the cutter no longer produces" (the suspicion of 2026-08-15).
    public var writerFailure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return sink?.failure ?? sinkFailure
    }

    /// Cuts off the running segment immediately.
    ///
    /// **To be called on a disconnect.** What the writer has just started,
    /// nobody picks up otherwise: the next fetch begins at a new
    /// keyframe. A cut here saves what is already there.
    @discardableResult
    public func flushSegment() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // **After the cut the rule applies again: keyframe first** (the second
        // finding of 2026-08-15, proven locally on the real channel). The next
        // segment must begin with a sync sample — otherwise the writer dies
        // without a word on `-11876` and swallows everything further. The provider's new
        // burst does usually begin at a keyframe,
        // but "usually" is no promise: the same waiting logic as at
        // session start, picture and audio alike.
        //
        // **And the held field falls with it.** It comes from BEFORE the
        // disconnect; after rejoining it would find a partner that lies seconds
        // later, and the pair would carry the old timestamp. It is counted
        // as an orphan — the tally is meant to see the disconnect, instead of reporting
        // a number it collected wrongly itself.
        if heldField != nil {
            pairing.orphans += 1
            heldField = nil
            heldPicture = nil
        }
        hasSeenKeyframe = false
        // **And the entry counters start over** (AP6 · Q7): after a
        // disconnect they kept accumulating, and the line "Entry: 412 units
        // discarded before the keyframe" then merged three entries into
        // one. A number that sums several events is no longer a measurement,
        // but an impression. Here and not in ``drainWaiting()``: the
        // line is written at the first picture **after** the keyframe,
        // and there the numbers must still stand.
        droppedBeforeKeyframe = 0
        droppedLeadingPictures = 0
        droppedLeadingSound = 0
        hasReportedOverflow = false
        // **And note the end** — the next burst picks up before it, see
        // ``seamOverlap(pts:seam:)``.
        seam = highestPictureTime
        seamStart = nil
        seamDiscarded = 0
        guard let sink else { return false }
        sink.discontinuity()
        return true
    }

    /// Finishes a finite stream — a recording, a file.
    ///
    /// For a channel this is never called.
    public func finish() async {
        // The lock is explicitly released **before** waiting:
        // a lock held across an `await` is still held on another thread
        // when the task continues there — and that is not a
        // special case, but the rule.
        let sink = closeInput()
        await sink?.finish()
        // For the finite stream the tally falls here, not only when the
        // object is released. The double call is covered.
        reportPairingBalance()
    }

    private func closeInput() -> (any SampleSink)? {
        lock.lock()
        defer { lock.unlock() }

        for piece in reader.flush() { handle(piece) }
        startIfPossible()
        drainWaiting()
        return sink
    }

    // MARK: - Innen

    private func handle(_ piece: TransportStreamReader.Piece) {
        if piece.kind.isVideo {
            handleVideo(piece)
        } else if piece.kind == .aac {
            handleAudio(piece)
        } else if piece.kind == .ac3 || piece.kind == .eac3 {
            // ALPA SPORT+ (2026-08-16): picture H.264, audio AC-3 — that one used to be
            // silently dropped, and the fallback path ran mute. The building blocks
            // existed long ago (``AC3Audio``, from the MKV path) — the wiring was missing.
            handleAC3(piece)
        } else if piece.kind == .mp2Audio {
            // The Turkish national channels (2026-08-16, "TR ULUSAL HQ/UHD"):
            // picture played, audio was missing — MPEG-1 Layer II, the classic
            // DVB audio format. Apple's decoder can handle it just fine; the old
            // assumption "Apple does not decode MP2" was simply wrong.
            handleMPEGAudio(piece)
        }
        // Everything else — teletext, DVB subtitles, unknown types — is silently
        // dropped here: a channel with picture is better than none.
        //
        // **DTS stood here with the reasoning "could not be repackaged", and both
        // have been wrong since 2026-09-04** It can be repackaged (``DTSTranscoder``),
        // and it cannot arrive here anyway: ``TransportStream/StreamKind``
        // carries the case `dts`, but the program table of a broadcast stream never produces
        // it — it arises solely from the Matroska identifier `A_DTS`
        // (``MatroskaTracks``). Anyone who wants to add the case here first needs
        // detection in the table and a frame splitter that walks along the header
        // — see ``ac3Frames(in:)`` and the 53 holes of 2026-09-04.
    }

    /// The one audio stream that goes into the output.
    ///
    /// **Telve 2 UHD (2026-08-16) reports TWO MP2 tracks in the same program** —
    /// two language versions. Anyone who passes both through mixes two audio tracks
    /// with overlapping times into a single one — audible as gibberish.
    /// It is pinned to the first track that yields its format; the
    /// order of the table names the main version first.
    private var audioPID: UInt16?

    /// Whether this piece belongs to the pinned audio stream (and pins on the
    /// first one).
    private func claimAudio(_ piece: TransportStreamReader.Piece) -> Bool {
        if let audioPID { return piece.pid == audioPID }
        audioPID = piece.pid
        return true
    }

    /// The identifier of the audio stream currently passing through — `nil` before the first.
    public var selectedAudioPID: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return audioPID
    }

    /// Pins a different audio stream — the audio track choice for channels (AP6).
    ///
    /// **Viable only for the renderer output.** The buffer accepts a
    /// format change between two packets; a segment writer has written its
    /// header segment and could not — there the change would mean
    /// a session restart. The caller knows which output it has.
    ///
    /// What belonged to the old track is discarded: format, frame information and
    /// the MP2 transcoder are rebuilt at the next packet of the new track.
    public func selectAudio(pid: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        guard audioPID != pid else { return }
        audioPID = pid
        audioFormat = nil
        ac3Info = nil
        dolby = nil
        mpegInfo = nil
        mpegTranscoder = nil
        lastAudioTime = nil
        audioAxis.reset()
        if store != nil, let current = sink {
            // **With the segment writer the change is a new section** (AP7 ·
            // 4): the running writer closes its segment, the next one
            // is created at the next keyframe with the new audio format and
            // writes its own header segment — the buffer turns that into
            // the break in the list (``SegmentStore/setHeader(_:)``). Until the
            // keyframe, whatever arrives is discarded: a section that begins
            // in the middle of the group of pictures could not be decoded by the player until the
            // next keyframe.
            current.discontinuity()
            sink = nil
            hasSeenKeyframe = false
            keyframePTS = nil
            firstVideoTime = nil
            waiting.removeAll()
            Diagnostics.playbackStep(
                "Audio track switched to PID \(pid) — new section from the next keyframe",
                since: nil)
            return
        }
        sink?.audioTrackChanged()
        Diagnostics.playbackStep("Audio track switched to PID \(pid)", since: nil)
    }

    private var ac3Info: AC3Audio.FrameInfo?

    private func handleAC3(_ piece: TransportStreamReader.Piece) {
        if let pts = piece.pts { audioTimestamps.note(pts) }
        guard claimAudio(piece), let pts = piece.pts else { return }
        if audioFormat == nil, let info = AC3Audio.info(in: piece.data) {
            ac3Info = info
            if decodesDolby {
                // **Dolby to PCM for the renderer** (F-010): the
                // audio renderer received the frames and stayed mute. If the
                // decoder is not available, the frame passes through as before — then
                // the track at least says why it stays silent.
                let attempt = Result { try DolbyDecoder(checking: info) }
                switch attempt {
                case .success(let decoder):
                    dolby = decoder
                    audioFormat = decoder.outputDescription
                    if !dolbyReported {
                        dolbyReported = true
                        Diagnostics.playbackStep("Audio: \(decoder.summary)", since: nil)
                    }
                case .failure(let obstacle):
                    audioFormat = try? AC3Audio.formatDescription(for: info)
                    if !dolbyReported {
                        dolbyReported = true
                        let reason =
                            (obstacle as? DolbyDecoder.Obstacle)?.rawValue ?? String(describing: obstacle)
                        Diagnostics.playbackProblem(
                            "Audio: \(info.isEnhanced ? "E-AC-3" : "AC-3") — \(reason); "
                                + "the renderer gets the frames raw and may stay silent",
                            since: nil)
                    }
                }
            } else {
                audioFormat = try? AC3Audio.formatDescription(for: info)
            }
        }
        guard let audioFormat, let info = ac3Info, soundBelongsToPicture(pts) else { return }

        let frameDuration = CMTime(
            value: CMTimeValue(info.samplesPerFrame), timescale: CMTimeScale(info.sampleRate))
        let start = audioAxis.start(
            packetTime: clock.time(for: pts, track: .audio), frameDuration: frameDuration)
        var last: CMTime?
        defer { if let last { audioAxis.next(after: last, frameDuration: frameDuration) } }
        for (index, frame) in Self.ac3Frames(in: piece.data).enumerated() {
            let time =
                start
                + CMTime(
                    value: CMTimeValue(index * info.samplesPerFrame),
                    timescale: CMTimeScale(info.sampleRate))
            last = time
            if let dolby {
                if let sample = dolby.decode(frame, at: time) { enqueue(sample, at: time, isAudio: true) }
                continue
            }
            guard
                let sample = try? AudioAssembly.sampleBuffer(
                    payload: frame, at: time,
                    duration: CMTime(
                        value: CMTimeValue(info.samplesPerFrame),
                        timescale: CMTimeScale(info.sampleRate)),
                    format: audioFormat)
            else { continue }
            enqueue(sample, at: time, isAudio: true)
        }
    }

    private var mpegInfo: MPEGAudio.FrameInfo?
    private var mpegTranscoder: MPEGAudioTranscoder?

    /// How many MPEG frames went in and AAC packets came out — the
    /// path must vouch for itself (lesson of 2026-08-16: it ran mute,
    /// and the track reported "ran through").
    private var mpegFramesIn = 0
    private var mpegPacketsOut = 0
    private var mpegReported = false

    private func handleMPEGAudio(_ piece: TransportStreamReader.Piece) {
        if let pts = piece.pts { audioTimestamps.note(pts) }
        guard claimAudio(piece), let pts = piece.pts else { return }
        if audioFormat == nil, mpegTranscoder == nil, let info = MPEGAudio.info(in: piece.data) {
            // With the **reason**, not just the failure: on 2026-08-22 the diagnosis said
            // six times "this device has no transcoder", and
            // afterwards it was open whether the MP2 decoder or the AAC encoder is missing —
            // two findings, two completely different ways out.
            let attempt = Result { try MPEGAudioTranscoder(checking: info) }
            if case .success(let transcoder) = attempt {
                mpegInfo = info
                mpegTranscoder = transcoder
                // The AAC form is registered: the writer receives what
                // it knows — the HLS profile does not accept MPEG audio.
                audioFormat = transcoder.outputDescription
                // With the path that produces the audio: on tvOS Apple's
                // Layer II decoder is missing, and then our own one works — on the
                // TV it must be readable which one it was.
                Diagnostics.playbackStep(
                    "Audio: MPEG audio layer \(info.layer), \(info.sampleRate) Hz → AAC"
                        + (transcoder.usesOwnDecoder ? " (own decoder)" : ""),
                    since: nil
                )
            } else if case .failure(let obstacle) = attempt, !mpegReported {
                // **Fail loudly, do not stay mute**: without this line
                // a missing decoder cannot be told apart from a mute
                // channel.
                mpegReported = true
                let reason =
                    (obstacle as? MPEGAudioTranscoder.Obstacle)?.rawValue
                    ?? String(describing: obstacle)
                Diagnostics.playbackProblem(
                    "Audio: MPEG audio layer \(info.layer), \(info.sampleRate) Hz, "
                        + "\(info.channels) channels — \(reason) on this device. "
                        + "The channel stays silent",
                    since: nil
                )
                // **The catalog right next to it.** The probe for it already existed,
                // but only via an environment variable when launched through
                // `devicectl` — and so it was unavailable exactly when the case
                // occurred. Here it costs nothing and
                // answers the follow-up question right away.
                ToneProbe.reportCodecInventory()
            }
        }
        guard let audioFormat, let info = mpegInfo, let transcoder = mpegTranscoder,
            soundBelongsToPicture(pts)
        else { return }

        let frameDuration = CMTime(
            value: CMTimeValue(info.samplesPerFrame), timescale: CMTimeScale(info.sampleRate))
        let start = audioAxis.start(
            packetTime: clock.time(for: pts, track: .audio), frameDuration: frameDuration)
        var last: CMTime?
        defer { if let last { audioAxis.next(after: last, frameDuration: frameDuration) } }
        let duration = CMTime(
            value: CMTimeValue(MPEGAudioTranscoder.samplesPerPacket),
            timescale: CMTimeScale(info.sampleRate))
        for (index, frame) in MPEGAudio.frames(in: piece.data).enumerated() {
            let frameTime =
                start
                + CMTime(
                    value: CMTimeValue(index * info.samplesPerFrame),
                    timescale: CMTimeScale(info.sampleRate))
            last = frameTime
            mpegFramesIn += 1
            for packet in transcoder.transcode(frame, at: frameTime) {
                mpegPacketsOut += 1
                guard
                    let sample = try? AudioAssembly.sampleBuffer(
                        payload: packet.payload, at: packet.time,
                        duration: duration, format: audioFormat)
                else { continue }
                enqueue(sample, at: packet.time, isAudio: true)
            }
        }

        // Take stock once after two seconds of material: a transcoder
        // that was accepted and then delivers nothing would otherwise be invisible
        // — and the output header would promise an audio track that never comes.
        if !mpegReported, mpegFramesIn >= 84 {
            mpegReported = true
            if mpegPacketsOut == 0 {
                Diagnostics.playbackProblem(
                    "Audio: transcoder produces nothing — \(mpegFramesIn) frames in, 0 packets out",
                    since: nil
                )
            } else {
                Diagnostics.verbose(
                    "Audio: MPEG→AAC running — \(mpegFramesIn) frames, \(mpegPacketsOut) packets")
            }
        }
    }

    /// Splits a PES packet into whole AC-3 frames — **along the header, not along the
    /// sync word.**
    ///
    /// **The bug that made TELE MOOS and SELA 1 stutter (2026-09-04):** until
    /// here the splitter looked for every `0B 77` in the packet and took it for a
    /// frame start. But the sync word is only one at the beginning of a frame —
    /// in the payload the same byte sequence occurs by chance, at 1536 bytes per
    /// frame in a good two percent of all frames (measured on 90 s of TELE MOOS: 74
    /// of 2975). The frame was cut up there, both halves were too
    /// short and were dropped: 53 holes of 32 ms in 95 s of audio. The system writer
    /// had stretched the holes, our own writer writes them — and at the
    /// live edge the player waits at every hole. AAC was never affected:
    /// ``AudioAssembly/frames(in:)`` has always walked along the header.
    ///
    /// Now the header gives the length, and the length says where the next frame
    /// begins. It searches only if no header stands at the expected position.
    static func ac3Frames(in data: Data) -> [Data] {
        var result: [Data] = []
        let base = data.startIndex
        let count = data.count
        var index = 0
        while index + 6 <= count {
            if data[base + index] == 0x0B, data[base + index + 1] == 0x77,
                let info = AC3Audio.info(in: data[(base + index)..<data.endIndex]),
                let size = info.frameSize, size > 0
            {
                guard index + size <= count else { break }  // angeschnittener Rest
                result.append(data.subdata(in: (base + index)..<(base + index + size)))
                index += size
            } else {
                index += 1
            }
        }
        return result
    }

    private func handleVideo(_ piece: TransportStreamReader.Piece) {
        if let pts = piece.pts { pictureTimestamps.note(pts) }
        var units = TransportStream.units(inElementaryStream: piece.data)
        var piece = piece
        guard !units.isEmpty else { return }

        // The descriptions arrive in the stream — usually before every
        // keyframe. They are collected continuously, so that a set
        // arriving later still counts.
        // **A change of the picture parameters in the middle of the stream is a new
        // section** (F-038, 2026-09-04: TELE MOOS breaks off with "decoding
        // failed −11855", at 24 s of lead, full buffer and
        // clean pairing — the decoder refuses a picture). Until here
        // SPS and PPS were read only up to the first header; if the
        // channel changed them afterwards (ad break, different encoder), the
        // player decoded the new pictures against the old header. Now: detected,
        // reported, and from the next keyframe a new header — as with the
        // audio track change.
        if videoFormat != nil {
            let found = TransportStream.parameterSets(in: units, kind: piece.kind)
            let spsChanged = found.sps.map { $0 != parameterSets.sps } ?? false
            let ppsChanged =
                found.pps.map { $0 != parameterSets.pps && !parameterSets.allPPS.contains($0) } ?? false
            if spsChanged || ppsChanged {
                parameterChanges += 1
                Diagnostics.playbackStep(
                    "Picture parameters changed (\(spsChanged ? "SPS" : "")\(spsChanged && ppsChanged ? "+" : "")\(ppsChanged ? "PPS" : "")), "
                        + "no. \(parameterChanges) — new section from the next keyframe",
                    since: nil)
                if let current = sink, store != nil {
                    current.discontinuity()
                    sink = nil
                }
                videoFormat = nil
                fieldInfo = nil
                parameterSets = TransportStream.ParameterSets()
                hasSeenKeyframe = false
                keyframePTS = nil
                firstVideoTime = nil
                waiting.removeAll()
            }
        }

        if videoFormat == nil {
            let found = TransportStream.parameterSets(in: units, kind: piece.kind)
            parameterSets.vps = found.vps ?? parameterSets.vps
            parameterSets.sps = found.sps ?? parameterSets.sps
            parameterSets.pps = found.pps ?? parameterSets.pps
            // And the further picture parameter sets — without them "TR: NOKTA TV
            // HQ" stayed black. Reasoning at ``ParameterSets/additionalPPS``.
            for extra in found.allPPS where !parameterSets.allPPS.contains(extra) {
                parameterSets.additionalPPS.append(extra)
            }

            guard parameterSets.isComplete(for: piece.kind),
                let format = try? SampleAssembly.formatDescription(
                    from: parameterSets, kind: piece.kind)
            else { return }

            // **Does this stream carry fields?** It says so in the picture set and
            // nowhere else — the reasoning and measurement are at ``H264Fields``.
            //
            // **Read before the description, not after** (AP2 · U1): the
            // answer belongs in the description itself. Before, the header stood here
            // first and then the question — and the decoder was told a
            // full frame where two offset fields arrived.
            if piece.kind == .h264, let sps = parameterSets.sps {
                fieldInfo = H264Fields.sequenceInfo(fromSPS: sps)
            }
            videoFormat =
                fieldInfo?.allowsFields == true
                ? SampleAssembly.withFields(format) : format

            // **What is in the header belongs in the track** (review agent 2026-08-23):
            // that a channel carries two picture parameter sets and we took only one
            // along was the cause of a permanently black picture — and
            // could not be seen from the diagnosis. The agent needed its own
            // capture for it; this line would have been enough.
            //
            // And the line now says only what it **knows**. Its predecessor
            // claimed "fields are paired" solely on the basis of the
            // picture set — with MBAFF the same would be there, and nothing would
            // be paired. Whether pairing really happens is told by the frame cadence further down.
            Diagnostics.playbackStep(
                "Picture header: \(parameterSets.allPPS.count) picture parameter sets, "
                    + (fieldInfo?.allowsFields == true
                        ? "picture set allows fields" : "progressive"),
                since: nil
            )
        }
        guard let videoFormat else { return }

        // **Two fields are one picture.** The provider sends them as two
        // PES packets with their own timestamps, 20 ms apart; in an
        // MP4 file they belong in ONE sample. Without this step
        // VideoToolbox got fifty half pictures per second and on
        // some channels drew nothing at all (on-device finding 2026-08-23).
        if let fieldInfo, fieldInfo.allowsFields {
            let step = Self.paired(
                units: units, piece: piece, info: fieldInfo, held: &heldField,
                heldPicture: &heldPicture, tally: &pairing)
            switch step {
            case .wait:
                return
            case .whole(let joined, let start):
                units = joined
                piece = start
            }
        }

        // **Before the first keyframe everything is discarded.** Whoever joins in the middle of a
        // group of pictures has pictures that refer to a predecessor
        // that never existed here. The decoder turns that into blocks or into
        // nothing — both look like a broken channel.
        // **What arrives twice at the seam has already played** — see
        // ``seamOverlap(pts:seam:)``. Before the keyframe gate, so that
        // a keyframe from the overlap does not re-enter either.
        if !hasSeenKeyframe, let seam, let pts = piece.pts {
            if Self.seamOverlap(pts: pts, seam: seam) {
                if seamStart == nil { seamStart = pts }
                seamDiscarded += 1
                return
            }
            if SampleAssembly.isKeyframe(units, kind: piece.kind) {
                self.seam = nil
                // Close the gap for picture and audio together — see
                // ``StreamClock/closeSeam(ticks:)``. Only a real seam: whatever
                // jumps further than ten seconds is left to the clock.
                let advanceTicks = Self.circularTicks(from: seam, until: pts)
                if advanceTicks > 0, advanceTicks <= 10 * 90_000 {
                    clock.closeSeam(ticks: advanceTicks)
                }
                if let row = seamLedger.seam(
                    back: seamStart.map { Self.circularDistance(from: $0, until: seam) },
                    discarded: seamDiscarded,
                    next: Self.circularDistance(from: seam, until: pts))
                {
                    Diagnostics.playbackStep(row, since: nil)
                }
                seamStart = nil
            }
        }

        if !hasSeenKeyframe {
            guard SampleAssembly.isKeyframe(units, kind: piece.kind) else {
                droppedBeforeKeyframe += 1
                return
            }
            hasSeenKeyframe = true
            keyframePTS = piece.pts

            // **An open group of pictures reaches back past its start**
            // (review agent 2026-08-23, "TR: NOKTA TV HQ" and "TR: MERCAN TV HQ").
            //
            // These channels send no IDR, but an I picture with a set before it —
            // correctly detected since the ALPA finding of 2026-08-16. After it, however, come
            // pictures that are presented BEFORE the I and refer to predecessors
            // that never existed here. VideoToolbox reports `-12350` for them,
            // and **AVAssetReader then discards the whole track** — even
            // if all the other pictures are good. Measured: with these pictures
            // the file was rejected, without them 165 of 165 ran cleanly.
            keyframeReportedAt = piece.pts
        }

        // Everything that would be shown before the keyframe is dropped — see above.
        //
        // **And only the entry group of pictures** (review agent 2026-08-23): the boundary
        // compares raw 33-bit stamps. On overflow — after 2³³/90000 =
        // **26.5 hours** — or on a timestamp break by the provider,
        // `pts < keyframePTS` would be permanently true, and picture **and** audio would stop
        // silently. ``StreamClock`` exists for exactly these two events,
        // and this guard bypassed it.
        //
        // As soon as the first packet **beyond** the boundary has passed, it
        // has served its purpose and is cleared.
        //
        // **And "beyond" means truly beyond** (AP3 · V1, expert review
        // 2026-08-24). Here `self.keyframePTS = nil` stood for every packet that
        // did not lie *before* the boundary — so also for the keyframe itself,
        // which lies exactly **on** it. It set the boundary and cleared it again in the
        // same call; the following pictures of the open
        // group of pictures passed unhindered, VideoToolbox reported `-12350`,
        // and `AVAssetReader` then discarded the whole track (NOKTA TV HQ,
        // MERCAN TV HQ). ``soundBelongsToPicture(_:)`` also shrank to
        // `hasSeenKeyframe` as a result, and the audio began 80–200 ms before
        // the picture again.
        //
        // Both fixes of 2026-08-23 were therefore ineffective — and reported
        // themselves as done: "0 pictures and 0 audio packets" stood in about 99
        // entry lines, with a checkmark.
        if let keyframePTS, let pts = piece.pts {
            switch Self.entry(pts: pts, limit: keyframePTS) {
            case .discard:
                droppedLeadingPictures += 1
                return
            case .boundaryFalls:
                self.keyframePTS = nil
            case .kept:
                break
            }
        }

        // **The finding must be reported, otherwise the fix is invisible.**
        //
        // ``droppedLeadingPictures`` was counted up and read by no one —
        // the same disease as with ``DecodeOrder/correctionCount``.
        // A review agent first had to run its own captures to see at all
        // whether the rule takes effect on a channel.
        //
        // It is reported at the first picture AFTER the keyframe: then
        // it is settled how many leading pictures there were.
        if let announce = keyframeReportedAt {
            keyframeReportedAt = nil
            Diagnostics.playbackStep(
                "Entry: \(droppedBeforeKeyframe) units discarded before the keyframe, "
                    + "\(droppedLeadingPictures) pictures and "
                    + "\(droppedLeadingSound) audio packets with an earlier presentation time, "
                    + "keyframe at \(announce)",
                since: nil
            )
        }

        guard let pts = piece.pts,
            var sample = try? SampleAssembly.sampleBuffer(
                for: TransportStream.AccessUnit(pts: pts, units: units),
                kind: piece.kind,
                format: videoFormat)
        else { return }

        // **The decode time travels along if the stream carries it** (Sola Sport
        // Mix, 2026-08-16): with picture reordering the presentation time jumps
        // backwards — that is right, but the writer demands times that rise
        // monotonically in decode order. Without the stamp it
        // took the presentation time as the decode time, died without a word on
        // −11800/−16364 and cut not a single segment out of 37 MB.
        var decode = piece.dts.map { clock.time(for: $0) }
        var time = clock.time(for: pts)

        // **Even supplied decode times cannot be trusted** (Ayaz HD*,
        // 2026-08-16): the provider's transcoder stamps the keyframe at every group boundary
        // with the same decode time as the last B picture before it.
        // The writer demands strictly rising times and died without a word on
        // −16364 — before the first segment, the channel stayed black. The
        // two stopgaps from ``DecodeOrder``, in the same order:
        // first force upwards, then adjust the presentation.
        var order = decode ?? time
        if let last = lastVideoDecode, order <= last {
            order = last + CMTime(value: 1, timescale: order.timescale)
            decode = order
            if order > time { time = order }
        }
        if let last = lastVideoDecode { cadence.add((order - last).seconds) }
        lastVideoDecode = order

        guard let restamped = Self.restamped(sample, to: time, decode: decode) else { return }
        sample = restamped

        // Ordering is by the decode time — it is the order in
        // which the writer needs the pictures; the presentation time may jump
        // with B pictures.
        if firstVideoTime == nil { firstVideoTime = order }
        enqueue(sample, at: order, isAudio: false)
        // The denominator of the tally: what ACTUALLY went out, not what came in.
        emittedPictures += 1
        if highestPictureTime.map({ Self.entry(pts: pts, limit: $0) == .boundaryFalls }) ?? true {
            highestPictureTime = pts
        }
    }

    /// The result of a pairing step.
    enum Pairing: Equatable {
        /// First field — held back, its counterpart is missing.
        case wait
        /// A whole picture: the merged units and the packet whose
        /// timestamp applies.
        case whole(units: [Data], piece: TransportStreamReader.Piece)
    }

    /// What the pairing actually did — not what the picture set allows.
    ///
    /// **Separate from ``FrameCadence``**, and that is the whole point: the
    /// frame cadence matures at thirty intervals and caps at two hundred.
    /// A tally that hung on it would be a startup tally over one second of
    /// broadcast and would never see pairs falling apart in the middle of a film.
    struct PairingTally: Equatable {
        /// Zwei Halbbilder zu einem Bild zusammengelegt.
        var pairs = 0
        /// Fields that never got their partner.
        var orphans = 0
        /// Access units that were already a whole picture.
        var wholePictures = 0
        /// Access units whose slice header could not be read.
        ///
        /// **Do not offset against ``wholePictures``.** ``H264Fields/picture(in:info:)``
        /// returns `nil` for an unreadable header, and the pairing passes them
        /// through like a whole picture — right as behavior, wrong as
        /// information: "progressive" and "we cannot read the header" are
        /// two findings with two different ways out.
        var unreadable = 0
        /// Fields that came in — denominator of the field rate.
        var fields = 0
    }

    /// Combines two fields into one picture.
    ///
    /// **As a pure computation, so that it can be checked without a channel.** The state
    /// (`held`) travels along as `inout` instead of living in the class.
    ///
    /// Three rules, each from a case:
    ///
    /// 1. **A whole picture passes through unchanged.** Even a stream that
    ///    may carry fields does not send them throughout.
    /// 2. **The timestamp of the FIRST field applies.** The second lies 20 ms
    ///    later; if you took that one, the picture would run half a picture early.
    /// 3. **Two equal fields in a row replace the first**, instead of
    ///    marrying it. Happens when joining in the middle of a pair and after a
    ///    disconnect — otherwise a foreign field would stick to a picture forever.
    ///
    /// Without a counter — a thin wrapper over the counting version. `inout`
    /// does not allow a default value, and whoever does not need the tally should
    /// not have to invent a counter.
    static func paired(
        units: [Data],
        piece: TransportStreamReader.Piece,
        info: H264Fields.SequenceInfo,
        held: inout (units: [Data], piece: TransportStreamReader.Piece)?
    ) -> Pairing {
        var ignored = PairingTally()
        var half: H264Fields.Picture?
        return paired(
            units: units, piece: piece, info: info, held: &held, heldPicture: &half,
            tally: &ignored)
    }

    /// Combines two fields into one picture and records what actually
    /// happened — the rules are at the version without `tally`.
    static func paired(
        units: [Data],
        piece: TransportStreamReader.Piece,
        info: H264Fields.SequenceInfo,
        held: inout (units: [Data], piece: TransportStreamReader.Piece)?,
        heldPicture: inout H264Fields.Picture?,
        tally: inout PairingTally
    ) -> Pairing {
        let picture = H264Fields.picture(in: units, info: info)
        guard let picture, picture != .frame else {
            // **Two different findings, one behavior.** Both are passed through;
            // counted separately, otherwise a slipped bit reader
            // reads like a progressive channel.
            if picture == nil { tally.unreadable += 1 } else { tally.wholePictures += 1 }
            // Whole picture — and a field still held is thereby orphaned.
            if held != nil { tally.orphans += 1 }
            held = nil
            return .whole(units: units, piece: piece)
        }
        tally.fields += 1

        guard let waiting = held else {
            held = (units, piece)
            heldPicture = picture
            return .wait
        }

        // Does the counterpart fit? The same half means: the held field has
        // lost its partner.
        //
        // **The half of the held field is already known** (AP7 · L2): it
        // was computed when it was held. Here a second call stood over
        // the same bytes — and that unpacks the whole NAL, at fifty
        // fields per second.
        let waitingPicture = heldPicture ?? H264Fields.picture(in: waiting.units, info: info)
        guard waitingPicture != picture else {
            // Here a field loses its partner — the number by which
            // the breakdown becomes visible at all.
            tally.orphans += 1
            held = (units, piece)
            heldPicture = picture
            return .wait
        }

        tally.pairs += 1
        held = nil
        heldPicture = nil
        return .whole(units: waiting.units + units, piece: waiting.piece)
    }

    /// Whether an audio packet belongs to the picture that is already running.
    ///
    /// **The audio must respect the same boundary as the picture** (review agent 2026-08-23).
    /// Since the leading pictures of an open group of pictures are dropped,
    /// the audio began **80 to 200 ms before** the first picture on every channel: the
    /// picture guard checks `pts < keyframePTS`, the three audio paths checked only
    /// `hasSeenKeyframe`. Measured on four captures — NOKTA TV and MERCAN TV
    /// −200 ms each, Telve 3 −120 ms, AYAZ 2 −80 ms.
    ///
    /// No lip-sync offset (the timestamps stay right), but a
    /// fraction of a second of audio over black at every entry and after every
    /// disconnect. A side effect of the fix that the same run found
    /// right along.
    /// **It does not clear the boundary itself** — the picture path does that as soon as its
    /// first packet beyond it has passed. As long as it stands, it applies to
    /// both tracks; afterwards to neither.
    private func soundBelongsToPicture(_ pts: UInt64) -> Bool {
        guard hasSeenKeyframe else { return false }
        guard let keyframePTS else { return true }
        guard Self.entry(pts: pts, limit: keyframePTS) == .discard else { return true }
        droppedLeadingSound += 1
        return false
    }

    /// What happens to a packet at entry — the rule on its own, so that
    /// it can be checked.
    ///
    /// **It was wrong twice, and both times it looked "fixed"**
    /// (2026-08-23 and the finding above it on 2026-08-24). A rule that lives in three
    /// lines of source code and zero lines of checks is exactly the kind that
    /// defuses itself.
    enum EntryPoint: Equatable {
        /// Before the boundary — the packet belongs to a group of pictures that never
        /// existed here.
        case discard
        /// On the boundary — the keyframe itself. It passes through, **and the
        /// boundary stays in place**.
        case kept
        /// Beyond the boundary — it has served its purpose.
        case boundaryFalls
    }

    ///
    /// **The comparison is made in the 33-bit circle, not raw** (remuxer review, suspicion 1,
    /// 2026-09-27). Here `pts < limit` stood. If the counter wraps exactly between the
    /// entry keyframe and the next picture — once in 26.5 hours,
    /// but then for everyone who tunes in at that moment —, every following picture was
    /// raw "before" the boundary: picture and audio were discarded until the connection dropped.
    /// Now the shorter way around the circle counts: whatever lies up to half a turn
    /// behind the boundary lies before it.
    static func entry(pts: UInt64, limit: UInt64) -> EntryPoint {
        let wrapRange: UInt64 = 1 << 33
        let spacing = (pts &- limit) & (wrapRange - 1)
        if spacing == 0 { return .kept }
        return spacing < wrapRange / 2 ? .boundaryFalls : .discard
    }

    /// Whether a picture after the disconnect still falls into the time that already went out.
    ///
    /// **The edge starts every new burst at the last keyframe BEFORE the end
    /// of the previous one** (proven 2026-08-15, seen on the TV 2026-10-02: "Telve runs
    /// 20 s, jumps back 8 s, runs 20 s again"). ``StreamClock`` smoothed the
    /// jump back as a break — right for the writer, wrong for the
    /// viewer: the doubled seconds were **appended at the end** and played
    /// a second time. Now everything is discarded up to the first keyframe behind the end;
    /// the price is at most one group of pictures that is skipped.
    ///
    /// **Only up to 60 s back.** Whatever lies further back is not a burst startup,
    /// but a new timeline (feed switch) — that belongs to the clock as
    /// before. Exactly on the end (distance zero) counts as doubled.
    static func seamOverlap(pts: UInt64, seam: UInt64) -> Bool {
        let wrapRange: UInt64 = 1 << 33
        return (seam &- pts) & (wrapRange - 1) < 60 * 90_000
    }

    private func handleAudio(_ piece: TransportStreamReader.Piece) {
        if let pts = piece.pts { audioTimestamps.note(pts) }
        guard claimAudio(piece) else { return }
        let frames = AudioAssembly.frames(in: piece.data)
        guard let first = frames.first else { return }

        if audioFormat == nil {
            audioFormat = try? AudioAssembly.formatDescription(for: first.header)
        }
        guard let audioFormat, let pts = piece.pts else { return }

        // Audio before the first keyframe is audio for a picture that does not
        // come. It would lie before the session start and be discarded anyway.
        // And **the same boundary as with the picture** — see
        // ``soundBelongsToPicture(_:)``.
        guard soundBelongsToPicture(pts) else { return }

        let frameDuration = CMTime(
            value: CMTimeValue(AudioAssembly.samplesPerFrame),
            timescale: CMTimeScale(first.header.sampleRate))
        let start = audioAxis.start(
            packetTime: clock.time(for: pts, track: .audio), frameDuration: frameDuration)
        var last: CMTime?
        defer { if let last { audioAxis.next(after: last, frameDuration: frameDuration) } }
        for (index, frame) in frames.enumerated() {
            let offset = CMTime(
                value: CMTimeValue(index * AudioAssembly.samplesPerFrame),
                timescale: CMTimeScale(frame.header.sampleRate))
            let time = start + offset
            last = time
            guard
                let sample = try? AudioAssembly.sampleBuffer(
                    for: frame, at: time, format: audioFormat)
            else { continue }
            enqueue(sample, at: time, isAudio: true)
        }
    }

    /// How many packets at most wait for the writer.
    ///
    /// **The finding** (AP6 · Q7, expert review 2026-08-24): ``waiting`` had
    /// no cap. If the writer is not created — because the
    /// format description is missing or `startWriting` fails —, the
    /// queue at 17 Mbit/s inflow accumulates enough in **under a minute**
    /// to crash the app. Instead of a black picture the
    /// viewer then gets a crash.
    ///
    /// Two thousand packets is a generous figure: the writer is created
    /// at the first keyframe, and until then at 25 pictures per
    /// second rarely more than a few hundred accumulate. Whoever breaks the cap has
    /// no startup problem, but a writer that never comes.
    static let maximumWaiting = 2000
    /// The same in bytes — two thousand UHD pictures would otherwise be a multiple of that,
    /// see ``BufferCap``.
    static let maximumWaitingBytes = 64 << 20

    private func enqueue(_ sample: CMSampleBuffer, at time: CMTime, isAudio: Bool) {
        // **Audio only runs forward.** After a break that the clock smoothed
        // out, the audio packets from before still arrive — interleaved they lie
        // a few tenths behind the picture and therefore carry the offset
        // of the OLD section with the new compensation: they fell back by the
        // whole jump, behind the most recently written audio packet.
        // A writer computed negative durations from them, a renderer played
        // them over the previous ones. They are lost; counted, not played.
        if isAudio {
            if let lastAudioTime, time < lastAudioTime {
                audioBehindClock += 1
                return
            }
            lastAudioTime = time
        }
        if let sink {
            _ = isAudio ? sink.append(audio: sample) : sink.append(video: sample)
        } else {
            // **The oldest goes, not the newest.** What would play next
            // is the youngest; the oldest is lost anyway once
            // the writer later starts with a session time that lies beyond it.
            // The queue trims itself — by count or bytes.
            guard waiting.append((time, isAudio, sample)) > 0 else { return }
            if !hasReportedOverflow {
                hasReportedOverflow = true
                Diagnostics.playbackProblem(
                    "Remuxer: \(waiting.count) packets (\(waiting.bytes >> 20) MB) waiting for a "
                        + "writer that never comes into being — older ones are discarded",
                    since: nil)
            }
        }
    }

    /// Whether the overflow has already occurred once — once per session is enough.
    private var hasReportedOverflow = false

    /// The time of the most recently passed-on audio packet — see ``enqueue``.
    private var lastAudioTime: CMTime?
    /// See ``AudioAxis`` — the count of frames leads, not the packet time.
    private var audioAxis = AudioAxis()
    /// How many audio packets lay behind the previous one and were therefore dropped.
    private var audioBehindClock = 0

    /// Startet den Abnehmer, sobald feststeht, welche Spuren er bekommt.
    private func startIfPossible() {
        guard sink == nil, let videoFormat, hasSeenKeyframe else { return }

        // Audio is waited for briefly — but not forever. If no viable audio track
        // is registered in the program at all, the waiting is skipped entirely.
        let hasAudioStream = reader.inventory.streams.contains {
            $0.kind == .aac || $0.kind == .ac3 || $0.kind == .eac3 || $0.kind == .mp2Audio
        }
        if audioFormat == nil, hasAudioStream {
            guard let first = firstVideoTime,
                let latest = waiting.last?.time,
                latest - first >= Self.audioGracePeriod
            else { return }
        }

        // **No more `try?`.** The reason for a failed build is kept and
        // reported once; without it the stream dried up silently. The attempt repeats
        // at every chunk — hence the gate and not one line per attempt.
        do {
            sink = try makeSink(videoFormat, audioFormat)
            sinkFailure = nil
        } catch {
            sinkFailure = error
            if let message = outageGate.notify(error) {
                Diagnostics.playbackProblem(message, since: nil)
            }
            return
        }
        reportInventory(videoFormat)
    }

    /// Writes down once WHAT is actually being repackaged.
    ///
    /// **The gap in the on-device test of 2026-08-22:** a dozen channels stuttered, and
    /// from the whole diagnosis it could not be seen whether they carry H.264 or HEVC
    /// and at what picture size. Yet on exactly that hangs the question of whether the
    /// device can decode them in hardware at all — an Apple TV accepts
    /// H.264, but not at every size, and whatever it cannot do in hardware,
    /// it draws visibly sluggishly. One line at startup ends the guessing.
    private func reportInventory(_ videoFormat: CMFormatDescription) {
        let size = CMVideoFormatDescriptionGetDimensions(videoFormat)
        let video = reader.inventory.video?.kind.name ?? "?"
        let audio = reader.inventory.audio?.kind.name ?? "no audio"
        // **And the subtitles that travel along** (AP6, 2026-09-03) — not yet
        // read, but named: the next report thereby says which channels
        // carry teletext or DVB subtitles, before anyone builds a reader.
        let subtitleTracks = reader.inventory.subtitleStreams
        let subtitleList =
            subtitleTracks.isEmpty
            ? ""
            : ", subtitles: "
                + subtitleTracks.map { $0.kind.name + ($0.language.map { " (\($0))" } ?? "") }
                .joined(separator: ", ")
        Diagnostics.playbackStep(
            "Catalog: \(video) \(size.width)×\(size.height), audio \(audio)\(subtitleList)",
            since: nil
        )
    }

    /// The frame cadence, once enough has been measured — once per session.
    private func reportCadenceIfReady() {
        guard !reportedCadence, let rate = cadence.rate, let jitter = cadence.jitter else { return }
        reportedCadence = true
        Diagnostics.playbackStep(
            "Frame cadence: \(rate) Hz, irregularity \(Int((jitter * 100).rounded())) % "
                + "(\(cadence.gaps.count) intervals measured)",
            since: nil
        )
    }

    /// From how many fields on the breakdown may be reported.
    ///
    /// **Five hundred**, that is ten seconds at fifty fields per second.
    /// Below that, the one orphan of the entry determines the share.
    static let pairingDecayMinimumFields = 500

    /// Whether the pairing is breaking down — as a pure computation, checkable without a channel.
    ///
    /// Two to three orphans per session are the normal case: one at entry
    /// in the middle of a pair, one each after a disconnect. Five percent of all
    /// fields it is no longer.
    static func pairingDecays(_ tally: PairingTally) -> Bool {
        tally.fields >= pairingDecayMinimumFields && tally.orphans * 20 > tally.fields
    }

    /// The pairing tally as text — a pure computation, checkable without a channel.
    ///
    /// `nil` if the pairing was never entered: a progressive channel
    /// does not even come here, and "0 pairs, 0 orphans" would be one more
    /// line of noise there — AP1 has enough of that.
    ///
    /// **What is NOT here: "interleaved, not de-interlaced".** The sentence would be
    /// true as soon as `pairs > 0`, and by construction —
    /// ``paired(units:piece:info:held:tally:)`` can do nothing but
    /// interleave. The two rates say the same thing and could just as well say the
    /// opposite: 50 → 50 would be de-interlaced, 50 → 12.5 would mean that every
    /// second pair is lost.
    ///
    /// **The time span covers only the output.** It comes from the first and
    /// the last assigned decode time, whereas `fields` also counts the fields discarded before the
    /// keyframe. Over two hours that is immaterial, in a short run it would push the field rate up —
    /// which is why the line explicitly says "output".
    static func pairingBalance(
        _ tally: PairingTally, pictures: Int, seconds: Double
    ) -> String? {
        guard tally.fields > 0 || tally.wholePictures > 0 || tally.unreadable > 0 else {
            return nil
        }
        let head =
            "Pairing: \(tally.pairs) pairs, \(tally.orphans) orphans, "
            + "\(tally.wholePictures) whole pictures, \(tally.unreadable) unreadable "
            + "slice headers — \(tally.fields) fields became \(pictures) pictures"
        guard seconds >= 1 else { return head + " (too short for a rate)" }
        return head
            + String(
                format: " over %.0f s of output (%.1f fields/s → %.1f pictures/s)", seconds,
                Double(tally.fields) / seconds, Double(pictures) / seconds)
    }

    /// Reports the pairing's breakdown at the moment it tips over.
    ///
    /// **Why alongside the tally:** the tally falls at teardown. A channel that
    /// is still running after two hours would have not a single line about
    /// the pairing until then, and whoever reads the recording out in the middle of the film would find
    /// nothing.
    ///
    /// Runs under the lock of ``feed(_:)`` and therefore takes none itself
    /// — just like ``reportCadenceIfReady()``.
    private func reportPairingDecayIfNeeded() {
        guard !reportedPairingDecay, Self.pairingDecays(pairing) else { return }
        reportedPairingDecay = true
        Diagnostics.playbackProblem(
            String(
                format: "Pairing is decaying: %d of %d fields without a partner (%.0f %%)",
                pairing.orphans, pairing.fields,
                Double(pairing.orphans) * 100 / Double(pairing.fields))
                + " — these fields are lost, their picture is never shown",
            since: nil)
    }

    /// Writes the pairing tally — exactly once per session.
    ///
    /// **When it falls: at teardown, not when the cadence measurement matures.** A
    /// first draft hung on ``FrameCadence/rate``, and that matures at thirty
    /// intervals — the tally would have become a startup tally over about thirty
    /// pictures.
    ///
    /// Public, so that the owner can already pull it on an orderly stop;
    /// otherwise ``deinit`` pulls it. Called twice, it writes once.
    public func reportPairingBalance() {
        lock.lock()
        var line: String?
        var timer: String?
        var dolbyLine: String?
        var seamLine: String?
        var writerLine: String?
        if !reportedPairing {
            reportedPairing = true
            let span = (lastVideoDecode ?? .zero) - (firstVideoTime ?? .zero)
            line = Self.pairingBalance(
                pairing, pictures: emittedPictures, seconds: max(0, span.seconds))
            timer = Self.clockBalance(
                breaks: clock.breakCount, wraps: clock.wrapCount, audioBehind: audioBehindClock,
                notes: clock.breakNotes)
            dolbyLine = dolby?.balance
            seamLine = seamLedger.balance
            writerLine = (sink as? CMAFWriter)?.gapBalance
        }
        // The lock is released BEFORE reporting — the same rule as in
        // ``finish()``: call nothing foreign under a held lock.
        lock.unlock()
        if let line { Diagnostics.playbackStep(line, since: nil) }
        if let timer { Diagnostics.playbackStep(timer, since: nil) }
        if let dolbyLine { Diagnostics.playbackStep(dolbyLine, since: nil) }
        if let seamLine { Diagnostics.playbackStep(seamLine, since: nil) }
        if let writerLine { Diagnostics.playbackStep(writerLine, since: nil) }
    }

    /// The line about the clock — only if it had anything to do. Until here
    /// ``StreamClock`` counted its breaks, and nobody read the number (F-009).
    static func clockBalance(breaks: Int, wraps: Int, audioBehind: Int, notes: [String] = []) -> String? {
        guard breaks > 0 || wraps > 0 || audioBehind > 0 else { return nil }
        var split = ["Clock: \(breaks) breaks smoothed out"]
        if !notes.isEmpty {
            split[0] += " (" + notes.joined(separator: ", ") + (breaks > notes.count ? ", …" : "") + ")"
        }
        if wraps > 0 { split.append("\(wraps) wraps") }
        if audioBehind > 0 { split.append("\(audioBehind) audio packets behind it discarded") }
        return split.joined(separator: ", ")
    }

    deinit {
        // The last safe moment: afterwards there is no one left who could read
        // the numbers.
        reportPairingBalance()
    }

    /// Passes on what is waiting in the order of its time.
    private func drainWaiting() {
        guard let sink, !waiting.isEmpty else { return }

        for entry in waiting.elements.sorted(by: { $0.time < $1.time }) {
            _ = entry.isAudio ? sink.append(audio: entry.sample) : sink.append(video: entry.sample)
        }
        waiting.removeAll()
    }

    /// Puts the straightened time into a finished packet.
    ///
    /// **Necessary because the packet already brings its time along** — from the raw
    /// timestamp of the stream, that is with overflow and break. Building it a
    /// second time would be more expensive than restamping; CoreMedia has a dedicated path for that.
    static func restamped(
        _ sample: CMSampleBuffer, to time: CMTime, decode: CMTime? = nil
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: sample.duration,
            presentationTimeStamp: time,
            decodeTimeStamp: decode ?? .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else { return nil }

        // The keyframe marker does not automatically travel along in a copy with new times
        // — and without it the writer takes every picture to be independent
        // and cuts at the wrong place.
        if let source = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
            let target = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true),
            CFArrayGetCount(source) > 0, CFArrayGetCount(target) > 0
        {
            let from = unsafeBitCast(CFArrayGetValueAtIndex(source, 0), to: CFDictionary.self)
            let to = unsafeBitCast(CFArrayGetValueAtIndex(target, 0), to: CFMutableDictionary.self)
            if let value = CFDictionaryGetValue(
                from, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
            {
                CFDictionarySetValue(
                    to, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), value)
            }
        }
        return copy
    }
}

/// Whether a writer failure has already been reported.
///
/// **Once per remuxer and not per attempt.** `startIfPossible()` runs on every
/// chunk from the network; a build that fails every time would otherwise write dozens of identical
/// lines per second into the error trace — and the one that counts would drown in them.
/// The same idea as `FileReportGate` in the file path.
struct WriterOutage {

    private var reported = false

    /// The sentence for the error trace at the first failure, afterwards `nil`.
    mutating func notify(_ error: Error) -> String? {
        guard !reported else { return nil }
        reported = true
        return "Remuxer: writer is not coming into being (\(error)) — the stream runs into nothing"
    }
}
