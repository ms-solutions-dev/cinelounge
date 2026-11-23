import AVFoundation
import Combine
import Core
import CoreMedia
import Foundation
import Observation

/// The direct renderer: Apple's hardware decoder, without Apple's player in front.
///
/// **Why it exists** (2026-09-03, diagnosis F-003): the HLS path needs whole segments
/// before the system player starts, and a segment is as long as the distance between
/// two keyframes — ten seconds on the UHD channels. Measured, that was 5.0 s median
/// to the picture, with a range of 1.8 to 10.3 s. VLC needed 376 to 678 ms on the
/// same channels. The difference is not a decoder but the container: VLC waits for no
/// segment.
///
/// This engine does not either. It takes the packets of the remuxer from a
/// ``SampleQueue`` and hands them to `AVSampleBufferDisplayLayer` and
/// `AVSampleBufferAudioRenderer`, which hang on a shared clock
/// (`AVSampleBufferRenderSynchronizer`). Decoding happens in the same hardware as
/// with the system player — the rule "audio may be decoded yourself, video may not"
/// stays observed.
///
/// ## What has its own behavior here
///
/// **The clock is ours.** The system player stops by itself when the buffer runs
/// dry; the clock here does not — it would keep running, and every late-arriving
/// frame would be late and be dropped. That is why a clock of its own watches how
/// far the delivered feed is ahead of the clock, and stops the clock before it
/// overtakes the buffer. That is the whole difference between an engine that bridges
/// dropouts and one that stutters at every burst from the provider.
///
/// **Start lean, then fatten.** Playback starts as soon as half a second of feed is
/// there; the session before it has waited for one anyway. The provider pushes at the
/// start at three to four times real time, so the buffer grows DURING the first
/// seconds of picture — not before.
///
/// **Channels only.** No scrubbing, no track choice, no subtitles: everything a film
/// needs, the system player has, and there it starts in 303 ms.
@MainActor
@Observable
public final class SampleBufferPlaybackEngine: PlaybackController {

    // MARK: - Rules

    /// From how much feed ahead of the clock playback starts.
    static let startLead: TimeInterval = 0.5
    /// Below how much lead the clock is stopped.
    ///
    /// **A tenth, and that is deliberately tight**: a larger value would stop at every
    /// burst pause of the provider (those are under a second), a smaller one would let the
    /// clock overtake the last frame. The tick below checks every hundred milliseconds —
    /// tighter than any burst pause.
    static let stallLead: TimeInterval = 0.1
    /// From how much lead playback restarts after a stop.
    ///
    /// One second, as at the session's startup: whoever restarts immediately on the first
    /// frame stops again on the second — that is stuttering, not buffering.
    static let resumeLead: TimeInterval = 1
    /// How often it is checked.
    static let tickInterval: Duration = .milliseconds(100)
    /// From what length a pause of the audio pump appears in the report.
    ///
    /// **A quarter second**: short enough that a dropout does not slip through, and long
    /// enough that the pump's ordinary timing is not in every report.
    static let reportThresholdAudioGap: TimeInterval = 0.25

    /// From what lag of the clock behind the buffer it is set anew.
    ///
    /// Happens only if the stop came too late: the clock has then run over frames that
    /// were not yet drawn, and everything waiting would be late. Then the clock is set to
    /// the next waiting frame — a jump forward, not a still frame.
    static let reanchorLag: TimeInterval = 1

    // MARK: - Contract

    public private(set) var status: PlaybackStatus = .idle
    public private(set) var position: TimeInterval = 0
    /// A channel has no length.
    public private(set) var duration: TimeInterval = 0
    /// The channel's audio tracks from the program table — the remuxer passes one of
    /// them through, and **which one is decided here by the viewer** (AP6, 2026-09-03). The
    /// identifier is the PID; the session keeps the offer in the buffer.
    public private(set) var audioTracks: [PlaybackTrack] = []
    public private(set) var subtitleTracks: [PlaybackTrack] = []
    public private(set) var selectedAudioTrack: PlaybackTrack.ID?
    public private(set) var selectedSubtitleTrack: PlaybackTrack.ID?
    /// When the clock first ran — the event, not the sample.
    public private(set) var readyToPlayAt: Date?

