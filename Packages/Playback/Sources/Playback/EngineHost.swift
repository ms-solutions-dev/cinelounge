import AVFoundation
import Core
import Foundation
import Observation

/// Holds the engine that belongs to a target and hands it out as a ``PlaybackController``.
///
/// The UI knows only this host. It never creates an engine itself, for two reasons:
/// otherwise every view would have to rebuild the choice from ``PlaybackDecision``, and
/// when the target changes the old engine would keep running — you would hear two audio
/// tracks on top of each other. That is exactly what showed up in the E0 evidence.
@MainActor
@Observable
public final class EngineHost {

    /// The engine that is playing.
    ///
    /// **There is exactly one** (AP8, 2026-09-02). Next to it there used to be
    /// ``requestedEngine`` and the question of whether another engine had stepped in —
    /// a distinction from the time when VLCKit was linked only on tvOS and the system
    /// player stepped in on the Mac. Since the teardown it can no longer be true.
    public private(set) var engine: PlaybackEngine = .native

    /// Whether a target is currently loaded.
    ///
    /// Before the first ``start(_:)`` an empty system player is already in place,
    /// so that ``controller`` is never missing. Without this flag there would be no way
    /// from outside to tell whether this engine is waiting or playing.
    public private(set) var isRunning = false

    /// The aspect ratio of the picture being played, width divided by height — `nil` as long
    /// as nobody knows it.
    ///
    /// **Needed on the phone, not on the TV** (AP4): Without this number the pinch gesture
    /// does not know how far it may go at all, and the remembered setting would not know
    /// which format to store it under.
    ///
    /// **Only the system player knows it, and that is not an oversight.** `presentationSize`
    /// lives on the `AVPlayerItem`; the direct renderer receives its images as samples and
    /// keeps no size. What it plays are channels — there the provider's format is a single
    /// one anyway, and the choice would add nothing. **So `nil` instead of a guessed number:**
    /// The fill factor becomes 1, the gesture moves nothing, and the button does not
    /// appear. A guess at this point would be a crop of the picture that nobody
    /// ordered.
    ///
    /// **Not `@Published`.** The size is set only once the player knows the first frame,
    /// and it does not change afterwards; whoever needs it samples it on the running
    /// tick (``PlayerModel``). Setting up an observation for it would mean giving the
    /// shared package a task that only the phone has.
    public var imageFormat: Double? {
        guard
            let size = (active as? NativePlaybackEngine)?.player.currentItem?
                .presentationSize,
            size.width > 0, size.height > 0
        else { return nil }
        return Double(size.width / size.height)
    }

    /// Passes a frame rate measured **later** on to the running engine.
    ///
    /// **Why this is needed** (AP2 · U4): On the file path there is no measured frame rate
    /// at startup — measuring is possible only on an assembled piece. The
    /// `DefaultDuration` from the Matroska header was therefore passed along, and that is a
    /// claim made by the file: In the same second, on 2026-08-23, the log showed "27.78 Hz measured"
    /// and "30.0 Hz registered (measured by the repackager)".
    ///
    /// Now the number travels afterwards. Whether it may overrule an earlier registration
    /// is decided by ``FrameRateRegistration``: A better source always may.
    public func adopt(contentFrameRate rate: Double) {
        if let native = active as? NativePlaybackEngine {
            native.contentFrameRate = rate
        } else if let renderer = active as? SampleBufferPlaybackEngine {
            renderer.contentFrameRate = rate
        }
    }

    /// A line for the log and for troubleshooting.
    ///
    /// Without a target this is stated explicitly: "as decided" would claim a
    /// choice that nobody made — whoever reads the line next to a black
    /// picture would conclude that something is playing.
    public var report: String {
        isRunning
            ? "Engine \(engine.rawValue) as decided"
            : "Engine \(engine.rawValue) ready, no target loaded"
    }

    public var controller: any PlaybackController { active }

    /// The state of the running engine — for views that wait for the end without knowing
    /// the controller (AP82, 2026-10-12: the trailer in the background of the
    /// detail page fades back to the still frame on `.ended`).
    public var status: PlaybackStatus { active.status }

    /// Muted or with sound — only for the system player; the direct renderer for channels
    /// has no mute and does not need it (AP82: the background trailer of the
    /// detail page runs muted, the full screen via the button with sound).
    public var isMuted: Bool {
        get { nativePlayer?.isMuted ?? false }
        set { nativePlayer?.isMuted = newValue }
    }

    /// Picture in picture for the video surface of this host — see ``PictureInPicture``.
    public let pictureInPicture = PictureInPicture()

    private var active: any PlaybackController

    public init() {
        // An empty system player as a placeholder, so that ``controller`` is not an
        // optional. Otherwise every view would have to handle the case "no engine yet",
        // although without a target it is not shown anyway.
        active = NativePlaybackEngine()
    }

    // No `deinit`. The teardown lives in ``stop()`` — the reasoning is in
    // ``NativePlaybackEngine``: A `deinit` runs without actor binding, and Swift 6
    // refuses access to non-sendable observers there.

    /// Creates the engine that the target's decision names, and loads the target.
    ///
    /// - Parameter samples: The download for the direct renderer. **Required when
    ///   the decision names it**, otherwise meaningless: A renderer without a
    ///   download would have nothing to draw — then the system player plays the
    ///   address, and the diagnostics say that the decision did not apply.
    public func start(_ target: PlaybackTarget) { start(target, samples: nil) }

