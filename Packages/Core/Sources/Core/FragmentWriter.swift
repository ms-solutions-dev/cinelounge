import AVFoundation
import CoreMedia
import Foundation

/// Writes finished picture packets as fragmented MP4 — in memory, without a file.
///
/// **Why `AVAssetWriter` and no muxer of our own.** Writing an MP4 by hand
/// would mean managing header tables, timescales and box nesting ourselves
/// — weeks of work for something Apple already ships and knows better
/// than any reimplementation. This is the shortcut that turns months into weeks:
/// we extract the pictures, Apple packages them.
///
/// **And without a file**, because the target is a running channel. Writing segments to
/// disk only to read them straight back would, with continuous
/// playback, mean constant writing to flash storage
/// that does not hold up forever. `AVAssetWriter` can instead
/// report its segments — they arise in memory and go from there back to
/// AVFoundation.
///
/// ## What comes out here
///
/// First a **header segment** with the stream's descriptions, then
/// continuously **data segments** with pictures. This is exactly the split HLS
/// with fMP4 expects — and exactly why this path is viable where the one via
/// `.ts` segments failed: for those an `AVAssetResourceLoaderDelegate` may
/// only redirect, for fMP4 it may deliver data.
public final class FragmentWriter: NSObject, @unchecked Sendable {

    /// A finished piece, as it goes to AVFoundation.
    public struct Segment: Sendable {
        /// Whether it carries the descriptions (the first) or pictures (all further ones).
        public let isInitialization: Bool
        public let data: Data
        /// How long the piece actually is, in seconds.
        ///
        /// **Reported by the writer and not assumed.** A guessed duration
        /// in the playlist throws AVFoundation off: it calculates
        /// with it, finds something else in the segment and rejects the stream —
        /// with a number instead of a reason.
        public let duration: Double
    }

    /// How long a segment should be.
    ///
    /// **Two seconds**, and that is a trade-off between two evils: short
    /// segments mean more frequent switching and more overhead; long ones mean
    /// that at startup a whole segment has to be finished before the
    /// first picture appears. For a channel the start counts — Apple recommends
    /// six seconds for HLS, but that would be exactly the wait we
    /// want to eliminate here.
    public static let segmentDuration = CMTime(value: 2, timescale: 1)

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let onSegment: @Sendable (Segment) -> Void

    private var isStarted = false
    private var hasFailedToStart = false

    // MARK: - Gleichlauf

    /// Where the video track last stood, in seconds of the stream.
    private var lastVideoSeconds: Double?
    /// Where the audio track last stood.
    private var lastAudioSeconds: Double?
    /// Where both tracks BEGAN — for the coverage measurement of the
    /// Matroska windows (Blibiagraik hunt, 2026-08-16): whether audio is missing at a seam
    /// is shown in "from when to when" of both tracks, not in one alone.
    private var firstVideoSeconds: Double?
    private var firstAudioSeconds: Double?

    /// The coverage of both tracks, from–to in seconds — `nil` as long as one
    /// track has delivered nothing.
    public var coverage: (video: ClosedRange<Double>, audio: ClosedRange<Double>)? {
        guard let firstVideoSeconds, let lastVideoSeconds,
            let firstAudioSeconds, let lastAudioSeconds,
            firstVideoSeconds <= lastVideoSeconds, firstAudioSeconds <= lastAudioSeconds
        else { return nil }
        return (firstVideoSeconds...lastVideoSeconds, firstAudioSeconds...lastAudioSeconds)
    }
    /// Whether the offset has already been reported — one report per incident, not
    /// per packet, otherwise the trace would be full of it within seconds.
    private var reportedSkew = false

    /// From what offset between picture and audio a report is made.
    ///
    /// **Two seconds** (requirement 2026-08-15: if audio is at second 4 and picture
    /// at second 6, something is wrong): the tracks arrive interleaved
    /// and normally lie tenths of a second apart — sometimes the
    /// picture leads, sometimes the audio. Two seconds is far beyond any healthy
    /// interleaving and exactly the order of magnitude from which the viewer
    /// sees the offset (Blibiagraik finding: "after 4–5 minutes picture and audio
    /// drift apart").
    static let skewThreshold: Double = 2
    /// Below what offset an incident counts as ended — with a margin to the
    /// reporting threshold, otherwise the report flickers at the boundary.
    static let skewAllClear: Double = 1

