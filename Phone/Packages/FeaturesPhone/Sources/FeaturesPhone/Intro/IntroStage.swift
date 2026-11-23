import AVFoundation
import Core
import DesignSystemPhone
import Diagnose
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// **The app intro on the phone too** (decision 27, C16) — short, only on cold start, a
/// tap skips it.
///
/// **The same clips, the same seasons, the same rule as on the TV**
/// (``Core/IntroCatalog``, ``Core/IntroTiming``): the clip comes at every cold start — app
/// quit in the app switcher and reopened, not on return from the background —,
/// drawn from the season that applies today. The files live
/// once in the repo (`App/Resources/Intro`, decision 4) and come into the bundle via `Phone/project.yml`
/// — a Christmas intro needs only files and an entry here too.
///
/// **What the phone does differently, and why:**
/// * **No still frame.** On the TV it covers loading with "Reduce Motion"; the
///   phone starts faster than a still frame is worth — the requirement was
///   "short". Without a clip the app therefore opens immediately.
/// * **No waiting for Home.** The cover opens at the clip's card deadline
///   (about 3.3 seconds) or on the first tap, whichever comes first.
/// * **Not at all with VoiceOver or "Reduce Motion"** — the same rule as there.
public struct IntroStage<Content: View>: View {

    private let appearance: PhoneIntro?
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(active: Bool = true, @ViewBuilder content: () -> Content) {
        self.appearance = PhoneIntro.forThisLaunch(active: active)
        self.content = content()
    }

    private var isClosed: Bool { appearance.map { $0.cover.pending == nil } ?? false }

    /// **The fade-out hangs on the reason** (``Core/IntroTiming/fadeOut(after:)``): after the deadline
    /// the set fades out for just under a second instead of cutting off with the figure (on-device test
    /// build 1332); a tap removes it briefly.
    private var fadeOut: Animation? {
        guard !reduceMotion, let reason = appearance?.cover.pending else { return nil }
        return .easeInOut(duration: IntroTiming.fadeOut(after: reason))
    }

    public var body: some View {
        ZStack {
            content
                .accessibilityHidden(isClosed)
            #if canImport(UIKit)
                if let appearance, isClosed {
                    IntroLayer(appearance: appearance)
                        .transition(.opacity)
                        .zIndex(1)
                }
            #endif
        }
        .animation(fadeOut, value: isClosed)
    }
}

/// What this launch shows — **decided once** and kept for the program run, so that
/// a rebuild of the shell (language change) does not show the intro again.
@MainActor
final class PhoneIntro {

    let clip: IntroCatalog.Clip
    let clipURL: URL
    let audioURL: URL?
    let bellPlacement: IntroCatalog.Placement
    let cover: IntroCover

    private init(
        clip: IntroCatalog.Clip, clipURL: URL, audioURL: URL?,
        bellPlacement: IntroCatalog.Placement, cover: IntroCover
    ) {
        self.clip = clip
        self.clipURL = clipURL
        self.audioURL = audioURL
        self.bellPlacement = bellPlacement
        self.cover = cover
    }

    private static var decided: PhoneIntro??

    static func forThisLaunch(active: Bool) -> PhoneIntro? {
        if let decided { return decided }
        let fresh = active ? plane() : nil
        decided = .some(fresh)
        return fresh
    }

    /// Runs `action` **as soon as the cover of this launch is open** — without an intro
    /// immediately (check Shell H7). The same role as `DrawReadiness.afterIntro`
    /// on the TV: a sheet at launch would otherwise lie over the clip.
    static func afterIntro(_ action: @escaping @MainActor () -> Void) {
        guard case .some(.some(let appearance)) = decided else {
            action()
            return
        }
        appearance.cover.afterUncovering(action)
    }

    /// **On the phone only the clip** — ``Core/IntroTiming/Kind/stillFrame`` means "no
    /// intro" here (see ``IntroStage``).
    nonisolated static func shows(_ kind: IntroTiming.Kind) -> Bool { kind == .clip }

