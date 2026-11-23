import Core
import Foundation

// **`canImport(UIKit)` and not `os(tvOS)`.** `AVPictureInPictureController` exists on
// iOS just the same — the switch was historical, not factual: as long as only the TV
// built, both conditions were the same thing. Since the phone uses the same engine,
// even the **signature** was missing there, and the video surface could no longer be
// compiled.
//
// **Whether it really works is told by `isPictureInPictureSupported()`** — and on iOS
// additionally by the app's background capability together with the audio session.
// Both belong to the app and not to the engine; it comes with AP27 ("What iOS adds").
// Until then the registration here is complete and goes nowhere, instead of missing.
#if canImport(UIKit)
    import AVKit
    import UIKit
#endif

/// Picture in Picture over the video surface of the system player (AP8).
///
/// **The window belongs to the system**, the engine to us: `AVPictureInPictureController`
/// takes over the `AVPlayerLayer`, the picture continues in the small window — in the
/// app and in other apps —, and the remuxer delivers as if nothing had happened.
/// Whoever leaves the view must then not stop the engine; the holder in Features
/// (``PictureInPictureKeeper``) handles that, and the system reports the return to
/// full screen via ``onRestore``.
@MainActor
public final class PictureInPicture: NSObject, ObservableObject {

    /// Whether the device supports Picture in Picture — on Apple TV since tvOS 14.
    public static var isSupported: Bool {
        #if canImport(UIKit)
            AVPictureInPictureController.isPictureInPictureSupported()
        #else
            false
        #endif
    }

    /// Whether a window is possible right now — surface in the picture, target loaded.
    @Published public private(set) var isPossible = false
    /// Whether the window is up.
    @Published public private(set) var isActive = false

    /// The system wants back to full screen: the app restores the view and then calls the
    /// completion handler with `true`.
    public var onRestore: ((@escaping (Bool) -> Void) -> Void)?
    public var onStarted: (() -> Void)?
    /// The window is gone — after a return or because it was closed.
    public var onStopped: (() -> Void)?

    #if canImport(UIKit)
        private var controller: AVPictureInPictureController?
        private var possibleObservation: NSKeyValueObservation?

        /// Attaches to the video surface of the system player — on every new surface, unless
        /// the window currently stands on the old one: that one stays until the return.
        public func attach(_ layer: AVPlayerLayer) {
            if let controller, controller.isPictureInPictureActive { return }
            guard attached !== layer else { return }
            guard Self.isSupported else { return }
            attached = layer
            adopt(AVPictureInPictureController(playerLayer: layer), engineName: "System player")
        }