    /// When the sync was last reported — in broadcast time, not in
    /// clock time: at startup, seconds of broadcast arise within a fraction of a
    /// second, and the report should follow the content, not the clock.
    private var lastSkewReport: Double = -.infinity

    /// The trace that decides when the status line says something new —
    /// see ``OffsetTrack``.
    private var skewTrail = OffsetTrack()

    /// The offset between the tracks at the intake funnel — or `nil`
    /// as long as both tracks have not delivered. Positive: the picture leads.
    ///
    /// **At the funnel, not at the screen:** what is measured is what the remuxer
    /// feeds the tracks. An offset here is a delivery or
    /// cutting error and worth a line in the report — an offset only at the
    /// screen with a clean funnel, on the other hand, would point to the player.
    static func skew(video: Double?, audio: Double?) -> Double? {
        guard let video, let audio else { return nil }
        return video - audio
    }

    /// At what interval of broadcast time the sync is reported **even without an incident**.
    ///
    /// **The reporting threshold is no good for observation** (viewer finding
    /// 2026-08-23: "Telve 3 UHD feels slightly out of sync between picture and audio").
    /// Two seconds is right as an *error* threshold — but an offset of
    /// forty to three hundred milliseconds is exactly the range that people
    /// notice and that the diagnosis, by design, did not cover. There was simply
    /// nothing in it as long as nothing was on fire.
    ///
    /// Hence now a **status line** instead of just an alarm: every ten
    /// seconds, where the two tracks stand. That is the number by which audio
    /// slowly drifting away can be recognised before it crosses the threshold.
    static let skewReportInterval: Double = 10

    /// Checks the sync after every packet and reports the incident exactly once.
    private func checkSkew() {
        guard let skew = Self.skew(video: lastVideoSeconds, audio: lastAudioSeconds) else {
            return
        }

        // The regular status line — see ``skewReportInterval``.
        //
        // **It is measured every ten seconds, and only what says something is
        // written** (AP1, 2026-09-02). The raw value is for the most part the
        // interleaving distance and not the offset; it fluctuates
        // within a session by 247 ms on average. ``OffsetTrack`` takes
        // the minimum of the last three samples — the value at which both tracks
        // last stood together — and only reports when it has moved by more
        // than a hundred milliseconds. On the recording of
        // 2026-08-23: 521 → 125 lines.
        let now = lastVideoSeconds ?? 0
        if now - lastSkewReport >= Self.skewReportInterval {
            lastSkewReport = now
            if let offset = skewTrail.report(forItem: skew) {
                Diagnostics.verbose(
                    "Sync: video at \(String(format: "%.1f", lastVideoSeconds ?? 0)) s, "
                        + "audio at \(String(format: "%.1f", lastAudioSeconds ?? 0)) s, "
                        + "offset \(Int(offset * 1000)) ms (smallest of the last "
                        + "\(OffsetTrack.window) samples)"
                )
            }
        }
        if abs(skew) >= Self.skewThreshold, !reportedSkew {
            reportedSkew = true
            Diagnostics.playbackProblem(
                "Sync: \(skew > 0 ? "video" : "audio") leads by "
                    + String(format: "%.1f", abs(skew))
                    + " s (video at \(String(format: "%.1f", lastVideoSeconds ?? 0)) s, "
                    + "audio at \(String(format: "%.1f", lastAudioSeconds ?? 0)) s)",
                since: nil
            )
        } else if abs(skew) < Self.skewAllClear, reportedSkew {
            reportedSkew = false
            Diagnostics.verbose("Sync: back together")
        }
    }
    /// From what length to cut — see ``init(format:audioFormat:segmentDuration:initialStart:onSegment:)``.
    private let cutAfter: CMTime
    /// When the current segment began — the basis for the cut.
    private var lastSegmentStart: CMTime?

