import Core
import Diagnose
import Foundation
import JellyfinKit

/// The own remuxer in front of the engine — **setup and fallback chain for both devices**
/// (AP58 R4, report A finding S3).
///
/// **Why it exists.** The file branch existed twice almost character for character, on the TV (`PlayerModel.liveOrFileRemux`)
/// and on the phone (`RepackagerRun`) — and only the TV had
/// the protection against a file that is shorter than its resume point, the playlist with
/// start mark for Continue Watching through the server, and the last attempt for a channel
/// whose remuxer does not start. On the phone a truncated movie ended after one
/// second, and resuming through the server fetched piece 0 first.
///
/// **Three sessions, one switch at the title and not at the delivery path:** the direct renderer and
/// the playlist of a channel read the stream as it comes (``LiveRemuxSession``);
/// a file is fetched in ranges (``MatroskaFileSession``), and that is why one can seek in
/// it.
///
/// **What stays per device** comes in as ``Context``: whether a running preview
/// is taken over (only the TV has one) and where the memory of the scarce
/// suppliers lives.
public enum RemuxStart {

    /// A set-up remuxer.
    nonisolated public struct Started {
        /// The local playlist the engine gets — with the direct renderer the
        /// source itself, because the engine needs an identifier.
        public let address: URL
        /// **To be held while playing.** If the holder goes away, playback loses its
        /// source in the middle of the movie (found on the phone on 2026-09-07: a channel
        /// stood for good after the first teardown).
        public let handle: AnyObject
        /// Ends the session — **must be called**, otherwise it holds on to the one allowed
        /// connection of the provider.
        public let finish: @Sendable () -> Void
        /// The measured frame rate, if the session already knows it.
        public let frameRate: Double?
        /// The startup marks, for the breakdown in the startup line.
        public let marks: StartupMarks?
        /// The buffer for the direct renderer — instead of an address.
        public let samples: SampleQueue?
        /// A corrected start position if the desired one lies beyond the end of the file
        /// — see ``tooShort(startAt:duration:)``.
        public let startAt: TimeInterval?
        /// A sentence for the viewer — that the file is truncated.
        public let hint: String?

        public init(
            address: URL, handle: AnyObject, finish: @escaping @Sendable () -> Void,
            frameRate: Double? = nil, marks: StartupMarks? = nil, samples: SampleQueue? = nil,
            startAt: TimeInterval? = nil, hint: String? = nil
        ) {
            self.address = address
            self.handle = handle
            self.finish = finish
            self.frameRate = frameRate
            self.marks = marks
            self.samples = samples
            self.startAt = startAt
            self.hint = hint
        }

        /// The counters for the stall interpretation — **only the stream has any.**
        public var pulse: (any RepackerPulse)? { handle as? RepackerPulse }
    }

    /// What differs per device.
    nonisolated public struct Context {
        /// Where the memory of the scarce suppliers lives (``SlowSourceMemory``).
        ///
        /// **Read and written at the same store** — on the TV until R4 it was read
        /// from `SecureStore()` and written to the store passed in; in the
        /// checks two truths ran side by side.
        public var store: any KeyValueStore
        /// Whether a running preview of the same channel is taken over (``LiveHandover``).
        public var takesOverPreview: Bool
        /// How large the time-shift ring may grow (``TimeShift/capacity(_:)``).
        public var timeOffset: Int64

        public init(
            store: any KeyValueStore, takesOverPreview: Bool,
            timeOffset: Int64 = TimeShift.capacity(.tv)
        ) {
            self.store = store
            self.takesOverPreview = takesOverPreview
            self.timeOffset = timeOffset
        }
    }

    /// Whether a target gets the playlist with start mark: a recording through the server's
    /// chunking, resumed at a position (F-008: without the mark the player fetched piece
    /// 0 first, forty seconds without a picture).
    public nonisolated static func needsStartMark(_ target: PlaybackTarget) -> Bool {
        target.decision.delivery == .hls && target.kind == .recording && target.startAt > 1
    }

    /// The playlist with start mark — see ``HLSStartRelay``.
    public static func startMark(_ target: PlaybackTarget) async throws -> Started {
        let relay = try await HLSStartRelay(source: target.url, startAt: target.startAt)
        return Started(address: relay.assetURL, handle: relay, finish: { relay.stop() })
    }

