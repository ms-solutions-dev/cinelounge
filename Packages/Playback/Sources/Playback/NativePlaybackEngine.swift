import AVFoundation
import Core
import CoreImage
import Foundation
import ImageIO
import Observation

#if os(tvOS)
    import AVKit
    import UIKit
#endif

/// Playback through the system player.
///
/// **The default case, no longer the exception.** A media server delivers everything
/// the engine does not open anyway as HLS with fMP4 segments — the reasoning is in
/// ``PlaybackEngineSelector``. What the engine brings to that and VLC does not:
/// hardware decoding with dynamic HDR metadata, AirPlay, Picture in Picture, smoother
/// scrubbing and a reload mechanism built for unreliable networks.
///
/// What it **cannot** do, and what VLC remains as a silent fallback for: subtitles in
/// ASS format, image subtitles from DVD and Blu-ray — and any kind of growing stream
/// without range access; a progressive remux stream from the server demonstrably
/// could not even be opened here.
///
/// Seeking and resuming are this engine's job with HLS: the playlist covers the full
/// running time, the engine requests the target segment, and the server restarts its
/// ffmpeg there on its own. The engine knows the length from the playlist — the UI
/// additionally keeps the server's metadata as the source of truth.
@MainActor
@Observable
public final class NativePlaybackEngine: PlaybackController {

    public private(set) var status: PlaybackStatus = .idle {
        didSet { if status == .playing { applyDisplayCriteria() } }
    }
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var audioTracks: [PlaybackTrack] = []
    public private(set) var subtitleTracks: [PlaybackTrack] = []
    public private(set) var selectedAudioTrack: PlaybackTrack.ID?
    public private(set) var selectedSubtitleTrack: PlaybackTrack.ID?

    /// Public because the view attaches it to an `AVPlayerLayer`.
    public let player = AVPlayer()

    /// How much lead the engine should aim for, in seconds.
    ///
    /// Thirty seconds bridge the measured dips of the server disk (52 versus 452 Mbit/s
    /// depending on a second reader) without straining the device's memory. Zero would
    /// mean: the engine decides on its own — and on the device it decided tighter than
    /// the connection can bear.
    static let forwardBufferSeconds: TimeInterval = 30

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var bufferObservations: [NSKeyValueObservation] = []
    private var endObservation: NSObjectProtocol?
    private var failObservation: NSObjectProtocol?

    /// The video layer this engine draws to — attached by the drawing surface as soon as
    /// it exists. Weak because the layer belongs to the view: when the surface goes away,
    /// no zombie should live on here.
    private weak var displayLayer: AVPlayerLayer?
    private var displayObservation: NSKeyValueObservation?

    /// Whether the layer has drawn its first frame — the core of
    /// ``firstFrameVisible``. Reset on load and then filled by observing the layer.
    /// Settable within the module because the checks cannot produce the state "frame was
    /// already shown" any other way — a layer never renders in a test run.
    var layerReadyForDisplay = false

    /// When the item reported ready to play — the core of ``readyToPlayAt``.
    ///
    /// The timestamp is created in the KVO callback for `AVPlayerItem.status` and thus in
    /// the event itself; it is queried later and as often as needed. It is reset on load
    /// **and** on stop, so that no previous target passes on its mark. Settable within the
    /// module for the same reason as ``layerReadyForDisplay``: an `AVPlayerItem` never
    /// becomes ready in a test run, so the state "was already ready" cannot be produced
    /// otherwise. Deliberately **not** `@Published` — the startup measurement polls on its
    /// own cadence anyway, and a notification to SwiftUI would trigger a redraw that
    /// shows nothing.
    public internal(set) var readyToPlayAt: Date?

    /// Whether the last failure was AVPlayer's rejection of the partial path — set before
    /// the state change so that the rebuild can already read it.
    public private(set) var rejectedLowLatency = false

    /// How subtitles are drawn — set by the host before loading.
    ///
    /// The engine intervenes only when this differs from the default: without its own
    /// rules the system draws the track according to its accessibility settings, and
    /// those should win as long as the viewer has not chosen anything here.
    var subtitleStyle: SubtitleStyle = .standard

    /// What fraction of the image height is visible — 1 as long as nothing is cropped.
    ///
    /// **Held and not merely passed through**, because an episode change brings a new
    /// item: without this note the line would sit at the bottom again for the next title,
    /// in the cropped margin, even though the image still fills the screen.
    private var subtitleShare: Double = 1

    /// The **measured** frame rate of the content — set by the host before loading.
    ///
    /// If a number is set here, it is announced and nothing is estimated. It comes from
    /// the remuxer, which counted the frame intervals of the real stream before the
    /// player saw the first frame — see ``TransportRemuxer/frameRate``.
    var contentFrameRate: Double?

    /// The preferred audio language — set by the host before loading.
    ///
    /// Used by ``enforceSingleAudioTrack()``: when a container keeps several audio tracks
    /// active at once, it decides which one stays.
    var preferredAudioLanguage: String?

    /// The former holder for the resume point — always empty today.
    ///
    /// The engine seeks immediately on load (see ``load(_:startingAt:)``); the slot stays
    /// only as readable evidence for the checks that pin down the not-remembering.
    private(set) var pendingStart: TimeInterval?

    /// Whether a seek is running — the lock against a second one.
    ///
    /// `AVPlayer.seek` with a second call before the completion callback cancels the
    /// first; anyone who scrubs fast collects nothing but cancelled seeks and ends up
    /// somewhere. So while a seek is running, only the target is remembered, and after the
    /// completion callback the **last** request is executed.
    private(set) var isSeeking = false
    private var queuedSeek: TimeInterval?

    /// When the current item began loading — the only zero point this engine can keep
    /// honestly.
    ///
    /// **Why it holds:** ``load(_:startingAt:)`` is the one place where a new target
    /// comes into being; every state is reset there anyway.
    ///
    /// **Why it must become `nil`:** after ``stop()`` there is no current item. If the
    /// mark stayed, a later line would report a span against a dead target — the same
    /// kind of information this diagnostic is meant to abolish. `Diagnostics.elapsed`
    /// shows a dash without a reference point, and a dash is the truth here.
    ///
    /// `private(set)` instead of `private`, so that the check can see the setting and
    /// clearing — the same design as ``isSeeking``.
    private(set) var loadStartedAt: Date?

    public init() {}

    // **No `deinit` for cleanup.** Teardown lives in `stop()`, for a compelling reason:
    // a `deinit` runs without actor binding, and the observers are not declared
    // sendable — Swift 6 refuses access. The UI calls `stop()` when the player goes
    // away; that is the point at which playback should end anyway.

    // MARK: - Control

