import DesignSystemPhone
import SwiftUI

/// Brightness on the left, volume on the right, seeking horizontally.
///
/// **And explicitly not the channel list from the left screen edge.** The same gesture
/// would have had three meanings there — brightness, back, and channel list — and which
/// one applies would depend on a few points of start position. Anyone who confuses them
/// loses the picture.
///
/// **The zones always apply — what is hidden is the controls, not the gesture** (E66).
/// This sentence read the other way round here until 2026-09-10. ("the zones only apply when the
/// bar is showing"), and it described neither the intent nor the build: a gesture that
/// starts to take effect four seconds after the last touch would be a coincidence for the
/// viewer. What actually applies is the **order in the stack**: this surface sits below the
/// bar, so a grip on a visible control belongs to that control — otherwise a grab on the
/// timeline would also move the brightness — and everywhere else it arrives here, whether
/// the bar is showing or not. The gaps between the bar's elements explicitly contribute
/// nothing: their spacers catch no touch, and their gradient in the background is set to
/// `allowsHitTesting(false)`.
///
/// **Reported on release, shown while it happens.** Seeking on every intermediate frame
/// would restart playback fifty times — the display follows the finger, playback only
/// follows the end of the movement.
struct SwipeZones: View {

    let duration: TimeInterval
    let location: TimeInterval
    let skip: (TimeInterval) -> Void
    /// Brightness and volume return the **new value** — during the gesture it appears as a
    /// level next to the finger. Without it (until 2026-09-07) you swiped blind.
    let brightness: (Double) -> Double?
    let volume: (Double) -> Double?
    /// A tap shows or hides the bar.
    let handleInput: () -> Void

    /// A double tap jumps — **forward on the right, back on the left.**
    ///
    /// **This was requested** (2026-09-06): a double tap on the right seeks forward, a double tap
    /// on the left seeks backward. This is the gesture everyone knows from YouTube and
    /// Netflix, and it costs nothing here: the surface is there anyway.
    ///
    /// **The middle belongs to neither.** A double tap exactly on the seam would otherwise be
    /// a coin toss; the middle fifth therefore only toggles the bar, like a single tap.
    let jumpBy: (TimeInterval) -> Void
    /// The finger is gone — **the marker at which a vertical zone releases its anchor.**
    ///
    /// ``Brightness`` computes absolutely from the total travel and needs the value at the
    /// moment of touch for that. Without this end, the anchor would stay the first one of the
    /// film, and every further swipe would start from a brightness that is long since a
    /// different one.
    var released: () -> Void = {}
    /// Dragging down from the middle — **the way out**, as in the players from Apple and
    /// YouTube (requested on 2026-09-07). The value is the progress 0…1; the view follows the
    /// finger with it.
    var pan: (Double) -> Void = { _ in }
    /// Released beyond the threshold: playback ends.
    var finish: () -> Void = {}
    /// A volume that does **not** come from the finger — the device buttons.
    ///
    /// **It must show the same bar as the gesture.** The system's display is suppressed in the
    /// player (see ``VolumeSlider``); without this line you would press the button and
    /// see nothing, and that is worse than the two bars that were the original issue.
    var buttonLevel: Double?
    /// Double speed while pressed — `nil` where the engine cannot do it.
    ///
    /// **As a possibility and not as an attempt.** The repackager feeds its queue at the pace
    /// of the stream; double speed would outrun it. Where the gesture cannot have any effect,
    /// it should not hint at anything either.
    var rate: ((Double) -> Void)?

    /// Whether two fingers are pinching right now — **then the touch belongs to the ``PinchGesture``.**
    ///
    /// Since 2026-09-27 the pinch hangs on the shared stack and runs simultaneously with the
    /// drag of this surface. For the drag, the first finger of a pinch is an ordinary swipe;
    /// without this value every pinch would also adjust brightness, sound or the position in
    /// the film as a side effect.
    var isPinching = false