    /// Builds the remuxer for a target whose delivery path runs through it.
    public static func build(_ target: PlaybackTarget, environment: Context) async throws -> Started {
        guard target.kind == .live else { return try await file(target) }
        let generous = SlowSourceMemory.load(from: environment.store)
            .needsGenerousWarmup(target.sourceURL)

        if target.decision.delivery == .renderInApp {
            // **The direct renderer** (2026-09-03): it waits for no piece. A parked
            // preview session cannot be taken over here, so it is torn down
            // BEFORE connecting — the 403 lesson of 2026-08-16.
            if environment.takesOverPreview { LiveHandover.shared.abandon() }
            if generous { reportGenerous() }
            let samples = SampleQueue(label: target.title)
            let session = try LiveRemuxSession(
                source: target.url, label: target.title, samples: samples,
                readySeconds: generous ? 4 : LiveRemuxSession.defaultRendererReadySeconds,
                readyTimeout: generous ? 30 : LiveRemuxSession.defaultReadyTimeout)
            try await session.startUp()
            Diagnose.step(.playback, "Remuxer started (direct) — \(session.state)")
            return Started(
                address: target.url, handle: session, finish: { [weak session] in session?.stop() },
                frameRate: session.frameRate, marks: session.marks, samples: samples)
        }

        // Ask at the handoff point first: if the preview has THIS channel running right now,
        // playback continues on its session — instant start, no new
        // connection. A foreign session is torn down in the process, BEFORE connecting.
        if environment.takesOverPreview, let held = LiveHandover.shared.claim(for: target.url) {
            Diagnose.step(.playback, "Remuxer taken over from the preview — instant start")
            let session = held.session
            return Started(
                address: held.playlist, handle: session,
                finish: { [weak session] in session?.stop() },
                frameRate: session.frameRate, marks: session.marks)
        }
        if generous { reportGenerous() }
        // With the channel name as a label: when zapping, the lines of two sessions run
        // interleaved through the track.
        let session = try LiveRemuxSession(
            source: target.url, label: target.title,
            readySegments: generous ? 6 : LiveRemuxSession.defaultReadySegments,
            readySeconds: generous ? 15 : LiveRemuxSession.defaultReadySeconds,
            readyTimeout: generous ? 30 : LiveRemuxSession.defaultReadyTimeout,
            timeOffset: environment.timeOffset)
        let list = try await session.start()
        Diagnose.step(.playback, "Remuxer started (list) — \(session.state)")
        return Started(
            address: list, handle: session, finish: { [weak session] in session?.stop() },
            frameRate: session.frameRate, marks: session.marks)
    }

    private static func reportGenerous() {
        Diagnose.step(.playback, "Large startup buffer — the supply was tight recently")
    }

    /// The file path — **pieces on demand from the Matroska on the server.**
    ///
    /// **The provider identification goes along**, because the provider's filter applies to movies as
    /// to channels. **HEAD only with the media server** (on-device finding 2026-08-23): the provider
    /// answers HEAD with a TCP reset (`-1005`); recognised by the identifier — one with a
    /// hash sign never belongs to the media server. **Directories already walked stay**, the
    /// second start of the same file has its own immediately.
    private static func file(_ target: PlaybackTarget) async throws -> Started {
        let session = try MatroskaFileSession(
            source: HTTPByteRangeSource(
                url: target.url,
                headers: ["User-Agent": LiveRemuxSession.userAgent],
                session: HTTPByteRangeSource.parallelSession,
                allowsHead: !JellyfinSource.isForeignItemID(target.itemID ?? "")),
            audioLanguage: target.preferredAudioLanguage)
        let source = target.url
        session.indexCacheKey = { size in MatroskaIndexCache.key(for: source, size: size) }
        let list = try await session.start()
        let duration = session.totalDuration
        Diagnose.step(
            .playback,
            "Remuxer started (file) — \(Int(duration)) s"
                + (session.truncated == nil ? "" : ", file truncated"))

        // **The viewer is told** (F-027: "keeps crashing when
        // continuing to watch" — it was the end of the truncated file, and only the diagnosis
        // knew).
        let hint = session.truncated.map { cut in
            String(
                format: AppLanguageSetting.word("player.truncatedFile"), clockTime(cut.end),
                clockTime(cut.promised))
        }
        var startAt: TimeInterval?
        if tooShort(startAt: target.startAt, duration: duration) {
            Diagnose.error(
                .playback,
                "Start position \(Int(target.startAt)) s lies beyond the end of the file "
                    + "(\(Int(duration)) s per the index) — the file is truncated, "
                    + "playback starts from the beginning")
            startAt = 0
        }
        // **The frame rate follows instead of being guessed** (AP2 · U4): at the start there is
        // nothing measured; the session reports its number as soon as the first piece is in place.
        return Started(
            address: list, handle: session, finish: { [weak session] in session?.stop() },
            startAt: startAt, hint: hint)
    }