        /// Attaches to the drawing surface of the direct renderer.
        ///
        /// **The one place where the second engine learns Picture in Picture** (AP2, 2026-09-07):
        /// `AVPictureInPictureController(playerLayer:)` demands exactly the layer the direct
        /// renderer does not have — until here the button on the phone was therefore greyed
        /// out for every channel of the `ts` access. Since iOS 15 there is the second source,
        /// `ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`, and the engine answers
        /// the window via ``RendererControl`` the questions the system player otherwise
        /// answers: is it playing, how far does it reach, pause, play on.
        ///
        /// **A channel is linear.** `requiresLinearPlayback` takes the scrub buttons away from
        /// the window; a ten-second skip in a running program would be a button without
        /// effect — the same rule as on the lock screen.
        public func attach(_ engine: SampleBufferPlaybackEngine) {
            if let pipController = controller, pipController.isPictureInPictureActive { return }
            guard attached !== engine.displayLayer else { return }
            guard Self.isSupported else { return }
            attached = engine.displayLayer
            let controllerRef = RendererControl(engine: engine)
            rendererControl = controllerRef
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: engine.displayLayer, playbackDelegate: controllerRef)
            let next = AVPictureInPictureController(contentSource: source)
            next.requiresLinearPlayback = true
            adopt(next, engineName: "Direct renderer")
        }

        /// The layer the controller is currently attached to — so that a view that re-applies
        /// on every redraw does not build a new controller on every redraw.
        private weak var attached: CALayer?
        /// The bridge to the direct renderer — held because the controller holds it only
        /// weakly.
        private var rendererControl: RendererControl?

        /// Takes over a new controller — **and on the phone switches on the start when leaving
        /// the app.**
        ///
        /// **That was the finding "Picture in Picture does not work on the phone"** (on-device
        /// test build 1332, 2026-09-27). On the iPhone the small window is opened not with a
        /// button but by leaving the app while the film is playing — that is how the TV app,
        /// Netflix and YouTube do it. iOS does that only if the controller carries
        /// `canStartPictureInPictureAutomaticallyFromInline`; the default is `false`. The
        /// value appeared nowhere in the whole project: whoever swiped home kept hearing the
        /// sound (audio session and `UIBackgroundModes: audio` were right) and saw no window.
        /// That is why every line is missing from the report too — nothing was rejected,
        /// it was never asked.
        ///
        /// **iOS only**: on the TV there is no switch "to home" with the picture running, and
        /// the property does not exist there.
        private func adopt(_ next: AVPictureInPictureController?, engineName: String) {
            possibleObservation = nil
            next?.delegate = self
            #if os(iOS)
                next?.canStartPictureInPictureAutomaticallyFromInline = true
            #endif
            controller = next
            // **Say once per surface what the cause is** (F-001): the button was missing, and
            // the trace had no line about it.
            Diagnostics.playbackStep(
                "Picture in Picture (\(engineName)): device \(Self.isSupported ? "can" : "cannot"), "
                    + "controller \(next == nil ? "not created" : "present"), "
                    + "start on leave \(Self.startsOnLeave ? "on" : "off"), "
                    + "audio session \(AVAudioSession.sharedInstance().category == .playback ? "playback" : AVAudioSession.sharedInstance().category.rawValue)",
                since: nil)
            possibleObservation = next?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
                [weak self] controller, _ in
                let possible = controller.isPictureInPicturePossible
                Task { @MainActor [weak self] in
                    guard let self, self.isPossible != possible else { return }
                    self.isPossible = possible
                    Diagnostics.playbackStep(
                        "Picture in Picture: window \(possible ? "possible" : "not possible right now")",
                        since: nil)
                }
            }
        }
    #endif

    /// Whether the window opens by itself when leaving the app — see `adopt`.
    ///
    /// **Yes on the phone, on the TV there is no such thing.** Information of its own and
    /// not knowledge of the callers, so that the trace says what this build does instead
    /// of someone having to derive it from the platform.
    public static var startsOnLeave: Bool {
        #if os(iOS)
            true
        #else
            false
        #endif
    }

    /// Why ``start()`` opens no window right now.
    ///
    /// **The reason belongs in the log and not just "rejected".** Until 2026-09-27 there
    /// stood only "Picture in Picture rejected"; whether the device cannot do it, the
    /// controller is missing or the picture is not up yet calls for three different
    /// answers, and clearing up a report without asking back meant guessing.
    public enum Rejection: String, Sendable, Equatable {
        /// The device cannot do Picture in Picture.
        case deviceCannot = "geraetKannNicht"
        /// No controller is attached to a picture surface yet — the engine has not shown one.
        case noController = "keinSteuerer"
        /// The controller is up, but the system says "not right now" — mostly because no
        /// picture is there yet.
        case notYetPossible = "nochNichtMoeglich"

        /// The sentence for the trace.
        public var message: String {
            switch self {
            case .deviceCannot: "the device cannot do it"
            case .noController: "no controller on a picture surface"
            case .notYetPossible: "the system reports \"not possible right now\""
            }
        }
    }

    /// The computation behind ``rejection`` — **without the system**, so that it can be
    /// checked on the Mac, where there is no `AVPictureInPictureController`.
    public nonisolated static func rejection(
        supported: Bool, controller: Bool, possible: Bool
    ) -> Rejection? {
        guard supported else { return .deviceCannot }
        guard controller else { return .noController }
        guard possible else { return .notYetPossible }
        return nil
    }

    /// Why no window would open now — `nil` if it works.
    public var rejection: Rejection? {
        #if canImport(UIKit)
            Self.rejection(
                supported: Self.isSupported, controller: controller != nil,
                possible: controller?.isPictureInPicturePossible ?? false)
        #else
            Self.rejection(supported: Self.isSupported, controller: false, possible: false)
        #endif
    }

    /// Opens the window — `false` if it does not work right now; ``rejection`` names the
    /// reason.
    @discardableResult
    public func start() -> Bool {
        #if canImport(UIKit)
            guard rejection == nil, let controller else { return false }
            controller.startPictureInPicture()
            return true
        #else
            return false
        #endif
    }

    public func stop() {
        #if canImport(UIKit)
            controller?.stopPictureInPicture()
        #endif
    }
}