    /// The position being sought to right now — **it is not shown here.**
    ///
    /// These four states belong to the ``PlayerView`` and are only written here. Until
    /// 2026-09-25 the swipe surface showed them itself, as an overlay across its whole area
    /// with `.center` and `.trailing` — and in portrait it hit exactly the pause button and
    /// +30, which sit in another stack. They are now drawn on the ``FeedbackStage``, which
    /// knows the buttons.
    @Binding var lookahead: TimeInterval?
    /// The level next to the finger — see ``Level``.
    @Binding var level: Level?
    /// Whether double speed is currently being held.
    @Binding var fast: Bool
    /// What the double tap just jumped — see ``JumpIndicator``.
    @Binding var jumpState: JumpIndicator.State?

    @State private var vertical: Vertical?
    /// Whether the scene is in the foreground — **a change is the cancellation that `onEnded` never reports.**
    @Environment(\.scenePhase) private var scenePhase
    @State private var levelRun = 0
    @State private var drag: Double = 0
    @State private var jumpRun = 0
    /// Whether a pinch already happened in this grip — **until release.** If the viewer takes
    /// one finger away early, the remaining finger must not carry on as a new swipe.
    @State private var isPinched = false
    /// Whether a drag is currently running — **a gesture state** that also resets itself after
    /// a cancellation and thereby takes ``isPinched`` along.
    @GestureState private var isPulling = false

    private enum Vertical { case brightness, audio, outbound }

    /// How far down you have to drag for playback to end — in points.
    nonisolated static let dragDistance: Double = 200
    /// At what fraction of the travel releasing ends playback.
    nonisolated static let pullThreshold = 0.55

    /// How far a full screen width seeks.
    ///
    /// **Ninety seconds over 393 points.** Finer would no longer be accurate, coarser would
    /// be a jump instead of a seek — and for the coarse jump there is the timeline.
    static let span: TimeInterval = 90

    /// How far a double tap jumps.
    ///
    /// **`nonisolated`, because a view hangs on the main thread and a number does not.**
    /// Without that, these constants and the rule below them would be bound to the main
    /// thread — and a test that only re-checks a calculation would have to move there.
    ///
    /// **Ten seconds, the system's number.** `AVPlayerViewController` jumps ten, YouTube ten,
    /// Netflix ten — a number of our own would be nothing but a surprise at this point.
    nonisolated static let jump: TimeInterval = 10

    /// How wide the dead middle is — **one fifth.**
    nonisolated static let midpoint = 0.2

    /// How long you have to press until the speed kicks in.
    ///
    /// **Just under half a second**, the number YouTube and TikTok use for the same gesture.
    /// Shorter would catch everyone who hesitates while tapping; longer would feel as if the
    /// app does not respond.
    nonisolated static let pressDuration = 0.45

    /// The speed that a long press holds.
    nonisolated static let fastSpeed = 2.0

    /// Whether a level has just **hit** its stop.
    ///
    /// **The transition counts, not the state.** Anyone who keeps swiping at full volume
    /// reports the same value 1 on every intermediate frame — one bump per intermediate frame
    /// would be a constant buzz and exactly what ``Haptics`` forbids.
    ///
    /// **And a zone change is not a hit.** Anyone who switches from brightness to sound and
    /// happens to start at the stop there has achieved nothing; they just stand somewhere
    /// else.
    ///
    /// **Without a predecessor, nothing.** The first value of a gesture is the state at the
    /// moment of touch — anyone who was already at the top has not just arrived.
    nonisolated static func atLimit(_ old: Level?, _ fresh: Level?) -> Bool {
        guard let fresh, fresh.value <= 0 || fresh.value >= 1 else { return false }
        guard let old, old.audio == fresh.audio else { return false }
        return old.value > 0 && old.value < 1
    }