    // MARK: - Building blocks

    /// The drawing surface. **Belongs to the engine, not to the view** — unlike with the
    /// system player, where the view attaches its `AVPlayerLayer` to the engine. Here the
    /// frames flow from the first instant, and a layer that comes into being only with
    /// the view would be too late for the first ones. The view hangs this layer in and
    /// aligns it, nothing more.
    public let displayLayer = AVSampleBufferDisplayLayer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let samples: SampleQueue
    private let feed: RendererFeed

    /// The time of the first frame — the clock begins there, and the position is
    /// computed against it.
    private var anchor: CMTime?
    /// Whether the clock was stopped by us (buffer empty) — not by the viewer.
    private var heldForSupply = false
    private var watch: Task<Void, Never>?
    private var loadStartedAt: Date?
    private var observers: [NSObjectProtocol] = []
    private var audioErrorWatch: NSKeyValueObservation?
    private var reportedAudioError = false
    /// Siehe ``firstFrameVisible``.
    private var layerReadyForDisplay = false
    /// How often the clock was stopped because of an empty buffer — for the balance.
    public private(set) var supplyHolds = 0

    /// The supplied frame rate, if the session already knows it; otherwise the buffer
    /// measures it itself. See ``applyDisplayCriteriaIfPossible()``.
    var contentFrameRate: Double?
    private var displayCriteriaApplied = false
    private var reportedRate: Float?

    public init(samples: SampleQueue) {
        self.samples = samples
        displayLayer.videoGravity = .resizeAspect
        let videoRenderer = displayLayer.sampleBufferRenderer
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        feed = RendererFeed(
            video: videoRenderer, audio: audioRenderer, samples: samples, clock: synchronizer)
    }

    // MARK: - Control

    /// The address plays no role here — the buffer is the source.
    public func load(_ url: URL, startingAt startPosition: TimeInterval) {
        loadStartedAt = Date()
        status = .opening
        position = 0
        anchor = nil
        heldForSupply = false
        readyToPlayAt = nil
        layerReadyForDisplay = false
        displayCriteriaApplied = false
        reportedRate = nil
        supplyHolds = 0
        reportedAudioError = false

        observe()
        feed.start()
        startWatch()
    }

    public func play() {
        guard anchor != nil else { return }
        synchronizer.rate = 1
        status = .playing
    }

    public func pause() {
        guard anchor != nil else { return }
        synchronizer.rate = 0
        status = .paused
    }

    public func stop() {
        watch?.cancel()
        watch = nil
        feed.setRunning(false)
        feed.stop()
        synchronizer.rate = 0
        displayLayer.sampleBufferRenderer.flush()
        audioRenderer.flush()
        samples.drain()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        audioErrorWatch?.invalidate()
        audioErrorWatch = nil
        resetDisplayCriteria()
        // **The balance always**, as soon as the clock ever ran (F-016): dropouts, decoder
        // errors and lead at the end — what a viewer reports as "does not run properly"
        // has its number here.
        if anchor != nil {
            let headStart = lead.map { String(format: "%.1f s ahead", $0) } ?? "no lead"
            // **The sync numbers** (F-016, Pusula 1: "picture and sound do not match"): where
            // the audio arrived relative to the picture, and how many packets the clock had
            // already left behind when they went in — those are never heard. Reasoning at
            // ``SampleQueue/audioSkew``.
            let sync = samples.audioSkew.map { ", " + Self.skewText($0) } ?? ""
            var late = ""
            if feed.lateAudio + feed.lateVideo > 0 {
                var firstItem: Double?
                if let leading = feed.firstLateAt, let anchor { firstItem = (leading - anchor).seconds }
                late =
                    ", \(feed.lateAudio) audio packets and \(feed.lateVideo) frames arrived behind the clock"
                    + " (up to \(String(format: "%.1f", feed.maxLateness)) s"
                    + (firstItem.map { ", first at \(String(format: "%.1f", $0)) s" } ?? "") + ")"
            }
            // The pump and the decoder share one thread — whichever of the two takes long makes
            // the other wait.
            var threadNote = ""
            // **From a quarter second and not from a whole one.** The threshold stood at 1 s and
            // thereby hid exactly the order of magnitude that matters: a pause of 250 ms is an
            // audible dropout, one of 900 ms was "nothing" under this rule. It is reported in
            // milliseconds because "0.3 s" is no longer information with a quarter-second
            // threshold.
            if feed.longestAudioPumpGap > Self.reportThresholdAudioGap {
                threadNote += ", longest pause of the audio pump \(Int(feed.longestAudioPumpGap * 1000)) ms"
            }
            if feed.longestDecodeCall > 0.1 {
                threadNote += ", longest decoder call \(Int(feed.longestDecodeCall * 1000)) ms"
            }
            Diagnostics.playbackStep(
                "Renderer tally: held \(supplyHolds) times, "
                    + "\(feed.decoderErrors) frames rejected by the decoder, at the end \(headStart)"
                    + sync + late + threadNote
                    + (feed.isDeinterlacing ? ", fields deinterlaced in hardware" : "")
                    + ", \(feed.enqueuedAudio) audio packets to the audio renderer"
                    + (audioRenderer.error != nil ? " (audio renderer in error)" : "")
                    + ", memory \(MemoryWatch.footprintText)",
                since: nil)
        }
        anchor = nil
        status = .idle
    }