    public func start(_ target: PlaybackTarget, samples: SampleQueue?) {
        // Tear down first, then build up. Without this line the old engine stays alive on the
        // second call: It already has the audio open, and you hear both
        // tracks at the same time while only the picture of the new one is visible.
        stop()

        // **Two engines, one switch — and the switch is the decision.**
        // AP8 (2026-09-02) had removed the switch because its second branch was VLC
        // and nobody created it any more. Since 2026-09-03 there is a second branch
        // again, and it is created: the direct renderer for
        // channels (``PlaybackEngine/renderer``). It needs no change to the
        // view — only a download instead of an address.
        if target.decision.engine == .renderer, let samples {
            let renderer = SampleBufferPlaybackEngine(samples: samples)
            renderer.contentFrameRate = target.contentFrameRate
            adopt(renderer, as: .renderer)
        } else {
            if target.decision.engine == .renderer {
                Diagnostics.playbackProblem(
                    "Direct renderer decided, but no buffer handed over — "
                        + "the system player takes the address",
                    since: nil)
            }
            let native = NativePlaybackEngine()
            // The subtitle appearance from Settings — before loading,
            // because the rules attach to the item and come into being with it.
            native.subtitleStyle = SubtitleStyle.load(from: ProfileStore.playback)
            // For the case of several simultaneously active audio tracks in the
            // container — see ``NativePlaybackEngine/enforceSingleAudioTrack()``.
            native.preferredAudioLanguage = target.preferredAudioLanguage
            // The measured frame rate, if one came along — see
            // ``NativePlaybackEngine/contentFrameRate``.
            native.contentFrameRate = target.contentFrameRate
            adopt(native, as: .native)
        }

        // Only after `isRunning`, because ``report`` reads it: Before that, the log would
        // say "no target loaded" on every start.
        isRunning = true
        // **The whole decision, not just the engine.** Here used to be only "engine vlc
        // as decided", and from the log alone it was impossible to tell whether the stream is
        // delivered directly, repackaged or transcoded — questions that come first with every
        // playback error. The reason belongs with it: It says which
        // rule applied and makes a wrong rule distinguishable from a
        // wrong engine.
        // With the title first (product question 2026-08-15: "do we record which
        // channel you are on?") — without it, the start line alone gave no way to tell WHAT is actually
        // starting except by guessing from the neighbouring lines.
        // **`[  —  ]` instead of `[  0.0s]`** (finding 2026-08-24): Here used to be `since: Date()`, and
        // ``Diagnostics/elapsed(since:)`` computes against now — so the line reported zero seconds in 189 of
        // 189 cases and thereby claimed a measurement. There is no reference point at all at
        // this spot: This line IS the zero point, `load` follows three statements
        // later. The gain lies only in the system log (`log show`) — in the export file from the
        // TV the time field is not present at all: ``Diagnostics/verboseEntry(_:failed:enabled:)``
        // takes over only the text.
        Diagnostics.playbackStep(
            """
            Start "\(target.title)": \(report), delivery \(target.decision.delivery.rawValue), \
            Reason \(target.decision.reason.rawValue), kind \(target.kind.rawValue)\
            \(target.decision.isBandwidthLimited ? ", limited to \(target.decision.maxBitrate.map { "\($0 / 1_000_000) Mbit/s" } ?? "?")" : "")
            """,
            since: nil
        )

        active.load(target.url, startingAt: target.startAt)
    }

    /// Ends playback and releases the forwarding.
    ///
    /// The engine itself stays in place and remains queryable — whoever still wants to report the
    /// last position after the end needs it.
    public func stop() {
        active.stop()
        isRunning = false
    }

    /// Adopts an engine.
    ///
    /// **There used to be a forwarding here, and it was removed without replacement with `@Observable`**
    /// (AP32, 2026-09-11). The reason back then was real: An
    /// `ObservableObject` **inside** an `ObservableObject` reports nothing to the
    /// outside — SwiftUI observes only the host, the `@Published` fields of the engine
    /// sit one level deeper. The result was not an error message but *"a
    /// progress bar that stays at zero while the film is playing"*, and nothing of it was
    /// visible in the source. So the host listened to the engine's `objectWillChange`
    /// and sent its own after it.
    ///
    /// **`@Observable` reports at the property and not at the class.** Whoever reads
    /// `host.active.position` observes exactly that property — across
    /// nesting boundaries. The trap no longer exists, and neither does the forwarding that
    /// plugged it.
    ///
    /// The engine still comes in as its own type: ``adopt(_:as:)`` is called with
    /// exactly two types, and an existential type would gain nothing here.
    private func adopt<E: PlaybackController>(_ newEngine: E, as kind: PlaybackEngine) {
        active = newEngine
        engine = kind
    }

    // MARK: - Access for the drawing surface

    /// Only for ``VideoSurface``: The picture surface must know the player in order to attach it to
    /// a layer. The ``PlaybackController`` contract deliberately does not hand it
    /// out, because otherwise every view could steer past the engine.
    var nativePlayer: AVPlayer? {
        (active as? NativePlaybackEngine)?.player
    }

    /// Likewise only for ``VideoSurface``: The surface attaches its video layer to
    /// the engine so that the engine can attest the first **drawn** frame — without
    /// this wire ``PlaybackController/firstFrameVisible`` would stay without information.
    var nativeEngine: NativePlaybackEngine? {
        active as? NativePlaybackEngine
    }

    /// The picture currently shown — only the system player can provide it; see
    /// ``NativePlaybackEngine/stillFrame(width:)``.
    public func stillFrame() -> Data? {
        nativeEngine?.stillFrame()
    }

    /// Likewise only for ``VideoSurface``: The direct renderer brings its own
    /// drawing surface; the view only hooks it in.
    var rendererEngine: SampleBufferPlaybackEngine? {
        active as? SampleBufferPlaybackEngine
    }

}