    var body: some View {
        GeometryReader { space in
            Color.clear
                .contentShape(Rectangle())
                // **The double tap comes before the single tap.** SwiftUI gives the gesture to the
                // counter registered first; the other way round, the single tap would have swallowed
                // every double tap, and seeking would never have arrived.
                .onTapGesture(count: 2) { location in duplicate(location, in: space.size) }
                .onTapGesture { handleInput() }
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .updating($isPulling) { _, isRunning, _ in isRunning = true }
                        .onChanged { drag in move(drag, in: space.size) }
                        .onEnded { _ in release() }
                )
                // **Alongside and not instead.** A long press is not a swipe: the two must not displace
                // each other, otherwise every hesitation before the swipe costs the seeking. The inner
                // drag with distance zero is only the marker for release — otherwise a press gesture
                // never learns that the finger is gone.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: Self.pressDuration)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { state in
                            if case .second(true, _) = state { speedOn() }
                        }
                        .onEnded { _ in speedOff() }
                )
                // **The buttons use the same bar and the same clock** as the gesture —
                // ``showLevelBriefly()`` lets it appear and go again.
                .onChange(of: buttonLevel) { _, fresh in
                    guard let fresh else { return }
                    level = Level(audio: true, value: fresh)
                    showLevelBriefly()
                }
                .onChange(of: isPinching) { _, fresh in
                    guard fresh else { return }
                    cancel()
                    if isPulling { isPinched = true }
                }
                .onChange(of: isPulling) { _, fresh in
                    if !fresh { isPinched = false }
                }
                .onChange(of: scenePhase) { _, fresh in
                    if fresh != .active { cancel() }
                }
                .onDisappear { cancel() }
        }
        // **The stop of brightness and sound.** The bar then stands still while the finger keeps
        // moving — without feedback you swipe against a wall you cannot see, and drag another two
        // centimeters into the void. The rule is in ``atLimit(_:_:)``, because it has three
        // cases and on the device none of them could be hit the same way twice.
        .haptics(.snapped, at: level, when: Self.atLimit)
        // **The threshold of the way out.** Picture and controls follow the finger downward and
        // grow paler as they do (``PlayerView``) — but nothing says from which point releasing
        // ends the film and from which it lets it snap back. This is the only place of this
        // gesture that cannot be shown at all: the viewer sees their own path, not the boundary
        // in it.
        .haptics(.snapped, at: drag >= Self.pullThreshold, when: { _, jenseits in jenseits })
        // **The moment the speed kicks in.** It is hardly visible in the picture — a film that
        // runs faster looks for a second like one that stutters. The bump says: that was me, and
        // it holds as long as you hold.
        .haptics(.snapped, at: fast, when: { _, on in on })
    }

    /// "2×" — **a sign and not a sentence.**
    ///
    /// It is in no language catalog, and that is right: the number and the multiplication
    /// sign read the same in all three languages, and a catalog entry "2×" would be a key
    /// that nobody will ever translate. The **explanation** for it is in the catalog, though
    /// — as a line under "More commands" (``PlayerView``).
    nonisolated static let speedText = "2×"

    /// Speeds up — **but not in the middle of another gesture.**
    ///
    /// Anyone who slowly drags down to close the player holds the finger slightly longer than
    /// half a second in the process. Without this lock the film would play at double speed at
    /// exactly that moment — and the viewer would see two things happening at once, of which
    /// they wanted one.
    private func speedOn() {
        guard let rate, !fast, !isPinched, vertical == nil, lookahead == nil else { return }
        fast = true
        rate(Self.fastSpeed)
    }

    /// Takes it back. **Unconditionally**: the way back must not depend on any state that an
    /// error could have disturbed beforehand — a film stuck at double speed is the worse bug.
    private func speedOff() {
        guard fast else { return }
        fast = false
        rate?(1)
    }

    /// Where a double tap jumps to.
    ///
    /// **On a channel it jumps nowhere.** `duration` is zero there — a channel has no end against
    /// which a position could be measured, and the provider sets
    /// `catchup = 0` on **all** 7,746 channels: there is no archive to jump back into. Instead
    /// of an inconsequential jump, the double tap toggles the bar, like a single tap.
    private func duplicate(_ location: CGPoint, in surface: CGSize) {
        let portion = Double(location.x / max(1, surface.width))
        guard duration > 0, let span = Self.span(at: portion) else {
            handleInput()
            return
        }
        jumpBy(span)
        showSkip(span)
    }

    /// Lets the ``JumpIndicator`` appear and go again — **and counts along while it
    /// appears.**
    ///
    /// The same design as ``showLevelBriefly()``: a counter instead of a cancellable task,
    /// because the second tap has to overtake the first without the first, when it expires,
    /// taking the second's display with it.
    ///
    /// **One second and not the 0.8 of the level.** The level sits next to the finger that is
    /// moving it; here the finger has already left the screen, and the display is the only
    /// information about what happened.
    private func showSkip(_ span: TimeInterval) {
        jumpState = jumpState?.and(span) ?? .first(span)
        jumpRun += 1
        let run = jumpRun
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if jumpRun == run { jumpState = nil }
        }
    }

    /// How far a double tap jumps at this position — `nil` in the dead middle.
    ///
    /// **Computed and not decided in the body.** The rule has three cases and two boundaries;
    /// in the body of a view it could only be checked on the device, and the middle could
    /// never be hit the same way twice there.
    nonisolated static func span(at portion: Double) -> TimeInterval? {
        guard abs(portion - 0.5) > midpoint / 2 else { return nil }
        return portion < 0.5 ? -jump : jump
    }

    private func move(_ drag: DragGesture.Value, in surface: CGSize) {
        guard !isPinched, !isPinching else { return }
        // **The direction is decided once and then held.** Without that, a diagonal movement
        // would flip back and forth between seeking and brightness, and both would be only half
        // executed.
        if vertical == nil, lookahead == nil {
            guard abs(drag.translation.width) > 0 || abs(drag.translation.height) > 0 else {
                return
            }
            if abs(drag.translation.height) > abs(drag.translation.width) {
                // **The middle belongs to the way out** — the same dead middle as with the double tap,
                // only downward. Brightness and sound are to the left and right of it.
                let portion = Double(drag.startLocation.x / max(1, surface.width))
                if abs(portion - 0.5) <= Self.midpoint / 2, drag.translation.height > 0 {
                    vertical = .outbound
                } else {
                    vertical = portion < 0.5 ? .brightness : .audio
                }
            }
        }
        if let vertical {
            // Upward is more — on the screen, up points up.
            let portion = -drag.translation.height / max(1, surface.height)
            switch vertical {
            case .brightness:
                if let value = brightness(Double(portion)) { level = Level(audio: false, value: value) }
            case .audio:
                if let value = volume(Double(portion)) { level = Level(audio: true, value: value) }
            case .outbound:
                self.drag = min(1, max(0, Double(drag.translation.height) / Self.dragDistance))
                pan(self.drag)
            }
            return
        }

        guard duration > 0 else { return }
        let portion = drag.translation.width / max(1, surface.width)
        lookahead = min(duration, max(0, location + Double(portion) * Self.span))
    }

    private func release() {
        // **A pinch is not a swipe.** What the drag had started up to that point has already been
        // taken back by ``cancel()``; nothing jumps or closes here any more.
        if isPinched {
            isPinched = false
            return
        }
        if let lookahead { skip(lookahead) }
        if vertical == .outbound {
            if drag >= Self.pullThreshold {
                finish()
            } else {
                pan(0)
            }
            drag = 0
        }
        lookahead = nil
        vertical = nil
        released()
        showLevelBriefly()
    }

    /// What to take back after an **aborted** grip (finding B3, 2026-09-25).
    ///
    /// Until then, resetting happened only in `.onEnded`. If the system aborts a gesture — a
    /// call, Control Center, switching to another app —, `.onEnded` never comes: preview, level
    /// and drag stayed in place, and in the worst case the film kept running at double speed.
    ///
    /// **An abort is not a release:** it does not jump to the preview and does not end
    /// playback, even if the drag was beyond the threshold — both would be actions that the
    /// viewer did not bring to completion.
    nonisolated static func cancelSteps(
        lookahead: Bool, level: Bool, drag: Double, vertical: Bool, fast: Bool
    ) -> [CancelStep] {
        var steps: [CancelStep] = []
        if lookahead { steps.append(.discardPreview) }
        if drag > 0 { steps.append(.snapBack) }
        if vertical { steps.append(.releaseAnchor) }
        if level { steps.append(.hideLevel) }
        if fast { steps.append(.speedBack) }
        return steps
    }

    /// Takes back an aborted grip — see ``cancelSteps(lookahead:level:drag:vertical:fast:)``.
    private func cancel() {
        let steps = Self.cancelSteps(
            lookahead: lookahead != nil, level: level != nil, drag: drag,
            vertical: vertical != nil, fast: fast)
        for step in steps {
            switch step {
            case .discardPreview: lookahead = nil
            case .snapBack:
                drag = 0
                pan(0)
            case .releaseAnchor:
                vertical = nil
                released()
            case .hideLevel: level = nil
            case .speedBack: speedOff()
            }
        }
    }

    /// **The level stays up briefly** — long enough to read the value, short enough that it
    /// does not sit over the film. A new grip in the meantime holds it: the counter decides
    /// who may clean up, and that is always the last one.
    private func showLevelBriefly() {
        levelRun += 1
        let run = levelRun
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            if levelRun == run { level = nil }
        }
    }

    /// "+42 s" or "−1:10" — **the span, not just the position.**
    ///
    /// When seeking you want to know **how far** you have jumped; the position alone answers
    /// that only after mental arithmetic.
    static func distanceText(_ span: TimeInterval) -> String {
        let character = span < 0 ? "−" : "+"
        return character + Timeline.time(abs(span))
    }
}