#if canImport(UIKit)
    extension PictureInPicture: AVPictureInPictureControllerDelegate {
        nonisolated public func pictureInPictureControllerDidStartPictureInPicture(
            _ controller: AVPictureInPictureController
        ) {
            Task { @MainActor in
                self.isActive = true
                Diagnostics.playbackStep("Picture in Picture: window is up", since: nil)
                self.onStarted?()
            }
        }

        nonisolated public func pictureInPictureControllerDidStopPictureInPicture(
            _ controller: AVPictureInPictureController
        ) {
            Task { @MainActor in
                self.isActive = false
                Diagnostics.playbackStep("Picture in Picture: window closed", since: nil)
                self.onStopped?()
            }
        }

        nonisolated public func pictureInPictureController(
            _ controller: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: any Error
        ) {
            Task { @MainActor in
                Diagnostics.playbackProblem(
                    "Picture in Picture: window not opened — \(Diagnostics.explain(error))", since: nil)
            }
        }

        nonisolated public func pictureInPictureController(
            _ controller: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion:
                @escaping (Bool) -> Void
        ) {
            // The delegate calls on the main thread; the completion handler is not `Sendable`,
            // so here and now instead of in a task — and expressly marked unsafe, because the
            // thread is fixed.
            nonisolated(unsafe) let promise = completion
            MainActor.assumeIsolated {
                Diagnostics.playbackStep("Picture in Picture: back to full screen", since: nil)
                if let onRestore = self.onRestore {
                    onRestore(promise)
                } else {
                    promise(true)
                }
            }
        }
    }
#endif

#if canImport(UIKit)
    /// The direct renderer's answers to the questions of the Picture-in-Picture window.
    ///
    /// **An object of its own and no extension of the engine:** the delegate must be an
    /// `NSObject`, the engine is not one. And the bridge holds it **weakly** — a window
    /// that the system still keeps open must not keep an engine alive that the host tore
    /// down long ago; without an engine the answers are "stands" and "nothing".
    ///
    /// **The calls arrive on the main thread** — AVKit calls delegates there, and the
    /// engine lives on the main actor. `assumeIsolated` says exactly that and crashes
    /// instead of being silently wrong should AVKit ever change it.
    private final class RendererControl: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {

        private weak var engine: SampleBufferPlaybackEngine?

        init(engine: SampleBufferPlaybackEngine) {
            self.engine = engine
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
        ) {
            // The engine is bound to the main actor and thus `Sendable`; the bridge itself is
            // not — that is why only the engine travels into the block, not `self`.
            let engine = engine
            MainActor.assumeIsolated {
                if playing { engine?.play() } else { engine?.pause() }
            }
        }

        /// **A channel has no beginning and no end** — exactly that is what this span tells
        /// the window: no timeline, no jump to the live edge.
        func pictureInPictureControllerTimeRangeForPlayback(
            _ pictureInPictureController: AVPictureInPictureController
        ) -> CMTimeRange {
            CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }

        func pictureInPictureControllerIsPlaybackPaused(
            _ pictureInPictureController: AVPictureInPictureController
        ) -> Bool {
            let engine = engine
            return MainActor.assumeIsolated { engine?.status == .paused }
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            didTransitionToRenderSize newRenderSize: CMVideoDimensions
        ) {}

        /// A channel cannot be scrubbed; the window does not get the buttons anyway
        /// (`requiresLinearPlayback`). The completion handler must still be called.
        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }
    }
#endif