    /// **A start position beyond the end of the file** (F-026, 2026-09-05): the header promises
    /// the runtime, the directory knows the truth. "Bringrarn Piosiaspeit Slausnonspel" is truncated at 55 %,
    /// and exactly there lay the resume position — the engine jumped to the end,
    /// reported `ended` after one second, and the viewer saw a different movie. Five
    /// seconds of leeway: the resume position lies at the cut, the honest end one
    /// piece distance behind it (F-028).
    public nonisolated static func tooShort(startAt: TimeInterval, duration: TimeInterval) -> Bool {
        startAt > 1 && duration > 1 && startAt >= duration - 5
    }

    /// Seconds as `h:mm:ss` — for the notice.
    public nonisolated static func clockTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    // MARK: - The fallback chain

    /// What happens after a failed remuxer — **as a value, so that both devices
    /// walk the same chain.**
    nonisolated public enum Fallback: Equatable, Sendable {
        /// Overtaken: the viewer has moved on, nobody sees the result any more.
        case superseded
        /// A rejection by the provider (on-device finding 2026-08-16, "KOPRU HABER HD": 403 on ALL
        /// paths) — **no further path**, every route runs into the same rejection.
        case rejection(status: Int)
        /// The media server chunks — natively, without a remuxer (product rule 2026-08-15: no
        /// more VLC workarounds). Only where the source can touch the stream.
        case serverChunks(PlaybackDecision)
        /// **The last resort:** Apple's engine on the raw address. If it fails,
        /// the message is honest instead of a second engine — for channels and for files without
        /// a media server.
        case lastAttempt(PlaybackDecision)
    }

    /// The chain after a failure.
    ///
    /// - Parameter quelleStueckelt: whether the source can build the title as a playlist
    ///   (a media server, and the title carries an identifier). Without this check the
    ///   fallback asked the media server for a provider title it has never seen
    ///   (on-device finding 2026-08-15: "VOD content does not play at all any more").
    public nonisolated static func fallback(
        after error: any Error, target: PlaybackTarget, sourceIsChunked: Bool
    ) -> Fallback {
        if error is CancellationError { return .superseded }
        if case LiveRemuxSession.SessionFailure.refused(let status) = error {
            return .rejection(status: status)
        }
        let d = target.decision
        if target.kind != .live, sourceIsChunked {
            return .serverChunks(
                PlaybackDecision(
                    engine: .native, delivery: .hls, reason: d.reason, maxBitrate: d.maxBitrate,
                    maxWidth: d.maxWidth, isBandwidthLimited: d.isBandwidthLimited,
                    audioStreamIndex: d.audioStreamIndex, subtitleStreamIndex: d.subtitleStreamIndex,
                    displaySupportsHDR: d.displaySupportsHDR, startAt: d.startAt))
        }
        return .lastAttempt(raw(d, reason: .containerNotNativelySupported))
    }

    /// Apple's engine on the raw address — the decision for it.
    public nonisolated static func raw(
        _ d: PlaybackDecision, reason: PlaybackDecision.Reason? = nil
    ) -> PlaybackDecision {
        PlaybackDecision(
            engine: .native, delivery: .directPlay, reason: reason ?? d.reason,
            maxBitrate: d.maxBitrate, maxWidth: d.maxWidth, isBandwidthLimited: d.isBandwidthLimited)
    }
}