/// One step when taking back an aborted grip — see
/// ``SwipeZones/cancelSteps(lookahead:level:drag:vertical:fast:)``.
nonisolated enum CancelStep: Equatable, Sendable {
    case discardPreview
    case snapBack
    case releaseAnchor
    case hideLevel
    case speedBack
}

/// What is currently being dragged and how far — brightness or sound, 0 to 1.
///
/// **Next to ``SwipeZones`` and not inside it** (2026-09-07): a view hangs on the main thread,
/// two numbers do not. Nested, this value would carry the view's thread binding along, and
/// ``SwipeZones/atLimit(_:_:)`` — a pure calculation that a test is meant to re-check —
/// could not get at its fields. The same reasoning as for ``SwipeCommand``, only with the
/// main thread instead of a type parameter.
struct Level: Equatable {
    /// Sound or brightness — **the zone belongs to the value.** A change of zone is not a hit,
    /// even if both happen to stand at the same end.
    let audio: Bool
    let value: Double
}

/// The level next to the finger — a vertical bar with the symbol below it.
///
/// **No number:** "63 %" answers no question you have while swiping; the fill level does.
/// Light on a semi-transparent background, so that it can be seen on any picture.
struct LevelIndicator: View {
    let icon: String
    /// 0 bis 1.
    let value: Double

    var body: some View {
        VStack(spacing: MetricsBoard.phone.gutter) {
            GeometryReader { space in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(.white)
                        .frame(height: space.size.height * min(1, max(0, value)))
                }
            }
            .frame(width: 6)
            // **Flexible down to a third.** In landscape and with the largest type, less height than
            // 140 points is free next to the transport row; a fixed bar would then run over the head
            // (see ``FeedbackSlots``).
            .frame(minHeight: 48, idealHeight: 140, maxHeight: 140)
            Image(systemName: icon)
                .iconSize(15, weight: .semibold)
                .foregroundStyle(.white)
        }
        .padding(.vertical, MetricsBoard.phone.gutter)
        .padding(.horizontal, Metrics.targetSpacing)
        .background(.black.opacity(0.35), in: Capsule())
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