    /// A channel knows no seeking. Bewusst still: the bar does not call this for a
    /// live target at all, and a message per press would be noise.
    public func seek(to position: TimeInterval) {}

    /// Selects an audio track: the remuxer pins the PID anew, the audio renderer is
    /// flushed, and whatever of the old track was still in the buffer is gone.
    public func selectAudioTrack(_ id: PlaybackTrack.ID) {
        guard id != selectedAudioTrack, id >= 0, id <= Int(UInt16.max),
            samples.audioOptions.contains(where: { Int($0.pid) == id })
        else { return }
        samples.onSelectAudio?(UInt16(id))
        audioRenderer.flush()
        selectedAudioTrack = id
    }

    public func selectSubtitleTrack(_ id: PlaybackTrack.ID?) {}

    // MARK: - Information

    /// Whether a frame ever arrived at the renderer. **Not** the image size: that is
    /// settled with the format description, long before anything is drawn.
    public var hasVideoOutput: Bool? { feed.enqueuedVideo > 0 }

    /// Whether the layer has drawn its first frame — reported by the system, not
    /// guessed. The same rule as with the system player: without a target `nil`.
    public var firstFrameVisible: Bool? {
        guard anchor != nil || status == .opening else { return nil }
        return layerReadyForDisplay
    }

    /// The renderer does not count dropped frames. "I don't know" is the honest answer
    /// here — not zero.
    public var droppedVideoFrames: Int? { nil }

    /// How far the delivered feed is ahead of the clock, in seconds.
    ///
    /// Public for the diagnosis: this number is the engine's health. If it rises, the
    /// provider is fattening; if it falls below ``stallLead``, the clock stops.
    public var lead: TimeInterval? {
        guard anchor != nil, let latest = samples.latestVideoTime else { return nil }
        return (latest - synchronizer.currentTime()).seconds
    }

    // MARK: - The guard over the clock