    public func load(_ url: URL, startingAt startPosition: TimeInterval) {
        // First, before anything else: a failure while opening should be measured against
        // the start of loading, not against the rest of this method.
        loadStartedAt = Date()
        failureReported = false
        rejectedLowLatency = false
        status = .opening
        position = 0
        duration = 0
        isSeeking = false
        queuedSeek = nil
        // The frame-rate announcement applies per target — the new one measures anew.
        displayCriteriaApplied = false
        pendingRate = nil
        login = FrameRateRegistration()
        rejectedRate = nil
        // **The wait reason belongs to the target too** (AP6 · Q7): it survived the switch,
        // and so the new channel suppressed exactly the first wait message if it happened to
        // be the same as the last one of the previous channel — the only one that says
        // anything during startup.
        lastWaitingReason = nil
        audioTracksEnforced = false
        containerTracksPublished = false
        info = ContainerReport()
        containerAudioFallback = []
        containerSubtitleFallback = []

        // Via `AVURLAsset` instead of the short form: this is the place where the loading
        // behavior can be configured at all, and it makes visible that a network source is
        // being opened here and not a file.
        headCacheLoader?.finish()
        headCacheLoader = nil
        let asset: AVURLAsset
        if Self.usesHeadCache(url), let own = HeadCacheLoader.ownAddress(forItem: url) {
            let since = loadStartedAt
            let loader = HeadCacheLoader(target: url, downloads: .shared) { text in
                Diagnostics.playbackStep(text, since: since)
            }
            asset = AVURLAsset(url: own)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            headCacheLoader = loader
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)
        if Self.stillFrameOn {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            videoOutput = output
        } else {
            videoOutput = nil
        }
        // Aim for a buffer instead of playing on the edge — the number is justified above.
        item.preferredForwardBufferDuration = Self.forwardBufferSeconds
        // Only when different from the default: empty rules would otherwise overwrite the
        // system's accessibility settings with its own defaults.
        applySubtitleRules(to: item)
        // Explicitly, although it is the default: the engine's entire stall behavior hangs
        // on this switch — it waits on its own until the buffer holds again, instead of
        // playing into the void.
        player.automaticallyWaitsToMinimizeStalling = true
        player.replaceCurrentItem(with: item)
        // **Never the dubbed version for YouTube trailers** (2026-11-08) — see ``OriginalAudio``.
        // Applies only where the tracks carry YouTube's marker; everything else stays as it is.
        Task { @MainActor in await OriginalAudio.select(forItem: item) }

        // **Seek immediately, do not wait for the length first.** Before, the start point was
        // remembered and caught up after the first time report — but until then the player
        // loaded from minute zero: the server chunked the beginning, which never interested
        // anyone, and started a second run at the target after the seek. At chapter start
        // this was noticeable as a long wait. A seek on an item that is still loading is
        // explicitly allowed in AVFoundation — it is executed as soon as the item is ready,
        // and the first segment request then goes straight to the target. The safeguard
        // against start points outside the film is provided by the caller via
        // `PlaybackProgress.startPoint` (Core, AP58 R0): the engine does not yet know a
        // length here, and AVFoundation would only clamp a seek that is too large to the
        // end.
        pendingStart = nil
        immediatelyAfterStartJump = startPosition > 1 && Self.isFile(url)
        if startPosition > 1 {
            performSeek(to: startPosition)
        }

        // The layer may still show the last frame of the previous target; its own reset only
        // arrives asynchronously. Without this line the "visible" mark for the new target
        // would already be set on load — the same lie this information is meant to abolish,
        // just from a different source.
        layerReadyForDisplay = false

        // **A new target measures anew.** That is the contract of
        // ``load(_:startingAt:)``, and the information must not depend on the host building a
        // fresh engine per target today anyway — that is its design, not our promise.
        readyToPlayAt = nil

        observe(item)
        player.play()
        startStartupWatch(forItem: url)
    }

    // MARK: - Startup guard (AP69)

    /// Whether the clock was already kicked for this startup — see ``TriggerRule``.
    /// A seek resets it (``finishSeek()``).
    public private(set) var clockKicked = false
    private var startupWatch: Task<Void, Never>?
    /// When the last seek finished — the startup from which ``TriggerRule`` counts.
    private var lastJump: Date?
    private var targetIsFile = false
    /// Tick of the watchdog; the diagnostic line comes every second tick.
    static let startupWatchInterval: Duration = .seconds(1)

    /// **Connection versus demand** (AP69, concept "connection tight"): measured from what
    /// the loader served and the seconds that became buffer from it — see
    /// ``Core/LineMeter``. `nil` without a loader (Jellyfin, HLS) or before the first
    /// honest window.
    public private(set) var lineFinding: LineFinding?
    private var lineMeter = LineMeter()

    /// **Checks while the clock is stopped** — the periodic time observer does not; it
    /// reports only when time is running. That is why on 2026-10-11 no line appeared in the
    /// report for 50 s. While the clock runs, it only measures (``lineFinding``) and no
    /// longer reports; the watchdog ends when the viewer pauses or the target fails.
    private func startStartupWatch(forItem url: URL) {
        startupWatch?.cancel()
        clockKicked = false
        lastJump = nil
        lineFinding = nil
        lineMeter = LineMeter()
        targetIsFile = Self.isFile(url)
        startWatchLoop()
    }

    /// **After a seek from the start** (on-device test 2026-10-11, Laitkrutbai Gezougros): the buffer
    /// is empty as at start, AVPlayer waits for its estimate again, and the help may come
    /// once more — after the same two seconds of patience and three seconds of lead.
    /// The connection is measured anew because the loader counts from the new position;
    /// the last finding stays until a fresh one is there.
    private func startupAfterJump() {
        guard targetIsFile else { return }
        lastJump = Date()
        clockKicked = false
        lineMeter = LineMeter()
        // Always anew: a watchdog that was already finished after a pause still hangs on the
        // field as a completed task — a `nil` check would overlook it.
        startupWatch?.cancel()
        startWatchLoop()
    }

