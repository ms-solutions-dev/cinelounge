#if os(tvOS)
    import AVFoundation
    import Core
    import DesignSystem
    import SwiftUI
    import UIKit

    /// **The intro as a warm start** (AP51, 2026-09-24) — a layer **over** the first
    /// view, never **before** it.
    ///
    /// **The content is in the tree from the first frame.** That is the whole construction:
    /// ``RootView`` and with it ``MainView`` begin loading immediately, and the intro
    /// lies only on top. Skipping therefore removes **only the picture** — loading
    /// continues, because it never depended on the intro. And if the intro can be left out
    /// entirely (VoiceOver), nothing breaks: the test from the concept, section 7.
    ///
    /// **Outside the identifier for the rebuild** (`themes.rebuildID` in the entry point):
    /// A change of colour scheme throws away the tree underneath; if the intro lay in it,
    /// it would come once more afterwards.
    ///
    /// **The content is locked while the cover is closed.** Without that, a
    /// view underneath would pull the focus to itself — ``MainView`` sets it itself on appearing
    /// —, and a press on Select would hit a card that nobody sees.
    public struct IntroStage<Content: View>: View {

        private let appearance: IntroAppearance?
        private let content: Content

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        /// - Parameter aktiv: `false` for starts that have nothing to do with the viewer
        ///   — the minimal example for the sidebar.
        public init(active: Bool, @ViewBuilder content: () -> Content) {
            self.appearance = IntroAppearance.forThisLaunch(active: active)
            self.content = content()
        }

        private var zu: Bool { appearance.map { $0.cap.pending == nil } ?? false }

        /// **The fade-out depends on the reason** (``Core/IntroTiming/fadeOut(after:)``): opened by itself
        /// just under a second, skipped short.
        private var fadeOut: Animation? {
            guard !reduceMotion, let reason = appearance?.cap.pending else { return nil }
            return .easeInOut(duration: IntroTiming.fadeOut(after: reason))
        }

        public var body: some View {
            ZStack {
                content
                    .disabled(zu)
                    .accessibilityHidden(zu)
                if let appearance, zu {
                    IntroLayer(appearance: appearance)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            // **No gliding with "Reduce Motion"** — the cards simply stand
            // there, as with the ``Streifen``.
            .animation(fadeOut, value: zu)
        }
    }

    /// **What this start shows — decided once per app run.**
    ///
    /// **Static and not as `@State`:** The entry point re-evaluates its body on every
    /// language and session change; a state would hang on the lifetime of a
    /// view, this one on that of the process. That is exactly "only on cold start":
    /// Returning from the background starts no process and shows nothing.
    @MainActor
    final class IntroAppearance {

        let clip: IntroCatalog.Clip?
        let clipURL: URL?
        /// The bell sound of this clip, if it has one and the file is there.
        let audioURL: URL?
        let stillFrame: UIImage?
        let bellPlacement: IntroCatalog.Placement
        let cap: IntroCover

        private init(
            clip: IntroCatalog.Clip?, clipURL: URL?, audioURL: URL?, stillFrame: UIImage?,
            bellPlacement: IntroCatalog.Placement, cap: IntroCover
        ) {
            self.clip = clip
            self.clipURL = clipURL
            self.audioURL = audioURL
            self.stillFrame = stillFrame
            self.bellPlacement = bellPlacement
            self.cap = cap
        }

        /// `.some(nil)` means: decided, and there is none.
        private static var decided: IntroAppearance??

        static func forThisLaunch(active: Bool) -> IntroAppearance? {
            if let decided { return decided }
            let fresh = active ? plane() : nil
            decided = .some(fresh)
            return fresh
        }

        /// **Via `Bundle.main` and not `Bundle.module`:** The files live in the
        /// app bundle (`App/Resources/Intro/`, copied flat). `Bundle.module` would point here
        /// to the package bundle of `Features`, find nothing — and the intro would silently
        /// not appear.
        ///
        /// **The draw comes from the set of this day** (AP51, decision 4): If a
        /// season from `intros.json` applies and its files are there, from its clips, otherwise from
        /// the default set — ``Core/IntroCatalog/clips(on:calendar:available:)``.
        private static func plane() -> IntroAppearance? {
            guard
                let address = Bundle.main.url(forResource: "intros", withExtension: "json"),
                let data = try? Data(contentsOf: address),
                let catalog = try? IntroCatalog.read(data)
            else { return nil }

            let now = Date()
            var random = SystemRandomNumberGenerator()
            // **Gregorian in the device's time zone**, not `.current`: `MM-TT` in
            // `intros.json` are Gregorian days (cross-check track D, 3.1).
            let dayCalendar = IntroCatalog.deviceCalendar
            let available: (String) -> Bool = {
                Bundle.main.url(forResource: $0, withExtension: nil) != nil
            }
            let drawn = catalog.select(
                on: now, calendar: dayCalendar, available: available, using: &random)
            let clipURL = drawn.flatMap {
                Bundle.main.url(forResource: $0.file, withExtension: nil)
            }
            let audioURL = drawn?.audio.flatMap {
                Bundle.main.url(forResource: $0, withExtension: nil)
            }
            let kind = IntroTiming.kind(
                voiceOver: UIAccessibility.isVoiceOverRunning,
                reduceMotion: UIAccessibility.isReduceMotionEnabled,
                hasClip: clipURL != nil)

            let clip: IntroCatalog.Clip?
            let stillFrame: UIImage?
            switch kind {
            case .none:
                return nil
            case .clip:
                clip = drawn
                stillFrame = nil
            case .stillFrame:
                clip = nil
                stillFrame = Bundle.main.url(forResource: catalog.fallbackStill, withExtension: nil)
                    .flatMap { UIImage(contentsOfFile: $0.path) }
                // Without a still frame there is nothing to show — then nothing at all, instead of
                // a black surface with a deadline.
                if stillFrame == nil { return nil }
            }

            let cap = IntroCover.withClock(
                deadline: .seconds(
                    catalog.deadline(
                        forItem: clip, on: now, calendar: dayCalendar, available: available)))
            DrawReadiness.shared.connect(cap)
            return IntroAppearance(
                clip: clip, clipURL: clip == nil ? nil : clipURL,
                audioURL: clip == nil ? nil : audioURL, stillFrame: stillFrame,
                bellPlacement: catalog.ringRingPosition, cap: cap)
        }
    }

    /// The picture itself: clip or still frame, the bell sign and the surface that
    /// skips.
    struct IntroLayer: View {

        let appearance: IntroAppearance

        /// How long the bell sign stays.
        ///
        /// **A second and a half from `bellAt`:** long enough to read it from three metres,
        /// and gone before the figure on the right — where the sign sits — leaves the
        /// frame.
        static let bellDuration = 1.5

        @State private var isRinging = false
        @FocusState private var focused: Bool

        var body: some View {
            ZStack {
                // systemfarbe: The stage of a video — its bars are black.
                Color.black.ignoresSafeArea()
                image
                    .ignoresSafeArea()
                    // **Decoration, not information** (concept, section 7): A video that is
                    // announced is information that nobody needs.
                    .accessibilityHidden(true)
                if isRinging {
                    bellSymbol
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                // **A surface over everything that takes Select** — without a hint text: Five
                // seconds are too short for instructions, and whoever has the
                // remote in hand presses anyway. **No swipe gestures**:
                // The two remote generations behave differently there.
                Button(action: appearance.cap.skip) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .bareFocusableButton()
                .focused($focused)
                .info(Text(app: "intro.skip"))
                .ignoresSafeArea()
            }
            // **The Menu button is consumed** and does not quit the app: On the
            // topmost view it would otherwise throw you out, and "Menu skips" would mean
            // "Menu quits".
            .onExitCommand(perform: appearance.cap.skip)
            .onAppear {
                focused = true
                // **The deadline runs from the first shown frame** (``IntroCover/deadline``),
                // not from the build of the entry point — otherwise the cards would come earlier in the clip by
                // the startup time than `cardsAt` promises.
                appearance.cap.start()
            }
            .animation(.spring(duration: 0.4), value: isRinging)
        }

        @ViewBuilder
        private var image: some View {
            if let clip = appearance.clip, let address = appearance.clipURL {
                ClipSurface(
                    address: address, audio: appearance.audioURL, at: clip.trimStart,
                    bellFrom: clip.bellAt, bellUntil: clip.bellAt + Self.bellDuration
                ) { on in
                    isRinging = on
                }
            } else if let stillFrame = appearance.stillFrame {
                Image(uiImage: stillFrame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }

        /// **In the right third, on black** (`ringRingPosition` from `intros.json`):
        /// outside the light cone, because all figures look to the right.
        private var bellSymbol: some View {
            GeometryReader { surface in
                Image(systemName: Glyph.bell.name)
                    .font(.system(size: 120, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 12)
                    .position(
                        x: surface.size.width * appearance.bellPlacement.x,
                        y: surface.size.height * appearance.bellPlacement.y)
            }
            .ignoresSafeArea()
            // It operates nothing and says nothing that the button does not already say.
            .accessibilityHidden(true)
        }
    }

    /// The clip without controls — an `AVPlayerLayer`, nothing else.
    ///
    /// **Not `VideoPlayer`:** That brings the playback controls along, takes the focus
    /// and registers with "Now Playing". An intro is not a playback.
    struct ClipSurface: UIViewRepresentable {

        let address: URL
        /// The bell sound — it starts **at the same boundary observer** as the
        /// bell sign, that is, in the same frame of the clip (AP51, decision 5). The clip
        /// itself stays silent.
        let audio: URL?
        /// From where playback starts (`trimStart`).
        let at: Double
        let bellFrom: Double
        let bellUntil: Double
        let onBell: @MainActor @Sendable (Bool) -> Void

        final class Surface: UIView {
            override class var layerClass: AnyClass { AVPlayerLayer.self }
            var playerLayer: AVPlayerLayer {
                // The layer is an `AVPlayerLayer` via `layerClass` — always.
                layer as! AVPlayerLayer
            }
        }

        final class Controller {
            var player: AVPlayer?
            var bell: AVAudioPlayer?
            var observers: [Any] = []

            func hold() {
                bell?.stop()
                bell = nil
                player?.pause()
                for entry in observers { player?.removeTimeObserver(entry) }
                observers = []
                player = nil
            }
        }

        func makeCoordinator() -> Controller { Controller() }

        func makeUIView(context: Context) -> Surface {
            let surface = Surface()
            surface.backgroundColor = .black
            surface.playerLayer.videoGravity = .resizeAspectFill

            let player = AVPlayer(url: address)
            // **Hold the last frame at the end** — do not switch to the still frame:
            // Kling only approximated the end frame, 1.5 to 1.9 brightness steps
            // off, and a switch would be seen as a jolt.
            player.actionAtItemEnd = .pause
            player.isMuted = true
            player.allowsExternalPlayback = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            surface.playerLayer.player = player

            let bell = audio.flatMap { try? AVAudioPlayer(contentsOf: $0) }
            bell?.prepareToPlay()
            context.coordinator.bell = bell
            let controller = context.coordinator
            let onBell = self.onBell
            let time = { (seconds: Double) in
                [NSValue(time: CMTime(seconds: seconds, preferredTimescale: 600))]
            }
            // **Via boundary observers and not via a clock of our own**: They hang on the
            // clip's time — if the startup stutters, the bell still rings in the right frame.
            let on = player.addBoundaryTimeObserver(forTimes: time(bellFrom), queue: .main) {
                MainActor.assumeIsolated {
                    controller.bell?.play()
                    onBell(true)
                }
            }
            let from = player.addBoundaryTimeObserver(forTimes: time(bellUntil), queue: .main) {
                MainActor.assumeIsolated { onBell(false) }
            }
            context.coordinator.player = player
            context.coordinator.observers = [on, from]

            // **From `trimStart`, frame-accurate** — and only then play: A `play()` before the
            // end of the seek would show for a moment the lead-in that `trimStart`
            // is meant to cut off.
            player.seek(
                to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                Task { @MainActor in controller.player?.play() }
            }
            return surface
        }

        func updateUIView(_ surface: Surface, context: Context) {}

        static func dismantleUIView(_ surface: Surface, coordinator: Controller) {
            coordinator.hold()
            surface.playerLayer.player = nil
        }
    }
#endif