    private func startWatch() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SampleBufferPlaybackEngine.tickInterval)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let anchor else {
            startIfSupplied()
            return
        }
        let now = synchronizer.currentTime()
        let latest = samples.latestVideoTime ?? anchor
        let lead = (latest - now).seconds

        switch status {
        case .playing:
            if lead < Self.stallLead { hold(lead: lead) }
        case .buffering:
            if lead >= Self.resumeLead { resume(lead: lead) }
        default:
            break
        }

        // Report the position only on visible movement — every report is a redraw of the
        // bar, and nobody needs that ten times a second.
        let location = max(0, (now - anchor).seconds)
        if abs(location - position) >= 0.25 { position = location }

        applyDisplayCriteriaIfPossible()
        refreshAudioTracks()
    }

    /// Keeps the audio-track offer from the buffer up to date — it stands only when the
    /// program table has been read, and that is after loading.
    private func refreshAudioTracks() {
        let offer = samples.audioOptions.map { option in
            PlaybackTrack(
                id: Int(option.pid),
                // The codec as a raw name — it distinguishes two tracks of the same language, and
                // ``PlaybackTrack/displayName(locale:)`` hides it where the language alone suffices.
                rawName: option.codec, language: option.language)
        }
        // **A single track is named too** (F-050, 2026-09-04): here stood "one track is no
        // choice", and on Telve 2 UHD with an MP2 track the menu showed "Tracks are still
        // being read …" — forever, because it cannot tell empty from waiting. A line with
        // the one track says what is there.
        if offer != audioTracks { audioTracks = offer }
        let chosen = samples.selectedAudioPID.map(Int.init)
        if chosen != selectedAudioTrack { selectedAudioTrack = chosen }
    }

    /// Starts playback as soon as the buffer holds.
    private func startIfSupplied() {
        guard let first = samples.firstVideoTime, let latest = samples.latestVideoTime,
            Self.canStart(first: first, latest: latest)
        else { return }
        anchor = first
        synchronizer.setRate(1, time: first)
        feed.setRunning(true)
        readyToPlayAt = Date()
        status = .playing
        Diagnostics.playbackStep(
            "Renderer: clock starting, "
                + "\(String(format: "%.1f", (latest - first).seconds)) s of broadcast ahead",
            since: loadStartedAt)
    }

    /// The startup rule as pure computation — checkable without a renderer.
    static func canStart(first: CMTime, latest: CMTime) -> Bool {
        (latest - first).seconds >= startLead
    }

    /// The codec of a format description as a four-character code: "ac-3", "ec-3", "aac ".
    nonisolated static func codecName(of format: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(format)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The span of the audio offset as a sentence. Negative is "behind the picture".
    nonisolated static func skewText(_ skew: ClosedRange<Double>) -> String {
        func s(_ v: Double) -> String { String(format: "%.1f", abs(v)) }
        if skew.upperBound <= 0 {
            return "Audio \(s(skew.upperBound))–\(s(skew.lowerBound)) s behind the picture"
        }
        if skew.lowerBound >= 0 {
            return "Audio \(s(skew.lowerBound))–\(s(skew.upperBound)) s ahead of the picture"
        }
        return "Audio \(s(skew.lowerBound)) s behind to \(s(skew.upperBound)) s ahead of the picture"
    }

    private func hold(lead: TimeInterval) {
        synchronizer.rate = 0
        feed.setRunning(false)
        heldForSupply = true
        supplyHolds += 1
        status = .buffering
        // A stop is information about the supply — it belongs in the trace, but not as a
        // defect: the engine does exactly the right thing here.
        Diagnostics.playbackStep(
            "Renderer holds: buffer at \(Int(lead * 1000)) ms", since: nil)
    }

    private func resume(lead: TimeInterval) {
        guard heldForSupply else { return }
        heldForSupply = false
        let now = synchronizer.currentTime()
        // **When the clock has overtaken the buffer, it is set back.** That is the case in
        // which the stop came too late: the next waiting frame lies BEHIND the clock, and
        // everything waiting would be late. Setting the clock to this frame is a jump
        // forward in the program — visible as a brief jerk, not as a still frame.
        if let next = samples.firstPendingVideoTime, (now - next).seconds > Self.reanchorLag {
            feed.flushDecoder()
            displayLayer.sampleBufferRenderer.flush()
            audioRenderer.flush()
            synchronizer.setRate(1, time: next)
            Diagnostics.playbackStep(
                "Renderer starts and restarts: clock was "
                    + "\(String(format: "%.1f", (now - next).seconds)) s ahead",
                since: nil)
        } else {
            synchronizer.rate = 1
            Diagnostics.playbackStep(
                "Renderer starts again: \(String(format: "%.1f", lead)) s buffer", since: nil)
        }
        feed.setRunning(true)
        status = .playing
    }

    // MARK: - What the system reports

    private func observe() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                object: displayLayer, queue: .main
            ) { [weak self] _ in
                // Read the CURRENT value, not the reported one — the same rule as with the system
                // player: a stale report from the previous target must not count as the first frame
                // of the new one.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.layerReadyForDisplay = self.displayLayer.isReadyForDisplay
                }
            })

        observers.append(
            center.addObserver(
                forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
                object: displayLayer.sampleBufferRenderer, queue: .main
            ) { [weak self] note in
                let error =
                    (note.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey]
                    as? Error).map { Diagnostics.explain($0) } ?? "no reason"
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // **After a decoder error the renderer must be flushed** — otherwise it accepts
                    // nothing any more. Until the next keyframe the picture afterwards may show blocks;
                    // a still frame until the channel switch would be worse.
                    //
                    // **One line per target, the rest is counted** (F-016): 1699 identical lines in
                    // one second cut off the front of the report — the balance at the stop names the
                    // number.
                    self.feed.noteDecoderError()
                    if self.feed.decoderErrors == 1 {
                        Diagnostics.playbackProblem(
                            "Renderer: decoder reports error — \(error); flushed, continuing "
                                + "(further ones are counted)",
                            since: self.loadStartedAt)
                    }
                    self.displayLayer.sampleBufferRenderer.flush()
                }
            })

        // **The audio renderer must explain itself** (F-010, 2026-09-04): Rendal HD, Rendal HD HEVC,
        // Rendal 2 HD, SELA 1 HD — picture without sound, 1448 AC-3 packets fed in on time, and
        // the trace knew nothing of it. Whether the renderer decodes AC-3 on this device at
        // all is told only by its error; until here nobody read it.
        audioErrorWatch = audioRenderer.observe(\.error, options: [.new]) { [weak self] renderer, _ in
            guard let error = renderer.error else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.reportedAudioError else { return }
                self.reportedAudioError = true
                let format = self.samples.audioFormat.map(Self.codecName) ?? "unknown format"
                Diagnostics.playbackProblem(
                    "Audio renderer reports error (\(format)) — \(Diagnostics.explain(error))",
                    since: nil)
            }
        }
        observers.append(
            center.addObserver(
                forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                object: displayLayer.sampleBufferRenderer, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                        self.displayLayer.sampleBufferRenderer.requiresFlushToResumeDecoding
                    else { return }
                    self.displayLayer.sampleBufferRenderer.flush()
                }
            })
    }

    // MARK: - Frame rate

    /// Announces the content's frame rate to the TV — once per target.
    ///
    /// The same rule as with the system player, only without its estimation path: the
    /// number comes from the intervals between frames, counted in the buffer, or was
    /// already supplied by the session. And it must be a standard rate — a fantasy rate
    /// would switch the TV into a mode that does not exist (check agent 2026-08-23).
    private func applyDisplayCriteriaIfPossible() {
        #if os(tvOS)
            guard !displayCriteriaApplied, status == .playing,
                let known = contentFrameRate ?? samples.frameRate, known > 10,
                let manager = DisplaySupport.displayManager, !manager.isDisplayModeSwitchInProgress,
                let format = samples.videoFormat
            else { return }

            guard let rate = FrameRateRegistration.standardRate(forItem: known) else {
                if reportedRate != Float(known) {
                    reportedRate = Float(known)
                    Diagnostics.playbackProblem(
                        "Frame rate \(known) Hz hits no standard rate — not "
                            + "registered, the TV stays where it is",
                        since: loadStartedAt)
                }
                return
            }
            manager.preferredDisplayCriteria = AVDisplayCriteria(
                refreshRate: rate, formatDescription: format)
            displayCriteriaApplied = true
            Diagnostics.probe(
                "Frame rate registered: \(rate) Hz (renderer, "
                    + (contentFrameRate != nil ? "measured by the session" : "measured in the buffer")
                    + "), system matching "
                    + (manager.isDisplayCriteriaMatchingEnabled ? "ON" : "OFF"))
        #endif
    }

    private func resetDisplayCriteria() {
        #if os(tvOS)
            guard displayCriteriaApplied else { return }
            displayCriteriaApplied = false
            DisplaySupport.displayManager?.preferredDisplayCriteria = nil
        #endif
    }
}