    private func startWatchLoop() {
        let isFile = targetIsFile
        let start = Date()
        startupWatch = Task { [weak self] in
            var cadence = 0
            var playedAlready = false
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.startupWatchInterval)
                guard let self, !Task.isCancelled else { return }
                cadence += 1
                guard self.status == .opening || self.status == .buffering || self.status == .playing
                else { return }
                let leadTime = self.bufferedRange.map { $0.upperBound - max(0, self.position) }
                if let loader = self.headCacheLoader, let previous = self.bufferedRange?.upperBound {
                    self.lineMeter.take(
                        .init(
                            time: Date().timeIntervalSince(start), deliveredBytes: loader.deliveredUpToNow(),
                            loadedSeconds: previous))
                    if let finding = self.lineMeter.finding, finding != self.lineFinding {
                        if finding.tight != (self.lineFinding?.tight ?? false) {
                            Diagnostics.playbackStep(
                                "Line \(finding.tight ? "tight" : "sufficient"): \(LineFinding.mbit(finding.lineMbit)) Mbit/s, movie needs \(LineFinding.mbit(finding.demandMbit)) Mbit/s",
                                since: self.loadStartedAt)
                        }
                        self.lineFinding = finding
                    }
                }
                if self.player.timeControlStatus == .playing {
                    if !playedAlready {
                        playedAlready = true
                        if self.readyToPlayAt != nil, cadence > 2 {
                            Diagnostics.playbackStep(
                                "Clock running — startup guard only measures now", since: self.loadStartedAt)
                        }
                    }
                    // Without a loader there is nothing to measure; with a file the watchdog stays awake
                    // anyway, because the next seek is a new startup.
                    if self.headCacheLoader == nil, !isFile { return }
                    continue
                }
                let readySince = TriggerRule.readySince(
                    ready: self.readyToPlayAt, jump: self.lastJump)
                let waiting = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if cadence.isMultiple(of: 2), self.readyToPlayAt != nil {
                    Diagnostics.playbackStep(
                        TriggerRule.row(
                            readySince: readySince, leadTime: leadTime,
                            waitReason: self.player.reasonForWaitingToPlay?.rawValue,
                            carries: self.player.currentItem?.isPlaybackLikelyToKeepUp ?? false,
                            full: self.player.currentItem?.isPlaybackBufferFull ?? false),
                        since: self.loadStartedAt)
                    self.headCacheLoader?.report()
                }
                if TriggerRule.shouldTrigger(
                    readySince: readySince, leadTime: leadTime, waiting: waiting, isFile: isFile,
                    alreadyTriggered: self.clockKicked)
                {
                    self.clockKicked = true
                    Diagnostics.playbackStep(
                        String(
                            format:
                                "Clock kicked%@: AVPlayer considered the line tight for %.0f s, %.1f s were buffered — stall guard stays on",
                            self.lastJump == nil ? "" : " after jump", readySince ?? 0, leadTime ?? 0),
                        since: self.loadStartedAt)
                    self.player.playImmediately(atRate: 1)
                }
            }
        }
    }

    public func play() {
        player.play()
        status = .playing
    }

    public func pause() {
        player.pause()
        status = .paused
    }

    /// The system player can do it — it has a rate and a pitch correction.
    public var supportsSpeed: Bool { true }

    /// **Only what is already playing.** `player.rate` is also the switch for start and
    /// stop: a rate on a paused film starts it again, and a long press on a still frame
    /// would unexpectedly make it play.
    public func setRate(_ rate: Double) {
        guard status == .playing else { return }
        player.rate = Float(rate)
    }

    public func setSubtitlePosition(visibleFraction portion: Double) {
        guard subtitleShare != portion else { return }
        subtitleShare = portion
        // **On the running item and not only at the next one.** It is filled in the middle of
        // the film; anyone who kept the rule until the next load would shift it to the title
        // where nobody asks about it any more.
        guard let item = player.currentItem else { return }
        applySubtitleRules(to: item)
    }

    public func stop() {
        player.pause()
        headCacheLoader?.finish()
        headCacheLoader = nil

        // The tracking of dropped frames stops as well: it hangs on the item, and without an
        // item it reads the log of a stream nobody sees any more.
        droppedRefresh?.cancel()
        droppedRefresh = nil
        startupWatch?.cancel()
        startupWatch = nil
        droppedFrames.set(nil)

        // Tear down the observers, otherwise they keep running with an empty item and report
        // times for something that is no longer playing.
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObservation {
            NotificationCenter.default.removeObserver(endObservation)
            self.endObservation = nil
        }
        if let failObservation {
            NotificationCenter.default.removeObserver(failObservation)
            self.failObservation = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        bufferObservations.forEach { $0.invalidate() }
        bufferObservations = []

        player.replaceCurrentItem(with: nil)
        // Without a running item there is no span. A leftover zero point would read like a
        // measurement and would not be one.
        loadStartedAt = nil
        status = .idle

        // **The readiness mark goes away too.** In the remuxer path the host keeps this
        // object while `PlayerModel.startEngine` first calls `stop()` and starts the new
        // engine several seconds later. A leftover mark would be that of the previous channel
        // in this gap. The three other pieces of information are safe here by themselves,
        // because they go through `player.currentItem` — this stored timestamp does not.
        readyToPlayAt = nil
        resetDisplayCriteria()
    }

    // MARK: - Frame rate of the TV

    /// The standard frame rates that are announced at all.
    ///
    /// **The measurement lied** (on-device finding 2026-08-16: "Frame rate announced: 28 Hz
    /// … 31 Hz … 16 Hz"): `currentVideoFrameRate` is the MOMENTARY drawing rate — it
    /// collapses while buffering, and the TV was sent to fantasy values. Now only a
    /// standard rate that the measurement comes close to is announced.
    private static let normedRates: [Float] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    /// The last measured stable standard rate — announced only when two ticks in a row
    /// produce the same one.
    private var pendingRate: Float?
    /// What is announced and who said it — including the lock against oscillation
    /// (AP2 · U5). The rules are in ``FrameRateRegistration``.
    ///
    /// **It replaces `appliedRate`**, and that is more than a rename:
    /// `guard appliedRate != nearest` let every mode switch through as long as the number
    /// was merely a different one — 46 announcements in 61 seconds between
    /// 23.976 / 24.0 / 25.0. And conversely it prevented every correction once something
    /// had been booked, even if nothing had been set (AP2 · U3).
    private var login = FrameRateRegistration()
    /// The last **rejected** frame rate — so that the same rejection does not go into the
    /// log on every tick. See ``applyDisplayCriteria()``.
    private var rejectedRate: Float?

    /// Whether playback starts without waiting after the start seek — **only when resuming
    /// a file** (2026-09-30, diagnosis F-049).
    ///
    /// Measured on "Laitkrutbai Gezougros" via iptvhost.example, resumed at 21:30 min: after the seek
    /// 4.6 s to the first frame, almost all of it `EvaluatingBufferingRate` — AVPlayer
    /// estimated the connection before it played. The connection delivers about 10 Mbit/s,
    /// the file needs 3 to 4. Started from the beginning it was 13 ms: there the start
    /// was already in place.
    ///
    /// **Once, and the stall protection stays.** `playImmediately` skips only this first
    /// wait; `automaticallyWaitsToMinimizeStalling` stays on, and if the connection is
    /// not enough after all, the engine pauses briefly and buffers as usual. Not for HLS
    /// and live: there AVPlayer estimates the rendition, and that is exactly what it
    /// should be allowed to do.
    private(set) var immediatelyAfterStartJump = false

    /// The loader for the start and file header from the download store — only for Xtream
    /// films (AP62).
    private var headCacheLoader: HeadCacheLoader?

    /// Whether the file-header cache is switched on — the emergency exit in case it
    /// snags on the device.
    nonisolated(unsafe) public static var headCacheOn = true

    /// **Emergency exit for the still frame** (2026-10-01) — see ``stillFrame(width:)``. An
    /// additional video output on the item is common in AVFoundation; should it interfere
    /// on a device after all (HDR), this one line switches it off.
    nonisolated(unsafe) public static var stillFrameOn = true

    /// The output through which ``stillFrame(width:)`` grabs the displayed frame.
    private var videoOutput: AVPlayerItemVideoOutput?

    /// **The frame currently visible** — as JPEG, for the tile in "Continue Watching"
    /// (requirement 2026-10-01: many titles have no images for their episodes).
    ///
    /// When pausing, the frame is in memory anyway; taking it costs no request and shows
    /// exactly the scene where playback continues. `nil` if the engine has none — then
    /// the other images in the chain apply.
    public func stillFrame(width: CGFloat = 1280) -> Data? {
        guard let output = videoOutput, let item = player.currentItem,
            let buffer = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil)
        else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard image.extent.width > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let reference = min(1, width / image.extent.width)
        return CIContext().jpegRepresentation(
            of: image.transformed(by: CGAffineTransform(scaleX: reference, y: reference)),
            colorSpace: colorSpace,
            options: [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
                    0.7
            ])
    }

    /// **Only Xtream films and episodes as MP4** (AP62): there the `moov` of some files is
    /// at the end, and the provider answers each request sluggishly. Jellyfin, live and the
    /// CL-Server go their way unchanged.
    nonisolated static func usesHeadCache(_ url: URL) -> Bool {
        guard headCacheOn, isFile(url), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return false }
        let split = url.pathComponents
        return split.contains("movie") || split.contains("series")
    }

    /// A file and not a stream — judged by the extension, because the engine knows nothing
    /// more here. A pass-through without an extension (`/stream?address=`) keeps the old
    /// behavior.
    nonisolated static func isFile(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    /// The last reported reason why the clock is waiting — so that only changes go into
    /// the log. See the place where it is read.
    private var lastWaitingReason: AVPlayer.WaitingReason??
    /// Whether the frame-rate announcement for the running item was already done.
    private var displayCriteriaApplied = false

    /// What the container's tracks yield — **preloaded**, not queried.
    ///
    /// **Why this is no longer queried on the spot** (AP15, 2026-09-02):
    /// `AVAssetTrack.formatDescriptions` and `.languageCode` are the old synchronous
    /// properties; Apple deprecated them in tvOS 16 because they **can block the calling
    /// thread** as long as the value is not yet loaded. Here they were queried from the
    /// main thread, when opening a title and then on every tick. That this never stood
    /// out means "the values were mostly already there" — over a weak connection
    /// "mostly" is no promise, and this app regularly runs through a tunnel with
    /// 0.3 Mbit/s.
    ///
    /// Loading now happens once per item via `load(_:)`, asynchronously. If nothing is
    /// there yet, **nothing wrong happens**: the places below do not set their lock and
    /// try again on the next tick — the same behavior they have for a still-empty track
    /// board anyway.
    private struct ContainerReport {
        /// The description of the **video** track — for ``AVDisplayCriteria``.
        var imageFormat: CMFormatDescription?
        /// The language per track, tied to the track's identity.
        var languages: [ObjectIdentifier: String] = [:]
        #if os(tvOS)
            /// What the container itself brings as display criteria — the fallback when no
            /// description can be fetched. Empty for HLS.
            var preset: AVDisplayCriteria?
        #endif
        /// Whether anything has been loaded at all.
        var settled = false
    }
    private var info = ContainerReport()

    /// Loads the track information of an item — once, asynchronously.
    private func loadContainerReport(from item: AVPlayerItem) async {
        var fresh = ContainerReport()
        for track in item.tracks {
            guard let asset = track.assetTrack else { continue }
            if let code = try? await asset.load(.languageCode) {
                fresh.languages[ObjectIdentifier(track)] = code
            }
            // **Only the video track.** Here stood `item.tracks.compactMap { … }
            // .first`, i.e. the first track at all that has a description — and nobody promises
            // the order of the tracks. Handing an AUDIO description to ``AVDisplayCriteria`` is
            // not a frame-rate announcement but a claim about a mode that does not exist.
            // ``videoCodec(of:)`` had long filtered correctly, this place did not.
            guard fresh.imageFormat == nil else { continue }
            guard asset.mediaType == .video else { continue }
            if let descriptions = try? await asset.load(.formatDescriptions) {
                fresh.imageFormat = descriptions.first
            }
        }
        #if os(tvOS)
            fresh.preset = try? await item.asset.load(.preferredDisplayCriteria)
        #endif
        fresh.settled = true
        guard player.currentItem === item else { return }
        info = fresh
    }

    /// Announces the content's frame rate to the TV.
    ///
    /// **On-device finding 2026-08-16: "SpaceX Sports 2 HEVC does not play smoothly"**
    /// — with zero dropouts in the measurement. 50 Hz sports on a 60 Hz output judders by
    /// design: every fifth frame is shown twice. tvOS matches the output for a CUSTOM
    /// player only if the app announces it — and even then only if the viewer has allowed
    /// the matching in the system settings (Video and Audio → Match Content). The
    /// criteria come from the asset itself; once per item is enough.
    private func applyDisplayCriteria() {
        #if os(tvOS)
            guard status == .playing, let item = player.currentItem,
                let manager = Self.displayManager, !manager.isDisplayModeSwitchInProgress
            else { return }

            // **A supplied number beats any estimate.** The remuxer counted the frame intervals
            // of the real stream; the player can only query its own drawing rate here, and during
            // startup that is still half the truth (on-device finding 2026-08-22: 24 Hz measured on a
            // 50 Hz channel, one second after the start — and because the stability rule demands
            // two equal ticks, the wrong number got through). It is then announced once, and the
            // TV switches once.
            if let known = contentFrameRate, known > 10 {
                // **The supplied number must be a standard rate too**
                // (check agent 2026-08-23): **58.82 Hz** was announced three times —
                // 1000/17, i.e. the remuxer's millisecond resolution on a 59.94 Hz channel whose
                // intervals fluctuate between 16 and 17 ms. A frame rate that does not exist.
                //
                // The protection existed, but only on the estimation path below —
                // this branch bypassed it. Harmless today, because the device consistently shows
                // "system matching OFF"; if the viewer switches it on, the TV would go to a
                // fantasy rate. This is exactly what ``normedRates`` was introduced against on
                // 2026-08-16.
                guard
                    let nearest = Self.normedRates.min(by: {
                        abs($0 - Float(known)) < abs($1 - Float(known))
                    }), abs(nearest - Float(known)) <= 1
                else {
                    // **Once per playback, not per tick.** The first version reported from the periodic
                    // observer — so twice per second. In the diagnosis of 2026-08-23 there were thirty
                    // identical lines in thirteen seconds, and they hid everything else in the error
                    // list.
                    //
                    // A message that repeats is no longer a message but noise — and noise costs exactly
                    // what it was meant for: the view of everything else.
                    if rejectedRate != Float(known) {
                        rejectedRate = Float(known)
                        Diagnostics.playbackProblem(
                            "Frame rate \(known) Hz hits no standard rate — not "
                                + "registered, the TV stays where it is",
                            since: loadStartedAt
                        )
                    }
                    return
                }
                register(nearest, from: .measured, measured: known, item: item, manager: manager)
                return
            }

            // The MEASURED frame rate of the running track — OVER ALL tracks,
            // not only those with `assetTrack`: with HLS `AVPlayerItemTrack` carries NO
            // `assetTrack`, so the first attempt filtered out every live track. Audio tracks
            // report 0 and do not disturb the maximum.
            let measured = item.tracks.map(\.currentVideoFrameRate).max() ?? 0
            guard measured > 10, item.isPlaybackLikelyToKeepUp else { return }

            // Only a standard rate that the measurement comes CLOSE to — "28 Hz" while
            // buffering is not a frame rate but a momentary state.
            guard
                let nearest = Self.normedRates.min(by: {
                    abs($0 - measured) < abs($1 - measured)
                }), abs(nearest - measured) <= 1
            else {
                pendingRate = nil
                return
            }
            // Stability: only when two ticks deliver the same standard.
            guard pendingRate == nearest else {
                pendingRate = nearest
                return
            }
            // Whether anything is announced at all is decided by ``FrameRateRegistration``:
            // the same mode stays silent, a better source may always, an equal-ranking one
            // exactly once.
            register(
                nearest, from: .estimated, measured: Double(measured), item: item,
                manager: manager)
        #endif
    }

    #if os(tvOS)
        /// Announces the rate and writes it down.
        ///
        /// Factored out because there are two paths to here: the supplied number from the
        /// remuxer and the own estimate. The announcement itself and above all its log line
        /// should be identical — otherwise the diagnosis shows two things for the same event.
        private func register(
            _ rate: Float, from source: FrameRateRegistration.Source, measured: Double,
            item: AVPlayerItem, manager: AVDisplayManager
        ) {
            guard login.accepts(rate, from: source) else { return }

            // **The description decides whether anything is set at all**
            // (AP2 · U3). Here the source booked success even if nothing was set: without a
            // format description it landed in the `else` branch, and
            // `item.asset.preferredDisplayCriteria` is empty during HLS playback — the criteria
            // were then **cleared** and the announcement was nevertheless recorded as done.
            // After that the lock prevented every further attempt for this item.
            let format = info.imageFormat ?? Self.syntheticVideoFormat(for: item, codec: videoCodec)
            let criteria: AVDisplayCriteria? =
                format.map { AVDisplayCriteria(refreshRate: rate, formatDescription: $0) }
                ?? info.preset

            guard let criteria else {
                // Stop honestly instead of booking success: without a description there is nothing
                // to announce, and the next attempt should be allowed again.
                login = FrameRateRegistration()
                if rejectedRate != rate {
                    rejectedRate = rate
                    Diagnostics.playbackProblem(
                        "Frame rate \(rate) Hz not registered: no format description "
                            + "and no value in the container — the TV stays where it is",
                        since: loadStartedAt)
                }
                return
            }

            manager.preferredDisplayCriteria = criteria
            displayCriteriaApplied = true
            // Into the trace, not into the blue: whether the announcement happened and whether
            // the SYSTEM allows the matching at all was otherwise not visible. Where the number
            // comes from belongs with it — "measured 24, announced 50" could not be recognized
            // as a contradiction on 2026-08-22.
            //
            // **And the origin is now stated correctly** (AP2 · U4): "measured by the remuxer"
            // depended solely on a number having been supplied — on the file path that was the
            // `DefaultDuration` from the Matroska header, i.e. a claim of the file and not a
            // measurement.
            Diagnostics.probe(
                "Frame rate registered: \(rate) Hz "
                    + Self.origin(source, measured: measured)
                    + ", system matching "
                    + (manager.isDisplayCriteriaMatchingEnabled ? "allowed" : "OFF"))

            reportSystemNotice(
                rate: rate, isAllowed: manager.isDisplayCriteriaMatchingEnabled)
        }

        /// **The announcement that has no effect** (AP2 · U2).
        ///
        /// On the device, 144 of 144 measurements say "system matching OFF". Above that,
        /// every time, stood "frame rate announced" — both are true, and together they make
        /// a piece of information nobody acts on: as long as the switch *Settings → Video and
        /// Audio → Match Content → Frame Rate* is off, the announcement changes nothing. For
        /// a rate that divides 60 this is harmless; at 25 or 50 it is exactly the stutter
        /// the viewer described on 2026-08-23.
        ///
        /// **Once per program run**, not per playback: the setting belongs to the device and
        /// does not change between two channels.
        private func reportSystemNotice(rate: Float, isAllowed: Bool) {
            guard FrameRateRegistration.needsSystemNotice(rate: rate, adjustmentAllowed: isAllowed),
                !Self.systemNoticeGiven
            else { return }
            Self.systemNoticeGiven = true
            Diagnostics.playbackProblem(
                "The content runs at \(rate) Hz, and that does not divide the TV's 60. "
                    + "The registration has no effect as long as Match Content / Match Frame Rate "
                    + "in the system settings (Video and Audio) is off — there and only "
                    + "there can it be switched.",
                since: nil)
        }

        /// Whether the hint was already shown in this program run.
        private nonisolated(unsafe) static var systemNoticeGiven = false

        static func origin(_ source: FrameRateRegistration.Source, measured: Double) -> String {
            switch source {
            case .measured: "(measured by the repackager)"
            case .header: "(given in the container header)"
            case .estimated: "(estimated at the player: \(Int(measured.rounded())))"
            }
        }

        /// A format description from the image size when the stream yields none: with HLS
        /// there is no `assetTrack` and thus no real one — for the frame-rate announcement
        /// the dimensions suffice, the rate travels separately.
        ///
        /// **The codec is no longer guessed** (AP2 · U3). Here `kCMVideoCodecType_HEVC` was
        /// hard-coded, while in 93 of 98 remuxer starts H.264 runs — the description lied
        /// about the video codec at exactly the place where the TV decides which mode to
        /// choose. Now the stream itself is asked; only when it too stays silent does H.264
        /// count as the more common case.
        ///
        /// **And the color attributes belong with it.** Without them the description
        /// describes a picture tube: `AVDisplayCriteria` uses them to help decide whether the
        /// TV switches to HDR. BT.709 is the default for everything below 4K and for every
        /// stream that says nothing else.
        private static func syntheticVideoFormat(
            for item: AVPlayerItem, codec: CMVideoCodecType
        ) -> CMFormatDescription? {
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return nil }
            var format: CMFormatDescription?
            let extensions: [CFString: Any] = [
                kCMFormatDescriptionExtension_ColorPrimaries:
                    kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                kCMFormatDescriptionExtension_TransferFunction:
                    kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                kCMFormatDescriptionExtension_YCbCrMatrix:
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            ]
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codec,
                width: Int32(size.width), height: Int32(size.height),
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &format)
            return format
        }

        /// The video codec of the running stream — asked, not guessed.
        ///
        /// From the preloaded information; if none is there yet, the more common case
        /// applies. See ``ContainerReport``.
        private var videoCodec: CMVideoCodecType {
            if let format = info.imageFormat {
                return format.mediaSubType.rawValue
            }
            // H.264 instead of HEVC as the fallback: 93 of 98 remuxer starts.
            return kCMVideoCodecType_H264
        }
    #endif

    // MARK: - One audio track, not all

    /// Whether the audio tracks of the running item were already checked.
    private var audioTracksEnforced = false

    /// The container tracks as a selection fallback — filled only when the container
    /// carries NO selection groups (Hisvei Weprir 811: two audio tracks, no group — the
    /// track choice was empty although there were two languages).
    private var containerAudioFallback: [AVPlayerItemTrack] = []
    private var containerSubtitleFallback: [AVPlayerItemTrack] = []
    private var containerTracksPublished = false

    /// Offers the container tracks for selection when the groups stay silent.
    ///
    /// Only from playing onward — before that the track board is empty. Once per item;
    /// the preselection shows what ``enforceSingleAudioTrack()`` has just enforced.
    private func publishContainerTrackChoices() {
        guard !containerTracksPublished, status == .playing, let item = player.currentItem
        else { return }
        let audio = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
        let subtitles = item.tracks.filter { track in
            let kind = track.assetTrack?.mediaType
            return kind == .subtitle || kind == .text || kind == .closedCaption
        }
        guard !audio.isEmpty || !subtitles.isEmpty else { return }
        // **Only when the languages are there.** Otherwise every track would be called
        // "Track 1", "Track 2" — and the lock below would prevent it from ever getting
        // better. See ``ContainerReport``.
        guard info.settled else { return }
        containerTracksPublished = true

        if audioTracks.isEmpty, audio.count > 1 {
            containerAudioFallback = audio
            audioTracks = audio.enumerated().map { index, track in
                let language = info.languages[ObjectIdentifier(track)]
                return PlaybackTrack(
                    id: index,
                    rawName: Self.containerTrackName(language, fallback: index),
                    language: language)
            }
            selectedAudioTrack = audio.firstIndex(where: \.isEnabled)
        }
        if subtitleTracks.isEmpty, !subtitles.isEmpty {
            containerSubtitleFallback = subtitles
            subtitleTracks = subtitles.enumerated().map { index, track in
                let language = info.languages[ObjectIdentifier(track)]
                return PlaybackTrack(
                    id: index,
                    rawName: Self.containerTrackName(language, fallback: index),
                    language: language)
            }
            selectedSubtitleTrack = subtitles.firstIndex(where: \.isEnabled)
        }
    }

    /// A readable name for a container track: the language, otherwise the number.
    static func containerTrackName(_ code: String?, fallback index: Int) -> String {
        if let code, let name = Locale.current.localizedString(forLanguageCode: code) {
            return name
        }
        return "Track \(index + 1)"
    }

    /// Narrows simultaneously ACTIVE audio tracks down to one.
    ///
    /// **On-device finding 2026-08-16, Hisvei Weprir 811:** an MP4 in directPlay kept Japanese AND
    /// German as active tracks — without an alternate group Apple's engine then simply
    /// plays both on top of each other. The remuxer picks exactly one track for MKV;
    /// here, on the raw container, the engine has to intervene itself: the preferred
    /// language stays, the rest is disabled. Only from playing onward, because the track
    /// board is empty before; once per item is enough.
    private func enforceSingleAudioTrack() {
        guard !audioTracksEnforced, status == .playing, let item = player.currentItem else {
            return
        }
        let audio = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
        guard !audio.isEmpty, info.settled else { return }
        audioTracksEnforced = true

        let active = audio.filter(\.isEnabled)
        guard active.count > 1 else { return }

        let chosen =
            active.first {
                LanguageCode.matches(
                    info.languages[ObjectIdentifier($0)], preferredAudioLanguage)
            } ?? active[0]
        for track in active where track !== chosen {
            track.isEnabled = false
        }
        Diagnostics.probe(
            "Container carries \(active.count) audio tracks active at once — "
                + "narrowed to "
                + "\(info.languages[ObjectIdentifier(chosen)] ?? "the first")")
    }

    /// Gives the output back to the system when nothing is playing any more.
    private func resetDisplayCriteria() {
        #if os(tvOS)
            pendingRate = nil
            login = FrameRateRegistration()
            rejectedRate = nil
            guard displayCriteriaApplied else { return }
            displayCriteriaApplied = false
            Self.displayManager?.preferredDisplayCriteria = nil
        #endif
    }

    #if os(tvOS)
        /// Since 2026-09-03 in ``DisplaySupport`` — both engines report.
        private static var displayManager: AVDisplayManager? { DisplaySupport.displayManager }
    #endif

    /// What the engine can currently play — for a channel with time shift, the window
    /// from the oldest segment to the live edge.
    private var seekableWindow: ClosedRange<TimeInterval>? {
        guard let ranges = player.currentItem?.seekableTimeRanges, !ranges.isEmpty else {
            return nil
        }
        let starts = ranges.map { $0.timeRangeValue.start.seconds }.filter(\.isFinite)
        let ends = ranges.map { $0.timeRangeValue.end.seconds }.filter(\.isFinite)
        guard let first = starts.min(), let last = ends.max(), last > first else { return nil }
        return first...last
    }

    /// The time-shift window — see ``Core/PlaybackController/timeShiftWindow``.
    public var timeShiftWindow: ClosedRange<TimeInterval>? { seekableWindow }

    public func seekToLiveEdge() {
        // The live edge is the end of the playable window — a bit before it, so that the
        // player does not reach into a segment the remuxer is only just cutting (F-041:
        // four times "Back to Live" without effect, because the seek to a billion seconds
        // was discarded).
        guard let window = seekableWindow else {
            seek(to: .greatestFiniteMagnitude)
            return
        }
        seek(to: max(window.lowerBound, window.upperBound - 1))
    }

    public func seek(to newPosition: TimeInterval) {
        // Always clamp downward, upward only with a known length. Shortly after opening, the
        // duration is not there yet — anyone who insisted on `duration > 0` here as before
        // silently discarded every early seek, and the bar showed a position the film never
        // reached.
        var target =
            duration > 0
            ? (PlaybackRules.seekTarget(newPosition, duration: duration) ?? max(0, newPosition))
            : max(0, newPosition)
        // Without a duration — a channel — the window holds the limits: not before the
        // oldest segment, not beyond the live edge.
        if duration <= 0, let window = seekableWindow {
            target = min(max(target, window.lowerBound), max(window.lowerBound, window.upperBound - 1))
        }

        // While a seek is running, only the last request is remembered — see
        // ``isSeeking``. The target replaces an earlier remembered one: anyone who presses
        // three times wants to arrive where they pressed last.
        if isSeeking {
            queuedSeek = target
            return
        }
        performSeek(to: target)
    }

    /// Executes the seek and releases the lock only with the completion callback.
    ///
    /// **With one second of tolerance instead of frame-exact.** Zero tolerance forces the
    /// engine to decode from the previous keyframe without showing any of it — with a
    /// stream from the network that means first of all: loading. One second off nobody
    /// sees while scrubbing; the wait before it, they certainly do.
    private func performSeek(to target: TimeInterval) {
        isSeeking = true
        position = target

        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            // The completion callback comes from an arbitrary queue — the way back to the main
            // actor goes through a task, not through an assumption.
            Task { @MainActor [weak self] in
                self?.finishSeek()
            }
        }
    }

    private func finishSeek() {
        isSeeking = false
        if let queued = queuedSeek {
            queuedSeek = nil
            performSeek(to: queued)
            return
        }
        if immediatelyAfterStartJump {
            immediatelyAfterStartJump = false
            // Only if nobody paused and the clock is still stopped.
            guard status == .opening || status == .playing,
                player.timeControlStatus != .playing
            else { return }
            player.playImmediately(atRate: 1)
            Diagnostics.playbackStep(
                "Resuming without waiting at \(String(format: "%.1f", position)) s",
                since: loadStartedAt)
            return
        }
        startupAfterJump()
    }

    /// Whether a frame arrives — read from the image size.
    ///
    /// `presentationSize` is zero as long as the player knows nothing yet, and stays zero
    /// if it cannot decode the video track. Only when a size is there is a frame
    /// evidenced. The distinction between "not yet" and "not at all" is made by the
    /// caller via time — see ``PlayerModel/blindTicks``.
    public var hasVideoOutput: Bool? {
        guard let item = player.currentItem else { return nil }
        return item.presentationSize != .zero
    }

    /// How many frames the player has dropped — from the access log.
    ///
    /// **The answer to the on-device finding of 2026-08-22** ("extreme judder and stutter" on
    /// the Turkish UHD channels, while the measurement reported "0 dropouts, 0 buffer
    /// messages, ran through" for every single one). That was not a contradiction but a
    /// gap: both quantities of the trace — stall and lead — need a standing or jumping
    /// **position**. Whoever drops frames keeps the position in order and merely shows
    /// it less often.
    ///
    /// `AVPlayerItemAccessLog` counts exactly that. The **last** entry is read: the log
    /// starts a new event at every change of delivery route, and older entries belong to
    /// a stream nobody sees any more. `-1` means "not collected" at Apple and becomes
    /// `nil` — a non-answer must not pass as exoneration.
    /// **Read off and not queried** (AP1, 2026-09-02). Here the access to the log was direct
    /// — and the caller asks twice per second on the main thread. The SDK header is
    /// unusually clear about it: "this method may temporarily block the calling thread …
    /// avoiding calling this method in the main thread" (`AVPlayerItem.h:703-704`,
    /// word for word the same as the sentence on `errorLog()`, because of which that
    /// access has long run off to the side in the project). That is exactly what the
    /// first attempt at opening the bracket around the trace failed on: opening it would
    /// have burdened every viewer with this call.
    ///
    /// Reading now happens in a detached task every two seconds; only the stored state
    /// stands here. For the trace that suffices: it compares the counter over an entire
    /// playback, not over one tick.
    public var droppedVideoFrames: Int? { droppedFrames.value }

    /// The stored state of the dropped frames — written by the detached task, read by
    /// the main thread.
    private let droppedFrames = CounterBox()

    /// The task that keeps it up to date. It hangs on the item: a new item begins a new
    /// access log, and the state of the old one would be information about a stream
    /// nobody sees any more.
    private var droppedRefresh: Task<Void, Never>?

    /// How often it is re-read.
    static let droppedRefreshInterval: Duration = .seconds(2)

    private func startDroppedRefresh(for item: AVPlayerItem) {
        droppedRefresh?.cancel()
        droppedFrames.set(nil)
        let box = droppedFrames
        droppedRefresh = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                // `accessLog()` is `NS_SWIFT_NONISOLATED`, `AVPlayerItemAccessLog` and its events are
                // `NS_SWIFT_SENDABLE` — the access may run off to the side. The same way as with the
                // error log.
                let event = item.accessLog()?.events.last
                // `-1` means "not collected" at Apple and becomes `nil` — a non-answer must not
                // pass as exoneration.
                box.set(
                    event.map { $0.numberOfDroppedVideoFrames >= 0 ? $0.numberOfDroppedVideoFrames : nil }
                        ?? nil)
                try? await Task.sleep(for: Self.droppedRefreshInterval)
            }
        }
    }

    /// Whether the first frame has become visible — read from the video layer.
    ///
    /// `presentationSize` is no good for this: it is already set when the player has
    /// merely read the format descriptions (roadmap AP5 — "the mark fires too early").
    /// `AVPlayerLayer.isReadyForDisplay`, by contrast, flips only when the layer has
    /// really drawn the first frame.
    ///
    /// The decision itself is in ``firstFrameVerdict`` — a pure function, so that all
    /// branches can be checked without rendering a frame.
    public var firstFrameVisible: Bool? {
        Self.firstFrameVerdict(
            hasItem: player.currentItem != nil,
            externalPlayback: player.isExternalPlaybackActive,
            presentationSizeKnown: player.currentItem.map { $0.presentationSize != .zero }
                ?? false,
            layerAttached: displayLayer != nil,
            layerReady: layerReadyForDisplay
        )
    }

    /// The rule behind ``firstFrameVisible``, checkable on its own.
    ///
    /// - Without a target there is nothing to see: `nil`.
    /// - With **AirPlay** the picture is produced on the other device and the local
    ///   layer stays empty — there the image size still applies, otherwise every AirPlay
    ///   playback would report "no picture" forever and the measurement would give up
    ///   after thirty seconds for no reason.
    /// - Without an attached layer there is no honest answer: `nil`. That is the state of
    ///   the checks on the Mac — and of the moment between an engine switch and the
    ///   rebuild of the surface.
    /// - Otherwise the layer decides.
    static func firstFrameVerdict(
        hasItem: Bool,
        externalPlayback: Bool,
        presentationSizeKnown: Bool,
        layerAttached: Bool,
        layerReady: Bool
    ) -> Bool? {
        guard hasItem else { return nil }
        if externalPlayback { return presentationSizeKnown }
        guard layerAttached else { return nil }
        return layerReady
    }

    /// Attaches the video layer of the drawing surface so that the engine can attest to
    /// its first frame.
    ///
    /// The surface calls this on every rebuild — hence the guard against attaching the
    /// same layer twice, otherwise the observation would be set up anew on every SwiftUI
    /// pass.
    public func attachDisplayLayer(_ layer: AVPlayerLayer) {
        guard displayLayer !== layer else { return }
        displayLayer = layer
        // **On attaching, "nothing drawn yet" applies, never the actual state of the
        // layer** (on-device finding 2026-08-15, "first frame: 0 ms" on channel switch): on an
        // engine switch the layer still holds the last frame of the PREVIOUS channel — its
        // `isReadyForDisplay` is true, and anyone who takes it over here declares the old
        // frame the first one of the new channel. The observation below reports
        // immediately with `.initial` and then reads the value valid at that moment — for a
        // surface rebuilt in the middle of playback the mark still becomes true.
        layerReadyForDisplay = false

        displayObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
            [weak self] _, _ in
            // Do not take over the reported value but read the **current** one: the report
            // arrives asynchronously on the main actor, and a stale "ready" report from the
            // previous target would otherwise be counted as the first frame of the new one after
            // it loads. After a target change the current value is already reset.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.layerReadyForDisplay = self.displayLayer?.isReadyForDisplay ?? false
            }
        }
    }

    /// The already loaded span around the current position.
    ///
    /// With HLS and direct playback this engine seeks everywhere itself — there the span
    /// is only information. The UI needs it for engines on a raw file, where a seek
    /// outside what is loaded is better made as a new request to the server.
    public var bufferedRange: ClosedRange<TimeInterval>? {
        guard let item = player.currentItem else { return nil }

        let current = CMTime(seconds: max(0, position), preferredTimescale: 600)
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)

        // The span in which the current position lies — the others are of no use to the
        // seeker, a reload would be needed there anyway.
        for range in ranges where range.containsTime(current) {
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite, start <= end else { continue }
            return start...end
        }
        return nil
    }

    // MARK: - Tracks

    public func selectAudioTrack(_ id: PlaybackTrack.ID) {
        // Container without selection groups (Hisvei Weprir 811): switching is done directly on
        // the tracks — exactly one on, the rest off.
        if !containerAudioFallback.isEmpty {
            for (index, track) in containerAudioFallback.enumerated() {
                track.isEnabled = index == id
            }
            selectedAudioTrack = id
            return
        }
        select(id, in: .audible)
        selectedAudioTrack = id
    }

    public func selectSubtitleTrack(_ id: PlaybackTrack.ID?) {
        if !containerSubtitleFallback.isEmpty {
            for (index, track) in containerSubtitleFallback.enumerated() {
                track.isEnabled = id == index
            }
            selectedSubtitleTrack = id
            return
        }
        select(id, in: .legible)
        selectedSubtitleTrack = id
    }

    /// Selects an option within a media group.
    ///
    /// The system player works not with track numbers but with groups of options. The
    /// translation goes via the index — the same counting that was used when collecting,
    /// so that both sides mean the same thing.
    private func select(_ id: PlaybackTrack.ID?, in characteristic: AVMediaCharacteristic) {
        guard let item = player.currentItem else { return }

        Task { @MainActor in
            guard
                let group = try? await item.asset.loadMediaSelectionGroup(
                    for: characteristic
                )
            else { return }

            guard let id, group.options.indices.contains(id) else {
                // Without an identifier: switch off. For subtitles the normal case.
                item.select(nil, in: group)
                return
            }
            item.select(group.options[id], in: group)
        }
    }

    // MARK: - Observing

    private func observe(_ item: AVPlayerItem) {
        startDroppedRefresh(for: item)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        // **Unregister the notifications too, not just overwrite.** A token from
        // `addObserver(forName:…)` is NOT unregistered by assigning a new variable — so far
        // an observer of the old item stayed behind on every channel switch without
        // `stop()`. `stop()` only removes the most recent one.
        if let endObservation {
            NotificationCenter.default.removeObserver(endObservation)
            self.endObservation = nil
        }
        if let failObservation {
            NotificationCenter.default.removeObserver(failObservation)
            self.failObservation = nil
        }

        // Twice per second: more often gains nothing for a display and needlessly wakes the
        // main thread.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                // During a seek the display shows the target, not the old position — until the
                // completion callback the engine still reports from there.
                if !self.isSeeking {
                    self.position = time.seconds
                }

                let total = item.duration.seconds
                if total.isFinite, total > 0 {
                    self.duration = total
                }
                // Only if the engine is really playing: before, an unconditional switch stood here,
                // and "buffering" was gone again after half a tick although nothing was arriving.
                if self.status == .opening || self.status == .buffering,
                    self.player.timeControlStatus == .playing
                {
                    self.status = .playing
                }

                // **Why the clock is stopped is told by AVFoundation itself** — and nobody ever
                // asked (check agent 2026-08-23).
                //
                // The viewer finding "picture stands, only starts with the sound" cost an entire
                // agent run and a dozen correlations. `reasonForWaitingToPlay` would have answered
                // it in one sentence: `.toMinimizeStalls` means buffer, `.evaluatingBufferingRate`
                // means "still estimating", `.noItemToPlay` means nothing is queued at all.
                //
                // Only on **changes**, otherwise it would be one line per half second — the
                // frame-rate rejection already made the same mistake once today.
                let waiting = self.player.reasonForWaitingToPlay
                if waiting != self.lastWaitingReason {
                    self.lastWaitingReason = waiting
                    // **The position is shown only where the clock really ran.** 374 of the 392 lines
                    // of 2026-08-23 carried "at 0.0 s" — that was no measurement but the design: at startup
                    // the time still stands at zero, and with `noItemToPlay` no item is queued at all.
                    // Only 18 lines carried a position, and exactly those were the dropouts in the
                    // middle of the film. The real information is the timestamp anyway.
                    //
                    // Careful when reading: `time.seconds` can be NaN. The comparison then goes wrong,
                    // and it says "clock starts running" — the same line as for a real startup. The two
                    // cannot be told apart on this line.
                    let at = self.position > 0 ? String(format: "%.1f", self.position) : nil
                    let text: String
                    if let reason = waiting {
                        text = "Clock waiting (\(reason.rawValue))" + (at.map { " at \($0) s" } ?? "")
                    } else {
                        text = at.map { "Clock running from \($0) s" } ?? "Clock starting"
                    }
                    Diagnostics.playbackStep(text, since: self.loadStartedAt)
                }
                // On the tick, not only on switching: the measured frame rate often appears only
                // seconds after the first frame — until then the announcement stays open (see
                // applyDisplayCriteria).
                self.applyDisplayCriteria()
                self.enforceSingleAudioTrack()
                self.publishContainerTrackChoices()
            }
        }

        // `.initial` closes a window that costs nothing: had the item become ready before
        // this registration, no report would ever come. The `default:` branch catches
        // `.unknown` anyway.
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    // **The startup mark is created here, in the event.** Until 2026-08-26 the startup
                    // measurement fetched it from the same 50 ms sample as the first frame; both marks
                    // carried the same `now`, and the middle segment was therefore zero by design.
                    // Readiness lies before the first drawn frame — only this gap is the buffering and
                    // decoding, the quantity the question of a second engine hangs on. Only the first
                    // report counts, same reasoning as in ``StartupTiming/markReady(at:)``.
                    if self.readyToPlayAt == nil { self.readyToPlayAt = Date() }
                    Task {
                        await self.collectTracks(from: item)
                        await self.loadContainerReport(from: item)
                    }
                case .failed:
                    self.status = .failed
                    self.reportFailure("System player could not open", of: item, at: nil)
                default:
                    break
                }
            }
        }

        // **The buffer is observed, not guessed.** Before, there was only the item's status
        // here — "buffering" was never set, and after twelve seconds the UI's stall
        // watchdog struck where an honest display would have sufficed.
        bufferObservations = [
            item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshBufferState() }
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshBufferState() }
            },
        ]

        endObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.status = .ended
            }
        }

        // A stream that breaks off in the middle of the film — for instance because the
        // server lost the encoding — reports here and not via `item.status`. Without this
        // observer only a standing picture without explanation would remain.
        failObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] note in
            // The reason is in the `userInfo` of the notification and not in `item.error` —
            // hence it is unpacked and passed on. Unpacking needs no actor binding; everything
            // that touches `self` or `item` stands below.
            let failure = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
            let rejectedLowLatency = Self.isLowLatencyRejection(failure as NSError?)
            MainActor.assumeIsolated {
                // **Only for the item that is playing right now.** The old notification observers
                // are meanwhile unregistered in `observe(_:)`; the check stays because a
                // notification that has already been dispatched would otherwise write a line about
                // the NEW target.
                guard let self, self.player.currentItem === item else { return }
                self.rejectedLowLatency = rejectedLowLatency
                self.status = .failed
                self.reportFailure(
                    "Playback broke off",
                    of: item,
                    at: self.position,
                    error: failure as NSError?
                )
            }
        }
    }

    // MARK: - Why it failed

    /// Whether a failure line has already gone out for the running item.
    ///
    /// `status == .failed` and `failedToPlayToEndTimeNotification` can both fire for the
    /// same item. Two lines for one failure read like two failures — and the question
    /// at hand is precisely how often it really went wrong.
    private var failureReported = false

    /// What an error-log entry yields about the failure.
    ///
    /// As a value of its own instead of a grip on the event, because
    /// `AVPlayerItemErrorLogEvent` carries `AV_INIT_UNAVAILABLE` (AVPlayerItem.h:1091) —
    /// no event can be built in a check. If the text assembly lived on the event, the
    /// very part that carries the information would stay unchecked.
    ///
    /// The fields are `var`: only then does the memberwise initializer set the missing
    /// optionals to `nil` on its own, and the checks can populate individual fields.
    struct ErrorLogFacts: Sendable, Equatable {
        var domain: String?
        var code: Int?
        var comment: String?
        var serverAddress: String?
        var httpHeaderCount: Int?
        var contentType: String?
    }

    /// What goes from the error log into the trace — without interpretation.
    ///
    /// **`errorStatusCode` is NOT an HTTP status.** The SDK header says only "A unique
    /// error code identifier. Corresponds to «status»" (AVPlayerItem.h:1117-1121).
    /// What the number means depends solely on `errorDomain`: `CoreMediaErrorDomain` →
    /// a CoreMedia/OSStatus value, usually negative, without a public translation
    /// table; `NSURLErrorDomain` → a `URLError.Code` (-1001 timeout, -1005 connection
    /// dropped), the only domain with documented readability; `NSOSStatusErrorDomain`
    /// and vendor-specific ones → raw. That is why the number ALWAYS goes out with its
    /// domain in front and never with an interpretation.
    ///
    /// The only documented HTTP word is elsewhere: according to the header
    /// `allHTTPResponseHeaderFields` is filled exactly "if an HTTP response was received
    /// as part of this error" (AVPlayerItem.h:1135-1138).
    ///
    /// "no error log" is information of its own and no placeholder: for non-HTTP items
    /// an empty log is the normal case, and without this sentence "nothing logged"
    /// could not be told apart from "not looked at".
    nonisolated static func describe(_ facts: ErrorLogFacts?) -> String {
        guard let facts else { return "no error log" }
        var parts: [String] = [
            "Error log \(facts.domain ?? "no domain") "
                + (facts.code.map(String.init) ?? "no code")
        ]
        if let server = facts.serverAddress { parts.append("Server \(server)") }
        if let count = facts.httpHeaderCount {
            parts.append("HTTP response arrived (\(count) header lines)")
        }
        if let type = facts.contentType { parts.append("Content-Type \(type)") }
        if let comment = Diagnostics.withoutAddress(facts.comment) { parts.append("Comment: \(comment)") }
        return parts.joined(separator: " · ")
    }

    /// Whether an error is AVPlayer's rejection of the partial path: CoreMediaErrorDomain
    /// -15410, in the error itself or beneath it — see ``LowLatencyMemory``.
    nonisolated static func isLowLatencyRejection(_ error: NSError?) -> Bool {
        var current = error
        var depth = 0
        while let e = current, depth < 4 {
            if e.domain == "CoreMediaErrorDomain", e.code == -15410 { return true }
            if e.localizedDescription.contains("Low Latency") { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// Reads the fields that say something out of a log event.
    ///
    /// The guard around `allHTTPResponseHeaderFields` is no decoration: the field exists
    /// only from tvOS 17.5 and macOS 14.5, and this package also builds against macOS 14
    /// (Package.swift).
    nonisolated static func facts(from event: AVPlayerItemErrorLogEvent?) -> ErrorLogFacts? {
        guard let event else { return nil }
        var headers: [String: String]?
        if #available(tvOS 17.5, macOS 14.5, *) { headers = event.allHTTPResponseHeaderFields }
        return ErrorLogFacts(
            domain: event.errorDomain,
            code: event.errorStatusCode,
            comment: event.errorComment,
            serverAddress: event.serverAddress,
            httpHeaderCount: headers?.count,
            contentType: headers?.first { $0.key.lowercased() == "content-type" }?.value
        )
    }

    /// Writes the one line that says WHY it failed.
    ///
    /// Before, both went to `Diagnostics.network.error` — a pure OSLog logger that never
    /// creates a trace entry. The submitted report of 2026-08-23 therefore contains zero
    /// failure lines, while the `playbackProblem` lines of the same engine appear in it
    /// 288, 186 and 156 times. What was missing was the outlet, not the observer.
    private func reportFailure(
        _ headline: String,
        of item: AVPlayerItem,
        at seconds: TimeInterval?,
        error: NSError? = nil
    ) {
        guard !failureReported else { return }
        failureReported = true

        let failure = error ?? (item.error as NSError?)
        let reason = Diagnostics.withoutAddress(failure?.localizedDescription) ?? "unknown"
        let origin = failure.map { "\($0.domain) \($0.code)" } ?? "no error object"
        let started = loadStartedAt
        // **The span is measured HERE, not in the detached task** — otherwise it would
        // include the read time of the error log.
        let span = started.map { String(format: "%.1f", Date().timeIntervalSince($0)) }

        // **Do not read on the main thread.** The SDK header is unusually clear here: "this
        // method may temporarily block the calling thread … It is strongly recommended …
        // avoiding calling this method in the main thread" (AVPlayerItem.h:714-715).
        // `errorLog()` is specially `NS_SWIFT_NONISOLATED` for that, `AVPlayerItemErrorLog`
        // and its events are `NS_SWIFT_SENDABLE` — the access may run off to the side.
        Task.detached(priority: .utility) {
            let facts = Self.facts(from: item.errorLog()?.events.last)
            // **The rejection of the partial path is in the error log**, not in the error
            // object (F-040: NEBULA HQ, -15410 only there). Whoever plans the rebuild waits
            // briefly for this mark.
            if facts?.code == -15410 || facts?.comment?.contains("Low Latency") == true {
                await MainActor.run { [weak self] in self?.rejectedLowLatency = true }
            }
            var text = headline
            if let span { text += " after \(span) s" }
            if let seconds { text += ", at \(Int(seconds)) s in the picture" }
            text += ": \(reason) [\(origin)] · \(Self.describe(facts))"
            // `since:` reaches only the system log: `playbackProblem` passes the text on to the
            // trace WITHOUT the time field (Diagnostics.swift:54-59). That is why the span is
            // additionally in the text — only that arrives in the submitted report.
            Diagnostics.playbackProblem(text, since: started)
        }
    }

    /// Translates the engine's buffer state into the playback status.
    ///
    /// Only between "playing" and "buffering": pause, end and error take precedence —
    /// whoever is paused does not wait for data, even if none is arriving.
    private func refreshBufferState() {
        guard status == .playing || status == .buffering, let item = player.currentItem else {
            return
        }

        // Only the transition is recorded, not every call: the observers also report
        // without a change, and a trace full of repetitions hides the question at hand —
        // when and how often it stuttered.
        if item.isPlaybackBufferEmpty {
            if status != .buffering {
                Diagnostics.verbose("Buffer empty at \(Int(position)) s — buffering")
            }
            status = .buffering
        } else if item.isPlaybackLikelyToKeepUp, player.timeControlStatus == .playing {
            if status != .playing {
                Diagnostics.verbose("Buffer sufficient again at \(Int(position)) s — playing")
            }
            status = .playing
        }
    }

    /// Translates the chosen presentation into the rules of the system engine.
    ///
    /// Size as a percentage relative to the system default, color as an ARGB array —
    /// both affect only text tracks (WebVTT); image subtitles are drawn only by VLC
    /// anyway. As a function of its own so that the translation can be checked without
    /// building a player.
    static func textStyleRules(
        for style: SubtitleStyle, row: Int? = nil
    )
        -> [AVTextStyleRule]
    {
        var attributes: [String: Any] = [:]
        // **Size and color only when different from the default.** Always setting both
        // values here would mean overwriting the system's accessibility settings with its
        // own defaults — the viewer who set larger subtitles there would get the normal
        // ones again.
        if !style.isStandard {
            let rgba = style.color.rgba
            attributes[kCMTextMarkupAttribute_RelativeFontSize as String] = style.size.percent
            attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] = [
                rgba.alpha, rgba.red, rgba.green, rgba.blue,
            ]
        }
        // **The line position is a statement about the picture and not about taste.** It is
        // applied only when the fill really crops at top and bottom, and disappears with
        // it — see ``SubtitleLayout``.
        if let row {
            attributes[
                kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection
                    as String] = row
        }
        guard !attributes.isEmpty else { return [] }
        return [AVTextStyleRule(textMarkupAttributes: attributes)].compactMap { $0 }
    }

    /// Applies the subtitle rules to an item — **or clears them.**
    ///
    /// **`nil` and expressly not an empty list.** This is already noted as a finding
    /// above this file: empty rules overwrite the system's accessibility settings with
    /// its own defaults — whoever set larger subtitles there would get the normal ones
    /// again. `nil` is the value with which AVFoundation hands the track back to the
    /// viewer's settings, and thus also the way to **withdraw** a custom rule: whoever
    /// switches back from the filled picture must not have their line stay at the top
    /// where nothing is cropped any more.
    private func applySubtitleRules(to item: AVPlayerItem) {
        let rules = Self.textStyleRules(
            for: subtitleStyle,
            row: SubtitleLayout.linePlacement(visibleFraction: subtitleShare))
        item.textStyleRules = rules.isEmpty ? nil : rules
    }

    private func collectTracks(from item: AVPlayerItem) async {
        audioTracks = await tracks(in: .audible, of: item)
        subtitleTracks = await tracks(in: .legible, of: item)
    }

    private func tracks(
        in characteristic: AVMediaCharacteristic,
        of item: AVPlayerItem
    ) async -> [PlaybackTrack] {
        guard
            let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic)
        else { return [] }

        return group.options.enumerated().map { index, option in
            PlaybackTrack(
                id: index,
                rawName: option.displayName,
                language: option.extendedLanguageTag
            )
        }
    }
}

/// A counter that is written on one thread and read on another.
///
/// Small and expressly a class: the value is kept up to date in a detached task and
/// read on the main thread; a value type would have to be passed through and would
/// already be stale when read.
final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Int?

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func set(_ fresh: Int?) {
        lock.lock()
        defer { lock.unlock() }
        state = fresh
    }
}