    /// - Parameters:
    ///   - format: The description from ``SampleAssembly/formatDescription(from:kind:)``.
    ///     It is handed to the writer instead of guessed from the first packet —
    ///     it has to write the header before the first picture arrives.
    ///   - audioFormat: The same for audio, from
    ///     ``AudioAssembly/formatDescription(for:)``. **To be registered only at setup
    ///     and not later**: the header names all tracks, and it is
    ///     written as soon as the first picture has gone through. An audio track supplied
    ///     later would be in no header and never reach the viewer.
    ///     For MPEG audio sources too, AAC arrives here: the writer can neither
    ///     accept MPEG audio in the HLS profile (`canAdd` rejects) nor
    ///     encode itself alongside passed-through video (−11875) — that is why
    ///     ``MPEGAudioTranscoder`` encodes before this point.
    ///   - segmentDuration: From what length to cut at the next keyframe.
    ///     **Infinite means: not at all** — then a single piece results, and that is the case when the caller
    ///     already knows the boundaries (see ``MatroskaFileSession``).
    ///   - initialStart: What time the first segment carries outward.
    ///     **Zero is right as long as one writer writes the whole stream**
    ///     — for a channel the timeline then begins at it
    ///     instead of at whatever value happens to be present. If, on the other hand, each
    ///     piece is created on its own, its real start time must be given here; otherwise
    ///     every piece claims to begin at zero, and the player cannot
    ///     line them up.
    public init(
        format: CMFormatDescription,
        audioFormat: CMFormatDescription? = nil,
        segmentDuration: CMTime = FragmentWriter.segmentDuration,
        initialStart: CMTime = .zero,
        mediaTimeScale: CMTimeScale = 90_000,
        onSegment: @escaping @Sendable (Segment) -> Void
    ) throws {
        self.onSegment = onSegment
        self.cutAfter = segmentDuration

        // Without an output file: this setup reports its segments instead of
        // storing them. That is exactly why it exists.
        writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        // **We cut ourselves, and that is no frill.** With a fixed
        // cut length, AVFoundation refuses to pass picture and audio through
        // at the same time (code -11875, literally: "does not support passthrough
        // of video track and audio track at same time"). It would offer to
        // re-encode instead — exactly what must never happen here.
        //
        // Cutting ourselves removes the condition and is the right thing anyway:
        // a cut belongs at a keyframe, not to the clock.
        // Where the clock cuts, a segment may begin with a picture
        // that means nothing without its predecessor.
        writer.preferredOutputSegmentInterval = .indefinite
        // The stream's first timestamp is not zero — a channel has been running
        // for hours. Without this hint the segment's timeline would begin
        // at whatever value happens to be present.
        writer.initialSegmentStartTime = initialStart

        // **The video track's timebase** (F-005, 2026-09-04): without a value,
        // AVAssetWriter takes 600 — in which a picture at 23.976 Hz is 25.025 ticks,
        // and 24, 25 and 26 were written. See ``TimeGrid/timebase``.
        writer.movieTimeScale = mediaTimeScale
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.mediaTimeScale = mediaTimeScale
        // **Explicitly NOT real-time data**, and that is a lesson from
        // 2026-08-09: with `true` the writer accepts only what it can handle at the moment
        // and rejects the rest — whoever does not resubmit the rejected pictures
        // writes a gappy picture sequence. AVFoundation accepts it and
        // then discards it with code -12881, without a reason.
        //
        // Here the pictures come from a buffer, not from a camera: they
        // all exist already, and the writer may take its time. The
        // caller makes sure via ``append(_:)`` that none gets lost.
        input.expectsMediaDataInRealTime = false

        if let audioFormat {
            let audio = AVAssetWriterInput(
                mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            audio.expectsMediaDataInRealTime = false
            audioInput = audio
        } else {
            audioInput = nil
        }

        super.init()

        writer.delegate = self
        guard writer.canAdd(input) else {
            throw SampleAssembly.AssemblyFailure.bufferCreationFailed(-1)
        }
        writer.add(input)

        if let audioInput {
            guard writer.canAdd(audioInput) else {
                throw SampleAssembly.AssemblyFailure.bufferCreationFailed(-2)
            }
            writer.add(audioInput)
        }
    }

    /// Accepts a picture — and **loses none**.
    ///
    /// **Why waiting happens here:** an `AVAssetWriterInput` does not accept
    /// at any time. Whoever ignores that and simply carries on writes a
    /// gappy picture sequence — and that costs not one picture but the
    /// whole stream: AVFoundation rejects it later (code -12881) without saying
    /// why. That was the most stubborn error of this stage.
    ///
    /// The wait is short and bounded; if the writer really hangs, a
    /// lost picture is better than a frozen channel.
    @discardableResult
    public func append(_ sample: CMSampleBuffer) -> Bool {
        // **The cut comes before the picture, not after.** Cutting happens at
        // a keyframe — in such a way that this picture is the first of the
        // new segment. Whoever cuts after appending puts the
        // keyframe at the end of the old segment; the following one would then begin
        // with a picture that needs its predecessor, and would stay black until
        // the next keyframe arrives.
        // **The start counts from the FIRST keyframe — even before starting.**
        // `isStarted` stood before the whole check here, and that was a
        // silent double error (on-device finding 2026-08-15, sixth evening test):
        // `isStarted` is set only AT the first packet, so after this
        // point — the first keyframe never set the start, only the
        // second, and cutting happened at the third. Piece 0 was thus always TWO
        // keyframe periods long (20 s with UHD channels): double
        // wait until the picture, and the oversized target duration also clocked
        // the player's list refresh so slowly that it starved at the end of
        // piece 0 while piece 1 had long since been cut.
        if Self.isKeyframe(sample) {
            let time = sample.presentationTimeStamp
            if isStarted, cutAfter.isNumeric, let last = lastSegmentStart,
                (time - last) >= cutAfter
            {
                writer.flushSegment()
                lastSegmentStart = time
            } else if lastSegmentStart == nil {
                lastSegmentStart = time
            }
        }
        lastVideoSeconds = sample.presentationTimeStamp.seconds
        if firstVideoSeconds == nil { firstVideoSeconds = lastVideoSeconds }
        checkSkew()
        return append(sample, to: input)
    }

    /// Whether a picture stands on its own.
    ///
    /// **It is asked through the negation**, because CoreMedia stores it that way:
    /// what is noted is not "is keyframe" but "is not one". If the
    /// note is missing entirely, it is one — so its absence is the right
    /// default value and not the opposite.
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: false) as? [[CFString: Any]],
            let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool
        else { return true }
        return !notSync
    }

    /// Accepts an audio packet.
    ///
    /// **Picture and audio have to come in in order of their time**, not
    /// first all pictures and then all audio. The writer stores both
    /// interleaved and holds back until the other track
    /// has caught up; whoever lets one track run too far ahead accumulates
    /// the lead in memory.
    /// Whether the video input is currently accepting — otherwise the writer waits for
    /// the other track (see ``MatroskaRemuxer``: first the audio, then the picture).
    public var isVideoReady: Bool { input.isReadyForMoreMediaData }

    @discardableResult
    public func appendAudio(_ sample: CMSampleBuffer) -> Bool {
        guard let audioInput else {
            reportFailure("no audio input registered")
            return false
        }
        lastAudioSeconds = sample.presentationTimeStamp.seconds
        if firstAudioSeconds == nil { firstAudioSeconds = lastAudioSeconds }
        checkSkew()
        return append(sample, to: audioInput)
    }

    /// Says once why the writer is not writing.
    ///
    /// **The finding** (AP6 · Q1, expert review 2026-08-24): ``append(_:to:)``
    /// had four `return false` without a line of log. After
    /// `hasFailedToStart` it only returns `false`, the remuxer keeps
    /// running, the buffer stays empty, the channel stays black — until a
    /// **timeout** is reported that it was not. `writer.error`
    /// is available the whole time and is passed through three layers
    /// without anybody picking it up.
    ///
    /// **Once per writer**, not per packet: at 50 fields per second
    /// the truth would otherwise be just another way of filling the log.
    private func reportFailure(_ reason: String) {
        guard !hasReported else { return }
        hasReported = true
        let error = writer.error.map { Diagnostics.explain($0) } ?? "no error object"
        Diagnostics.playbackProblem(
            "Writer: \(reason) — status \(writer.status.rawValue), \(error)",
            since: nil)
    }

    /// Whether the reason has already been stated.
    private var hasReported = false

    private func append(_ sample: CMSampleBuffer, to target: AVAssetWriterInput) -> Bool {
        if !isStarted {
            // **A failed start is remembered.** Without this marker
            // the next packet tries again, and `startWriting` on
            // a failed writer throws an exception instead of returning an
            // error — a failed channel would become a
            // crash of the whole app.
            guard !hasFailedToStart else { return false }
            guard writer.startWriting() else {
                hasFailedToStart = true
                reportFailure("startWriting rejected")
                return false
            }
            // The timeline begins at the first packet, not at zero: the
            // timestamp of a running channel has been counting for hours.
            //
            // **At the first of the two tracks**, and that is why the caller must
            // feed interleaved by time: whatever lies before the session start
            // the writer throws away. If the audio came a tenth of a second
            // before the first picture and the session began at the picture, exactly
            // that tenth of a second would be missing — audible as a clipped beginning.
            // **The decode time is used where there is one.** For
            // material with B-frames it lies before the presentation time; a
            // session that begins only at the presentation throws away the first
            // pictures because their decode time lies before it.
            let start =
                sample.decodeTimeStamp.isValid
                ? min(sample.decodeTimeStamp, sample.presentationTimeStamp)
                : sample.presentationTimeStamp
            writer.startSession(atSourceTime: start)
            isStarted = true
        }

        var waited = 0
        while !target.isReadyForMoreMediaData, waited < Self.maximumWaitMilliseconds {
            Thread.sleep(forTimeInterval: 0.002)
            waited += 2
        }
        if waited > Self.reportedWaitMilliseconds {
            longWaits += 1
            if longWaits <= 3 {
                Diagnostics.playbackStep("Writer waited \(waited) ms for the input", since: nil)
            }
        }
        guard target.isReadyForMoreMediaData else {
            reportFailure(
                "Input not ready after \(Self.maximumWaitMilliseconds) ms")
            return false
        }
        guard target.append(sample) else {
            reportFailure("Packet rejected")
            return false
        }
        return true
    }

    /// How long to wait for a busy writer, in milliseconds.
    /// **Three seconds, not 200 ms** (F-012, 2026-09-04): on the Apple TV
    /// four pieces arose at once while the decoder was running — and the
    /// input was still not ready after 200 ms. The packet was dropped, several times per
    /// minute: a hole in the picture, and with audio an offset that grew with every
    /// dropped frame ("the longer it runs, the more voice
    /// and picture drift apart"). The writer is not bound to real time;
    /// the pieces are created in advance. Waiting is cheap, a hole is not.
    static let maximumWaitMilliseconds = 3000
    /// From what wait time the diagnostics hear about it.
    static let reportedWaitMilliseconds = 200
    private var longWaits = 0

    /// Cuts immediately, without waiting for the next keyframe.
    ///
    /// **For the disconnect.** If the connection breaks, material that was started sits in the
    /// writer that nobody else will pick up: the next request begins at
    /// a new keyframe, and everything before it would be lost. A cut at
    /// this point rescues it — the segment becomes shorter than the others, and
    /// that is permitted as long as it does not exceed the target duration.
    @discardableResult
    public func flushSegment() -> Bool {
        guard isStarted, writer.status == .writing else { return false }
        writer.flushSegment()
        lastSegmentStart = nil
        return true
    }

    /// Marks the video track finished — BEFORE the last audio.
    ///
    /// **The Blibiagraik drift hung on this order** (2026-08-16, convicted on the test
    /// bench): at the end of a file window the audio extends a few packets
    /// past the last picture. The writer interleaves both tracks
    /// and made the audio wait until the picture catches up — which never comes.
    /// ``append(_:to:)`` gave up after its deadline, and at each seam
    /// zero to three audio packets vanished from the output: ~20–60 ms per window, lined up in the
    /// fMP4 without timestamps of their own into a growing shift,
    /// which only a seek (fresh base time) healed. Once the video track
    /// is reported finished, the lock falls away and the audio goes through.
    public func finishPictures() {
        guard isStarted, !hasFinishedPictures else { return }
        hasFinishedPictures = true
        input.markAsFinished()
    }

    private var hasFinishedPictures = false

    /// Finishes and releases the last segment.
    public func finish() async {
        guard isStarted else { return }
        finishPictures()
        audioInput?.markAsFinished()
        await writer.finishWriting()
    }

    public var failure: Error? { writer.error }
}

extension FragmentWriter: AVAssetWriterDelegate {

    public func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        // The report states the actual duration. If it is missing, only the
        // default remains — then the list is approximately right instead of exact.
        //
        // **The video track is what is asked for, not the first one found.** With audio there are
        // two reports in it, and the audio track regularly ends a few
        // milliseconds earlier or later than the picture. Whoever takes whatever comes first
        // writes sometimes the one and sometimes the other duration into the list —
        // an error that adds up across the segments.
        let reports = segmentReport?.trackReports
        let seconds =
            (reports?.first { $0.mediaType == .video } ?? reports?.first)?.duration.seconds
            ?? Self.segmentDuration.seconds

        onSegment(
            Segment(
                isInitialization: segmentType == .initialization,
                data: segmentData,
                duration: seconds.isFinite && seconds > 0 ? seconds : Self.segmentDuration.seconds
            )
        )
    }
}