// MARK: - The feed

/// The thread between buffer and renderer — off the main actor.
///
/// **Why a class of its own:** the renderers call out their hunger on a thread of
/// their own (`requestMediaDataWhenReady`), and the engine lives on the main actor.
/// What stands here touches no state of the engine — only the buffer, which has its
/// own lock, and the renderers, which order their calls themselves.
final class RendererFeed: @unchecked Sendable {

    private let video: AVSampleBufferVideoRenderer
    private let audio: AVSampleBufferAudioRenderer
    private let samples: SampleQueue
    /// The clock against which lateness is measured — its time may be read from any
    /// thread; whether it runs is told by ``setRunning(_:)``.
    private let clock: AVSampleBufferRenderSynchronizer
    private var _running = false
    private var _lateAudio = 0
    private var _lateVideo = 0
    /// One thread, so that picture and sound go out in the order of their arrival and
    /// the two pumps do not get in each other's way.
    private let queue = DispatchQueue(label: "cinelounge.renderer-feed", qos: .userInteractive)
    private let lock = NSLock()
    private var _enqueuedVideo = 0
    private var _enqueuedAudio = 0
    /// The own decoder — only where it pays off (interlaced video). Created at the first
    /// frame if its description demands it; otherwise it stays `nil` and the layer
    /// decodes itself. See ``HardwareVideoDecoder``.
    ///
    /// **Under the lock** (F-016, 2026-09-03): the feed thread reads the field, ``stop()``
    /// on the main actor writes it — an unprotected class field between two threads is a
    /// crash on suspicion, and the crash on Telve 2 UHD (the first session with its own
    /// decoder) bears its signature.
    private var _decoder: HardwareVideoDecoder?
    private var decoderDecided = false
    private var decoder: HardwareVideoDecoder? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _decoder
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _decoder = newValue
        }
    }
    private var _decoderErrors = 0
    /// How many frames the renderer rejected — for the balance.
    var decoderErrors: Int {
        lock.lock()
        defer { lock.unlock() }
        return _decoderErrors
    }
    func noteDecoderError() {
        lock.lock()
        defer { lock.unlock() }
        _decoderErrors += 1
    }

    init(
        video: AVSampleBufferVideoRenderer, audio: AVSampleBufferAudioRenderer,
        samples: SampleQueue, clock: AVSampleBufferRenderSynchronizer
    ) {
        self.video = video
        self.audio = audio
        self.samples = samples
        self.clock = clock
    }

    /// Whether the clock is running — only then is "behind the clock" a statement.
    func setRunning(_ running: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _running = running
    }

    /// How many audio packets were already late when they went in.
    var lateAudio: Int {
        lock.lock()
        defer { lock.unlock() }
        return _lateAudio
    }

    var lateVideo: Int {
        lock.lock()
        defer { lock.unlock() }
        return _lateVideo
    }

    /// Counts a packet whose time the running clock has already left behind — and
    /// remembers how late and when first (F-050: 390 audio packets on Telve 3 UHD, and
    /// the number alone did not say whether at the start or later).
    private func noteLateness(of sample: CMSampleBuffer, isAudio: Bool) {
        lock.lock()
        let running = _running
        lock.unlock()
        guard running else { return }
        let now = clock.currentTime()
        let lateness = (now - sample.presentationTimeStamp).seconds
        guard lateness > 0 else { return }
        lock.lock()
        if isAudio { _lateAudio += 1 } else { _lateVideo += 1 }
        _maxLateness = max(_maxLateness, lateness)
        if _firstLateAt == nil { _firstLateAt = now }
        lock.unlock()
    }

    private var _maxLateness: Double = 0
    private var _firstLateAt: CMTime?
    private var _lastAudioPump: DispatchTime?
    private var _longestAudioPumpGap: Double = 0
    private var _longestDecodeCall: Double = 0

    /// How far behind the clock the latest packet lay, in seconds.
    var maxLateness: Double {
        lock.lock()
        defer { lock.unlock() }
        return _maxLateness
    }

    /// The clock time of the first late packet.
    var firstLateAt: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return _firstLateAt
    }

    /// The longest pause between two runs of the audio pump, in seconds — a pump that
    /// does not run lets the sound age in the buffer.
    var longestAudioPumpGap: Double {
        lock.lock()
        defer { lock.unlock() }
        return _longestAudioPumpGap
    }

    /// The longest single call of the own decoder, in seconds — it stands on the same
    /// thread as the audio pump.
    var longestDecodeCall: Double {
        lock.lock()
        defer { lock.unlock() }
        return _longestDecodeCall
    }

    private func notePumpGap() {
        let now = DispatchTime.now()
        lock.lock()
        if let last = _lastAudioPump, _running {
            _longestAudioPumpGap = max(_longestAudioPumpGap, Self.seconds(from: last, to: now))
        }
        _lastAudioPump = now
        lock.unlock()
    }

    private func noteDecodeCall(seconds: Double) {
        lock.lock()
        _longestDecodeCall = max(_longestDecodeCall, seconds)
        lock.unlock()
    }

    static func seconds(since start: DispatchTime) -> Double {
        seconds(from: start, to: .now())
    }

    static func seconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Whether the hardware is currently deinterlacing — for the diagnosis.
    var isDeinterlacing: Bool { decoder?.isDeinterlacing ?? false }

    func start() {
        video.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pumpVideo() }
        audio.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pumpAudio() }
        // The wake-up call without which the renderer would stay silent forever in front of
        // an empty buffer — see ``SampleQueue/onAvailable``.
        samples.onAvailable = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.pumpVideo()
                self.pumpAudio()
            }
        }
    }

    func stop() {
        samples.onAvailable = nil
        video.stopRequestingMediaData()
        audio.stopRequestingMediaData()
        decoder?.invalidate()
        decoder = nil
        decoderDecided = false
    }

    /// Before a seek: what the own decoder still holds goes out — or away, because the
    /// clock starts anew afterwards.
    func flushDecoder() {
        decoder?.flush()
    }

    private func pumpVideo() {
        // **The decision is made at the first frame**, from its description: interlaced
        // video → own decoder with deinterlacing, otherwise the layer.
        if !decoderDecided, let first = samples.peekVideoFormat() {
            decoderDecided = true
            if HardwareVideoDecoder.isWorthwhile(for: first) {
                decoder = HardwareVideoDecoder { [weak self] frame in self?.enqueueDecoded(frame) }
                Diagnostics.playbackStep(
                    "Renderer: interlaced fields — own decoder with deinterlacing", since: nil)
            }
        }
        if let decoder {
            // The decoder has its own measure instead of the layer: it holds the frames in
            // reordering, the layer gets them finished.
            //
            // **And the layer must want them** (F-050, 2026-09-04): `isReadyForMoreMediaData` was
            // missing here. Finished frames went into the layer unasked, and it takes
            // everything — with 20 s of lead from the provider that is five hundred decoded
            // 1080p frames of three megabytes each. "TR: A2 UHD" was gone after 29 s, without
            // signal: the system kills what grows like that.
            while video.isReadyForMoreMediaData,
                decoder.pendingCount < HardwareVideoDecoder.maxInFlight,
                let sample = samples.nextVideo()
            {
                // **A rejected frame is dropped — it does NOT go compressed into the renderer**
                // (F-016): the renderer has been given finished frames and reports `-11800` for
                // every compressed one in between. 1699 times on Rendal HQ, and the picture tore.
                let started = DispatchTime.now()
                _ = decoder.decode(sample)
                noteDecodeCall(seconds: Self.seconds(since: started))
            }
            return
        }
        while video.isReadyForMoreMediaData, let sample = samples.nextVideo() {
            noteLateness(of: sample, isAudio: false)
            video.enqueue(sample)
            lock.lock()
            _enqueuedVideo += 1
            lock.unlock()
        }
    }

    private func enqueueDecoded(_ frame: CMSampleBuffer) {
        noteLateness(of: frame, isAudio: false)
        video.enqueue(frame)
        lock.lock()
        _enqueuedVideo += 1
        lock.unlock()
        // A finished frame makes room for the next one in the decoder.
        queue.async { [weak self] in self?.pumpVideo() }
    }

    private func pumpAudio() {
        notePumpGap()
        while audio.isReadyForMoreMediaData, let sample = samples.nextAudio() {
            noteLateness(of: sample, isAudio: true)
            audio.enqueue(sample)
            lock.lock()
            _enqueuedAudio += 1
            lock.unlock()
        }
    }

    var enqueuedVideo: Int {
        lock.lock()
        defer { lock.unlock() }
        return _enqueuedVideo
    }

    var enqueuedAudio: Int {
        lock.lock()
        defer { lock.unlock() }
        return _enqueuedAudio
    }
}