    private static func plane() -> PhoneIntro? {
        #if canImport(UIKit)
            let voiceOver = UIAccessibility.isVoiceOverRunning
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
        #else
            let voiceOver = true
            let reduceMotion = true
        #endif
        guard
            let address = Bundle.main.url(forResource: "intros", withExtension: "json"),
            let bytes = try? Data(contentsOf: address),
            let catalog = try? IntroCatalog.read(bytes)
        else { return nil }

        let now = Date()
        var random = SystemRandomNumberGenerator()
        let available: (String) -> Bool = {
            Bundle.main.url(forResource: $0, withExtension: nil) != nil
        }
        let drawn = catalog.select(
            on: now, calendar: IntroCatalog.deviceCalendar, available: available, using: &random)
        let clipURL = drawn.flatMap {
            Bundle.main.url(forResource: $0.file, withExtension: nil)
        }
        let introKind = IntroTiming.kind(
            voiceOver: voiceOver, reduceMotion: reduceMotion,
            hasClip: clipURL != nil)
        guard shows(introKind), let clip = drawn, let clipURL else { return nil }

        return PhoneIntro(
            clip: clip, clipURL: clipURL,
            audioURL: clip.audio.flatMap { Bundle.main.url(forResource: $0, withExtension: nil) },
            bellPlacement: catalog.ringRingPosition,
            cover: .withClock(deadline: .seconds(clip.cardsDeadline)))
    }
}

#if canImport(UIKit)
    /// The clip over everything — **a tap anywhere skips it.**
    struct IntroLayer: View {

        let appearance: PhoneIntro

        static let bellDuration = 1.5

        @State private var isRinging = false

        var body: some View {
            ZStack {
                // systemfarbe: behind the clip is black as in the cinema — the video
                // is 16 : 9 and fills, and the surface should not look like the app at the edges.
                Color.black.ignoresSafeArea()
                IntroClip(
                    address: appearance.clipURL, bellSound: appearance.audioURL,
                    startAt: appearance.clip.trimStart, bellFrom: appearance.clip.bellAt,
                    bellUntil: appearance.clip.bellAt + Self.bellDuration
                ) { ringing in
                    isRinging = ringing
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
                if isRinging {
                    GeometryReader { surface in
                        Image(systemName: Glyph.bell.name)
                            .iconSize(56, weight: .semibold)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 8)
                            .position(
                                x: surface.size.width * appearance.bellPlacement.x,
                                y: surface.size.height * appearance.bellPlacement.y)
                    }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: appearance.cover.skip)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(app: "intro.skip"))
            .accessibilityAction { appearance.cover.skip() }
            .onAppear { appearance.cover.start() }
            .animation(.spring(duration: 0.4), value: isRinging)
        }
    }

    /// The clip itself — muted, from `trimStart`, the chime as its own sound.
    struct IntroClip: UIViewRepresentable {

        let address: URL
        let bellSound: URL?
        let startAt: Double
        let bellFrom: Double
        let bellUntil: Double
        let onBell: @MainActor @Sendable (Bool) -> Void

        final class Surface: UIView {
            override class var layerClass: AnyClass { AVPlayerLayer.self }
            var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        }

        @MainActor
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
            player.actionAtItemEnd = .pause
            player.isMuted = true
            player.allowsExternalPlayback = false
            surface.playerLayer.player = player

            let bell = bellSound.flatMap { try? AVAudioPlayer(contentsOf: $0) }
            if bell != nil { Self.mixWithOthers() }
            bell?.prepareToPlay()
            let controller = context.coordinator
            controller.bell = bell
            let onBell = self.onBell
            let times = { (seconds: Double) in
                [NSValue(time: CMTime(seconds: seconds, preferredTimescale: 600))]
            }
            let bellOn = player.addBoundaryTimeObserver(forTimes: times(bellFrom), queue: .main) {
                MainActor.assumeIsolated {
                    controller.bell?.play()
                    onBell(true)
                }
            }
            let bellOff = player.addBoundaryTimeObserver(forTimes: times(bellUntil), queue: .main) {
                MainActor.assumeIsolated { onBell(false) }
            }
            controller.player = player
            controller.observers = [bellOn, bellOff]

            player.seek(
                to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                Task { @MainActor in controller.player?.play() }
            }
            return surface
        }

        /// The chime **mixes into running music instead of cutting it off** (check
        /// Shell H9, 2026-09-27).
        ///
        /// Without a set category `soloAmbient` applies: not mixable, and the app's first sound
        /// ends music or a podcast — for a chime of a second and a half. `.ambient`
        /// mixes and follows the silent switch. The player sets its own category at
        /// start (``AudioSession``), so this one does not stick.
        static func mixWithOthers() {
            do {
                try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            } catch {
                Diagnose.hint(.surface, "Intro: audio category not set", error)
            }
        }

        func updateUIView(_ surface: Surface, context: Context) {}

        static func dismantleUIView(_ surface: Surface, coordinator: Controller) {
            coordinator.hold()
            surface.playerLayer.player = nil
        }
    }
#endif
